#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# GADS Installation Script
# ============================================================
# Extracts the GADS binary, creates systemd hub + provider
# services, and starts them.

# ---------- Configuration ----------
GADS_USER="${GADS_USER:-$USER}"
GADS_DIR="${GADS_DIR:-/home/$GADS_USER/GADS}"
ZIP_FILE="$(cd "$(dirname "$0")" && pwd)/GADS.zip"

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

# ---------- Stop existing services ----------
log "Stopping existing services (if running)..."
sudo systemctl stop gads-hub gads-provider 2>/dev/null || true

# ---------- Create working directory ----------
log "Creating working directory: $GADS_DIR"
sudo mkdir -p "$GADS_DIR"

# ---------- Extract binary ----------
log "Extracting GADS binary..."
sudo unzip -o "$ZIP_FILE" -d "$GADS_DIR"

log "Making GADS executable..."
sudo chmod +x "$GADS_DIR/GADS"

# ---------- Set ownership ----------
log "Setting ownership to $GADS_USER..."
sudo chown -R "$GADS_USER:$GADS_USER" "$GADS_DIR"

# ---------- Create systemd service: gads-hub ----------
HUB_SERVICE="/etc/systemd/system/gads-hub.service"
log "Creating $HUB_SERVICE"

sudo tee "$HUB_SERVICE" > /dev/null <<EOF
[Unit]
Description=GADS Hub
After=network.target

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

# ---------- Create systemd service: gads-provider ----------
PROVIDER_SERVICE="/etc/systemd/system/gads-provider.service"
log "Creating $PROVIDER_SERVICE"

sudo tee "$PROVIDER_SERVICE" > /dev/null <<EOF
[Unit]
Description=GADS Provider
After=network.target gads-hub.service
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

# ---------- Reload systemd ----------
log "Reloading systemd daemon..."
sudo systemctl daemon-reload

# ---------- Enable services ----------
log "Enabling gads-hub and gads-provider..."
sudo systemctl enable gads-hub gads-provider

# ---------- Start services ----------
log "Starting gads-hub..."
sudo systemctl start gads-hub
sleep 5
log "Starting gads-provider..."
sudo systemctl start gads-provider

# ---------- Status ----------
echo ""
log "============================================"
log "  Installation complete!"
log "============================================"
echo ""

log "Hub service status:"
sudo systemctl status gads-hub --no-pager -l || true
echo ""
log "Provider service status:"
sudo systemctl status gads-provider --no-pager -l || true

echo ""
log "Useful commands:"
log "  sudo systemctl status gads-hub"
log "  sudo systemctl status gads-provider"
log "  sudo journalctl -u gads-hub -f"
log "  sudo journalctl -u gads-provider -f"
