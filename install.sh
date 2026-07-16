#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# GADS Installation Script (Raspberry Pi 5)
# ============================================================
# Installs Docker, runs MongoDB in a container, extracts the
# GADS binary, sets up Auth0 SSO proxy (GadsAuth), and creates
# systemd hub + provider + gadsauth services.

# ---------- Configuration ----------
GADS_USER="${GADS_USER:-$USER}"
GADS_DIR="${GADS_DIR:-/home/$GADS_USER/GADS}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIP_FILE="$SCRIPT_DIR/GADS.zip"
GADSAUTH_SRC="$SCRIPT_DIR/GadsAuth"

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

# GadsAuth (SSO proxy) settings
GADS_DOMAIN="${GADS_DOMAIN:-gads-mac.assurecraft.com}"
GADS_PORT="${GADS_PORT:-10000}"
NGINX_PORT="${NGINX_PORT:-80}"
GADSAUTH_DIR="$GADS_DIR/GadsAuth"

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

if [[ ! -d "$GADSAUTH_SRC" ]]; then
  err "GadsAuth directory not found at $GADSAUTH_SRC"
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
  sudo systemctl stop gads-hub gads-provider gads-auth 2>/dev/null || true
  if [ -f "$GADSAUTH_DIR/docker-compose.yml" ]; then
    cd "$GADSAUTH_DIR" && sudo docker compose down 2>/dev/null || true
  fi
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
# 5. Install GadsAuth (SSO proxy)
# ============================================================
install_gadsauth() {
  log "Installing GadsAuth to $GADSAUTH_DIR..."
  sudo mkdir -p "$GADSAUTH_DIR"

  # Copy all GadsAuth files
  for f in app.py Dockerfile requirements.txt nginx-gads.conf docker-compose.yml .env.example; do
    if [ -f "$GADSAUTH_SRC/$f" ]; then
      sudo cp "$GADSAUTH_SRC/$f" "$GADSAUTH_DIR/"
      log "  Copied $f"
    fi
  done

  sudo chown -R "$GADS_USER:$GADS_USER" "$GADSAUTH_DIR"

  # Create .env from template if it doesn't exist
  if [ ! -f "$GADSAUTH_DIR/.env" ]; then
    log "Creating GadsAuth .env from template..."
    if [[ -t 0 ]]; then
      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "  Auth0 SSO Configuration"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
      read -r -p "Auth0 domain [dev-ogoo2r1doi6hafxg.us.auth0.com]: " input_auth0_domain
      AUTH0_DOMAIN="${input_auth0_domain:-dev-ogoo2r1doi6hafxg.us.auth0.com}"

      read -r -p "Auth0 Client ID: " input_client_id
      AUTH0_CLIENT_ID="${input_client_id}"

      read -r -p "Auth0 Client Secret: " input_client_secret
      AUTH0_CLIENT_SECRET="${input_client_secret}"

      read -r -p "GADS public domain [$GADS_DOMAIN]: " input_domain
      GADS_DOMAIN="${input_domain:-$GADS_DOMAIN}"

      read -r -p "GADS Origin claim for JWT [sso.assurecraft.com]: " input_origin
      GADS_ORIGIN="${input_origin:-sso.assurecraft.com}"

      read -r -p "GADS JWT Secret (from Add New Secret Key form): " input_jwt_secret
      GADS_JWT_SECRET="${input_jwt_secret}"

      read -r -p "Admin emails (comma-separated): " input_admins
      GADS_ADMIN_EMAILS="${input_admins}"

      FLASK_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || openssl rand -hex 32)

      sudo tee "$GADSAUTH_DIR/.env" > /dev/null <<EOF
# Generated by GADS installer — $(date)
FLASK_SECRET_KEY=$FLASK_SECRET_KEY

AUTH0_DOMAIN=$AUTH0_DOMAIN
AUTH0_CLIENT_ID=$AUTH0_CLIENT_ID
AUTH0_CLIENT_SECRET=$AUTH0_CLIENT_SECRET

REDIRECT_URI=https://${GADS_DOMAIN}/auth/callback
POST_LOGIN_DEFAULT=/

GADS_ORIGIN=$GADS_ORIGIN
GADS_JWT_SECRET=$GADS_JWT_SECRET
GADS_USER_CLAIM=username
GADS_TENANT_CLAIM=tenant
GADS_TENANT_VALUE=assurecraft
GADS_TOKEN_TTL_SECONDS=300

