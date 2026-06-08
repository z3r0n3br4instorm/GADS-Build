#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# GADS Installation Script (Raspberry Pi 5)
# ============================================================
# Installs Docker, runs MongoDB in a container, extracts the
# GADS binary, and creates systemd hub + provider services.

# ---------- Configuration ----------
GADS_USER="${GADS_USER:-$USER}"
GADS_DIR="${GADS_DIR:-/home/$GADS_USER/GADS}"
ZIP_FILE="$(cd "$(dirname "$0")" && pwd)/GADS.zip"

# MongoDB container
MONGO_VERSION="${MONGO_VERSION:-7.0}"
MONGO_CONTAINER="${MONGO_CONTAINER:-gads-mongodb}"
MONGO_PORT="${MONGO_PORT:-27017}"

# Hub settings
HUB_HOST="${HUB_HOST:-0.0.0.0}"
HUB_PORT="${HUB_PORT:-10000}"
HUB_AUTH="${HUB_AUTH:-true}"
MONGO_DSN="${MONGO_DSN:-localhost:${MONGO_PORT}}"

# Provider settings
PROVIDER_NICKNAME="${PROVIDER_NICKNAME:-pi-provider}"
PROVIDER_HUB="${PROVIDER_HUB:-http://0.0.0.0:10000}"

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
# 1. Install Docker
# ============================================================
install_docker() {
  if command -v docker &>/dev/null; then
    log "Docker is already installed: $(docker --version)"
  else
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sudo sh
  fi

  log "Adding $GADS_USER to docker group..."
  sudo usermod -aG docker "$GADS_USER" || true

  log "Refreshing group membership..."
  sg docker -c "echo '  Docker group active for this session'" || true
  warn "You may need to log out and back in for docker group to take full effect."
}

# ============================================================
# 2. Start MongoDB in Docker
# ============================================================
start_mongodb() {
  # Stop+remove old container if it exists
  if sudo docker ps -a --format '{{.Names}}' | grep -q "^${MONGO_CONTAINER}$"; then
    log "Removing existing MongoDB container..."
    sudo docker rm -f "$MONGO_CONTAINER" || true
  fi

  log "Pulling MongoDB ${MONGO_VERSION} image (ARM64)..."
  sudo docker pull "mongo:${MONGO_VERSION}"

  log "Starting MongoDB container (${MONGO_CONTAINER})..."
  sudo docker run -d \
    --name "$MONGO_CONTAINER" \
    --restart always \
    -p "127.0.0.1:${MONGO_PORT}:27017" \
    -v gads-mongo-data:/data/db \
    "mongo:${MONGO_VERSION}"

  log "Waiting for MongoDB to be ready..."
  for i in $(seq 1 30); do
    if sudo docker exec "$MONGO_CONTAINER" mongosh --quiet --eval "db.runCommand({ping:1})" &>/dev/null; then
      log "MongoDB is ready."
      return 0
    fi
    sleep 1
  done
  err "MongoDB failed to start within 30s."
}

# ============================================================
# 3. Stop existing GADS services
# ============================================================
stop_gads() {
  log "Stopping existing GADS services (if running)..."
  sudo systemctl stop gads-hub gads-provider 2>/dev/null || true
}

# ============================================================
# 4. Extract GADS binary
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
# 5. Create systemd services
# ============================================================
create_services() {
  # Prompt for provider nickname
  if [[ -t 0 ]]; then
    echo ""
    read -r -p "Enter provider nickname [${PROVIDER_NICKNAME}]: " input_nickname
    PROVIDER_NICKNAME="${input_nickname:-$PROVIDER_NICKNAME}"
  fi

  HUB_SERVICE="/etc/systemd/system/gads-hub.service"
  log "Creating $HUB_SERVICE"

  sudo tee "$HUB_SERVICE" > /dev/null <<EOF
[Unit]
Description=GADS Hub
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=$GADS_USER
WorkingDirectory=$GADS_DIR
ExecStart=$GADS_DIR/GADS hub \\
  --host-address=$HUB_HOST \\
  --port=$HUB_PORT \\
  --auth=$HUB_AUTH \\
  --mongo-db=$MONGO_DSN
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
After=network.target gads-hub.service docker.service
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
  --mongo-db=$MONGO_DSN
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

# ============================================================
# 6. Enable and start GADS services
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
# 7. Show status
# ============================================================
show_status() {
  echo ""
  log "============================================"
  log "  Installation complete!"
  log "============================================"
  echo ""

  log "Docker / MongoDB container:"
  sudo docker ps --filter "name=${MONGO_CONTAINER}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
  echo ""
  log "Hub service status:"
  sudo systemctl status gads-hub --no-pager -l || true
  echo ""
  log "Provider service status:"
  sudo systemctl status gads-provider --no-pager -l || true

  echo ""
  log "Useful commands:"
  log "  sudo docker ps                          # Check MongoDB container"
  log "  sudo docker logs gads-mongodb           # MongoDB logs"
  log "  sudo systemctl status gads-hub"
  log "  sudo systemctl status gads-provider"
  log "  sudo journalctl -u gads-hub -f"
  log "  sudo journalctl -u gads-provider -f"
}

# ============================================================
# Run
# ============================================================
install_docker
start_mongodb
stop_gads
extract_gads
create_services
start_gads
show_status
