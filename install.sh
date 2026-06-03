#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# GADS Installation Script (Raspberry Pi 5)
# ============================================================
# Installs MongoDB, extracts the GADS binary, creates systemd
# hub + provider services, and starts everything.

# ---------- Configuration ----------
GADS_USER="${GADS_USER:-$USER}"
GADS_DIR="${GADS_DIR:-/home/$GADS_USER/GADS}"
ZIP_FILE="$(cd "$(dirname "$0")" && pwd)/GADS.zip"

# MongoDB version
MONGO_VERSION="${MONGO_VERSION:-7.0}"

# Hub settings
HUB_HOST="${HUB_HOST:-0.0.0.0}"
HUB_PORT="${HUB_PORT:-10000}"
HUB_AUTH="${HUB_AUTH:-true}"
MONGO_DB="${MONGO_DB:-localhost:27017}"

# Provider settings
PROVIDER_NICKNAME="${PROVIDER_NICKNAME:-pi-provider}"
PROVIDER_HUB="${PROVIDER_HUB:-http://192.168.1.7:10000}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------- Prerequisite checks ----------
if [[ $EUID -eq 0 ]]; then
  err "Do not run this script as root directly. Use a regular user — sudo will be used when needed."
fi

if [[ ! -f "$ZIP_FILE" ]]; then
  err "GADS.zip not found at $ZIP_FILE"
fi

ARCH="$(dpkg --print-architecture)"
if [[ "$ARCH" != "arm64" ]]; then
  warn "Expected arm64 (Raspberry Pi 5 64-bit), got $ARCH. Proceeding anyway..."
fi

# ============================================================
# 1. Install MongoDB
# ============================================================
install_mongodb() {
  if command -v mongod &>/dev/null; then
    log "MongoDB is already installed: $(mongod --version 2>/dev/null | head -1)"
    return 0
  fi

  log "Installing MongoDB $MONGO_VERSION for $ARCH..."

  # Import GPG key
  curl -fsSL https://www.mongodb.org/static/pgp/server-${MONGO_VERSION}.asc \
    | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg

  # Add repo (MongoDB provides arm64 packages for Ubuntu/Debian)
  . /etc/os-release
  if [[ "$ID" == "raspbian" ]]; then
    # Raspbian → use Debian repo
    REPO_DISTRO="debian"
    REPO_CODENAME="bookworm"
  elif [[ "$ID" == "ubuntu" ]]; then
    REPO_DISTRO="ubuntu"
    REPO_CODENAME="${VERSION_CODENAME:-$UBUNTU_CODENAME}"
  elif [[ "$ID" == "debian" ]]; then
    REPO_DISTRO="debian"
    REPO_CODENAME="${VERSION_CODENAME}"
  else
    REPO_DISTRO="debian"
    REPO_CODENAME="bookworm"
    warn "Unknown distro '$ID', defaulting to debian bookworm."
  fi

  echo "deb [arch=arm64 signed-by=/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg] \
https://repo.mongodb.org/apt/${REPO_DISTRO} ${REPO_CODENAME}/mongodb-org/${MONGO_VERSION} main" \
    | sudo tee /etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list > /dev/null

  sudo apt-get update
  sudo apt-get install -y mongodb-org

  log "Starting and enabling mongod..."
  sudo systemctl enable mongod
  sudo systemctl start mongod

  log "MongoDB installed and running."
}

# ============================================================
# 2. Stop existing GADS services
# ============================================================
stop_gads() {
  log "Stopping existing GADS services (if running)..."
  sudo systemctl stop gads-hub gads-provider 2>/dev/null || true
}

# ============================================================
# 3. Extract GADS binary
# ============================================================
extract_gads() {
  log "Creating working directory: $GADS_DIR"
  sudo mkdir -p "$GADS_DIR"

  log "Extracting GADS binary..."
  sudo unzip -o "$ZIP_FILE" -d "$GADS_DIR"

  log "Making GADS executable..."
  sudo chmod +x "$GADS_DIR/GADS"

  log "Setting ownership to $GADS_USER..."
  sudo chown -R "$GADS_USER:$GADS_USER" "$GADS_DIR"
}

# ============================================================
# 4. Create systemd services
# ============================================================
create_services() {
  HUB_SERVICE="/etc/systemd/system/gads-hub.service"
  log "Creating $HUB_SERVICE"

  sudo tee "$HUB_SERVICE" > /dev/null <<EOF
[Unit]
Description=GADS Hub
After=network.target mongod.service
Requires=mongod.service

[Service]
Type=simple
User=$GADS_USER
WorkingDirectory=$GADS_DIR
ExecStart=$GADS_DIR/GADS hub \\
  --host-address=$HUB_HOST \\
  --port=$HUB_PORT \\
  --auth=$HUB_AUTH \\
  --mongo-db=$MONGO_DB
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  PROVIDER_SERVICE="/etc/systemd/system/gads-provider.service"
  log "Creating $PROVIDER_SERVICE"

  sudo tee "$PROVIDER_SERVICE" > /dev/null <<EOF
[Unit]
Description=GADS Provider
After=network.target gads-hub.service mongod.service
Wants=gads-hub.service

[Service]
Type=simple
User=$GADS_USER
WorkingDirectory=$GADS_DIR
Environment="PATH=/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin:/usr/lib/android-sdk/platform-tools"
ExecStartPre=/bin/sleep 5
ExecStart=$GADS_DIR/GADS provider \\
  --nickname=$PROVIDER_NICKNAME \\
  --hub=$PROVIDER_HUB \\
  --mongo-db=$MONGO_DB
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

# ============================================================
# 5. Enable and start GADS services
# ============================================================
start_gads() {
  log "Reloading systemd daemon..."
  sudo systemctl daemon-reload

  log "Enabling gads-hub and gads-provider..."
  sudo systemctl enable gads-hub gads-provider

  log "Starting gads-hub..."
  sudo systemctl start gads-hub
  sleep 5
  log "Starting gads-provider..."
  sudo systemctl start gads-provider
}

# ============================================================
# 6. Show status
# ============================================================
show_status() {
  echo ""
  log "============================================"
  log "  Installation complete!"
  log "============================================"
  echo ""

  log "MongoDB status:"
  sudo systemctl status mongod --no-pager -l || true
  echo ""
  log "Hub service status:"
  sudo systemctl status gads-hub --no-pager -l || true
  echo ""
  log "Provider service status:"
  sudo systemctl status gads-provider --no-pager -l || true

  echo ""
  log "Useful commands:"
  log "  sudo systemctl status mongod"
  log "  sudo systemctl status gads-hub"
  log "  sudo systemctl status gads-provider"
  log "  sudo journalctl -u gads-hub -f"
  log "  sudo journalctl -u gads-provider -f"
}

# ============================================================
# Run
# ============================================================
install_mongodb
stop_gads
extract_gads
create_services
start_gads
show_status