GADS_DEFAULT_ROLE=user
GADS_ADMIN_EMAILS=$GADS_ADMIN_EMAILS

GADS_PORT=$GADS_PORT
NGINX_PORT=$NGINX_PORT
EOF
    fi
  else
    log "GadsAuth .env already exists, skipping."
    # Still update GADS_PORT + NGINX_PORT in case they changed
    sudo sed -i "s/^GADS_PORT=.*/GADS_PORT=$GADS_PORT/" "$GADSAUTH_DIR/.env" 2>/dev/null || true
    sudo sed -i "s/^NGINX_PORT=.*/NGINX_PORT=$NGINX_PORT/" "$GADSAUTH_DIR/.env" 2>/dev/null || true
  fi

  sudo chown "$GADS_USER:$GADS_USER" "$GADSAUTH_DIR/.env"
  sudo chmod 600 "$GADSAUTH_DIR/.env"

  log "Building and starting GadsAuth containers..."
  cd "$GADSAUTH_DIR"
  sudo docker compose build
  sudo docker compose up -d
}

# ============================================================
# 6. Create systemd services
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

  # GadsAuth systemd service — ensures Docker Compose stack starts on boot
  AUTH_SERVICE="/etc/systemd/system/gads-auth.service"
  log "Creating $AUTH_SERVICE"

  sudo tee "$AUTH_SERVICE" > /dev/null <<EOF
[Unit]
Description=GADS SSO Proxy (Auth0)
After=network.target docker.service gads-hub.service
Requires=docker.service
Wants=gads-hub.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$GADS_USER
WorkingDirectory=$GADSAUTH_DIR
ExecStart=${GADSAUTH_DIR}/../docker-compose-start.sh 2>/dev/null || docker compose up -d
ExecStop=docker compose down
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  # Create a convenience start script
  sudo tee "$GADS_DIR/docker-compose-start.sh" > /dev/null <<'SCRIPT'
#!/usr/bin/env bash
cd "$(dirname "$0")/GadsAuth"
docker compose up -d
SCRIPT
  sudo chmod +x "$GADS_DIR/docker-compose-start.sh"
  sudo chown "$GADS_USER:$GADS_USER" "$GADS_DIR/docker-compose-start.sh"
}

# ============================================================
# 7. Enable and start GADS services
# ============================================================
start_gads() {
  log "Reloading systemd daemon..."
  sudo systemctl daemon-reload

  log "Enabling gads-hub, gads-provider, and gads-auth..."
  sudo systemctl enable gads-hub gads-provider gads-auth

  log "Starting gads-hub..."
  sudo systemctl start gads-hub
  sleep 5
  log "Starting gads-provider..."
  sudo systemctl start gads-provider
  sleep 2
  log "Starting gads-auth (SSO proxy)..."
  sudo systemctl start gads-auth
}

# ============================================================
# 8. Show status
# ============================================================
show_status() {
  echo ""
  log "============================================"
  log "  Installation complete!"
  log "============================================"
  echo ""

  log "Docker containers:"
  sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
  echo ""
  log "Hub service status:"
  sudo systemctl status gads-hub --no-pager -l 2>/dev/null || true
  echo ""
  log "Provider service status:"
  sudo systemctl status gads-provider --no-pager -l 2>/dev/null || true
  echo ""
  log "SSO proxy status:"
  sudo systemctl status gads-auth --no-pager -l 2>/dev/null || true

  echo ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "  GADS Hub:        http://localhost:${HUB_PORT}"
  log "  SSO Login:       https://${GADS_DOMAIN}/auth/login"
  log "  SSO Verify:      https://${GADS_DOMAIN}/auth/verify"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  log "Useful commands:"
  log "  sudo docker ps                              # All containers"
  log "  sudo docker logs gads-mongodb               # MongoDB logs"
  log "  sudo docker logs gads-sso-proxy             # SSO proxy logs"
  log "  sudo docker logs gads-nginx                 # nginx logs"
  log "  sudo systemctl status gads-hub"
  log "  sudo systemctl status gads-provider"
  log "  sudo systemctl status gads-auth"
  log "  sudo journalctl -u gads-hub -f"
  log "  sudo journalctl -u gads-auth -f"
  log ""
  log "To reconfigure SSO:  edit $GADSAUTH_DIR/.env then run:"
  log "  cd $GADSAUTH_DIR && docker compose up -d --build"
}

# ============================================================
# Run
# ============================================================
install_docker
start_mongodb
stop_gads
extract_gads
install_gadsauth
create_services
start_gads
show_status
