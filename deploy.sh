#!/usr/bin/env bash
# =============================================================================
# deploy.sh — copy files to Hetzner and start services
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh
#
# Prerequisites:
#   1. SSH alias "hetzner" configured in ~/.ssh/config
#   2. .env file exists and is filled out (copy from .env.example)
#   3. Domain DNS A records pointing to 37.27.203.157
# =============================================================================

set -euo pipefail

SSH_ALIAS="hetzner"
REMOTE_DIR="/opt/traefik-fastapi"

# ---- Sanity checks ----------------------------------------------------------
if [ ! -f .env ]; then
  echo "ERROR: .env file not found. Copy .env.example to .env and fill it in."
  exit 1
fi

echo ""
echo "==========================================="
echo " Deploying to Hetzner ($SSH_ALIAS)"
echo "==========================================="

# ---- 1. Install Docker on the server (idempotent) ---------------------------
echo ""
echo "[1/5] Checking Docker on server..."
ssh "$SSH_ALIAS" '
  if ! command -v docker &>/dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
  else
    echo "Docker already installed: $(docker --version)"
  fi
'

# ---- 2. Create remote directory structure -----------------------------------
echo ""
echo "[2/5] Creating remote directories..."
ssh "$SSH_ALIAS" "mkdir -p $REMOTE_DIR/app $REMOTE_DIR/traefik"

# ---- 3. Copy project files --------------------------------------------------
echo ""
echo "[3/5] Copying files..."
scp docker-compose.yml        "$SSH_ALIAS:$REMOTE_DIR/"
scp .env                      "$SSH_ALIAS:$REMOTE_DIR/"
scp traefik/traefik.yml       "$SSH_ALIAS:$REMOTE_DIR/traefik/"
scp app/main.py               "$SSH_ALIAS:$REMOTE_DIR/app/"
scp app/requirements.txt      "$SSH_ALIAS:$REMOTE_DIR/app/"
scp app/Dockerfile            "$SSH_ALIAS:$REMOTE_DIR/app/"

# ---- 4. Set up acme.json with correct permissions ---------------------------
echo ""
echo "[4/5] Setting up acme.json (must be chmod 600)..."
ssh "$SSH_ALIAS" "
  touch $REMOTE_DIR/traefik/acme.json
  chmod 600 $REMOTE_DIR/traefik/acme.json
  echo 'acme.json: OK'
"

# ---- 5. Start services ------------------------------------------------------
echo ""
echo "[5/5] Starting services..."
ssh "$SSH_ALIAS" "
  cd $REMOTE_DIR
  docker compose pull traefik 2>/dev/null || true
  docker compose up -d --build
  echo ''
  echo 'Running containers:'
  docker compose ps
"

# ---- Done -------------------------------------------------------------------
DOMAIN=$(grep '^DOMAIN=' .env | cut -d= -f2)
echo ""
echo "==========================================="
echo " Deployment complete!"
echo "==========================================="
echo ""
echo "  API:       https://api.$DOMAIN"
echo "  API docs:  https://api.$DOMAIN/docs"
echo "  Dashboard: https://traefik.$DOMAIN"
echo ""
echo "Note: Let's Encrypt certificates may take up to 60 seconds on first boot."
echo "      Watch logs with:  ssh $SSH_ALIAS 'cd $REMOTE_DIR && docker compose logs -f'"
echo ""
