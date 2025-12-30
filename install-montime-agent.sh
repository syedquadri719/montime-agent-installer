#!/bin/bash
# MonTime.io Agent Installer
# Ubuntu / Debian
#
# Usage:
# sudo bash install-montime-agent.sh [installer-key] [tenant-uuid]
set -euo pipefail

echo "🚀 Installing MonTime.io Monitoring Agent"
echo ""

# Root check
if [[ $EUID -ne 0 ]]; then
  echo "❌ This script must be run as root (use sudo)"
  exit 1
fi

# Configuration
BASE_URL="${BASE_URL:-https://www.montime.io}"
INSTALLER_API_URL="$BASE_URL/api/servers"
INGEST_URL="$BASE_URL/api/metrics/ingest"
GITHUB_REPO="syedquadri719/montime-agent-installer"
AGENTS_PATH="agents"
GITHUB_API_URL="https://api.github.com/repos/$GITHUB_REPO/contents/$AGENTS_PATH"
DEFAULT_AGENT_VERSION="v1.1.0"

AGENT_DIR="/opt/montime"
VENV_DIR="$AGENT_DIR/venv"
ENV_DIR="/etc/montime"
ENV_FILE="$ENV_DIR/agent.env"
SERVICE_NAME="montime-agent"

# Input: CLI args take priority
INSTALLER_SECRET_KEY="${1:-}"
TENANT_ID="${2:-}"

# If no installer key, fall back to interactive
if [[ -z "$INSTALLER_SECRET_KEY" ]]; then
  echo "📋 Server Registration"
  echo "────────────────────────────────────────────"
  echo "1) Auto-register with installer key"
  echo "2) Manual token entry"
  echo ""
  read -rp "🔑 Enter installer key (or press Enter to skip): " INSTALLER_SECRET_KEY
fi

SERVER_TOKEN=""

if [[ -n "$INSTALLER_SECRET_KEY" ]]; then
  # Ensure tenant ID
  if [[ -z "$TENANT_ID" ]]; then
    read -rp "🏢 Enter tenant ID (UUID): " TENANT_ID
  fi

  if ! [[ "$TENANT_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "❌ Invalid tenant ID format"
    exit 1
  fi

  # Get hostname/display name
  SUGGESTED_NAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || "unknown")
  if [[ "$SUGGESTED_NAME" == "unknown" ]]; then
    read -rp "🖥️ Enter server name: " SUGGESTED_NAME
  else
    echo "🖥️ Detected hostname: $SUGGESTED_NAME"
    if [[ -z "$1" || -z "$2" ]]; then  # Only prompt if interactive
      read -rp "Use '$SUGGESTED_NAME' as server name? (Y/n): " USE_IT
      if [[ "$USE_IT" =~ ^[Nn]$ ]]; then
        read -rp "Enter custom server name: " SUGGESTED_NAME
      fi
    fi
  fi

  if [[ -z "$SUGGESTED_NAME" ]]; then
    echo "❌ Server name required"
    exit 1
  fi

  echo ""
  echo "📡 Registering server '$SUGGESTED_NAME'..."

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "x-installer-key: $INSTALLER_SECRET_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"tenant_id\":\"$TENANT_ID\",\"display_name\":\"$SUGGESTED_NAME\"}" \
    "$INSTALLER_API_URL")

  BODY=$(curl -s -X POST \
    -H "x-installer-key: $INSTALLER_SECRET_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"tenant_id\":\"$TENANT_ID\",\"display_name\":\"$SUGGESTED_NAME\"}" \
    "$INSTALLER_API_URL")

  if [[ "$HTTP_CODE" == "200" ]]; then
    SERVER_TOKEN=$(echo "$BODY" | jq -r '.api_key')
    SERVER_ID=$(echo "$BODY" | jq -r '.id')
    CREATED=$(echo "$BODY" | jq -r '.created')

    if [[ "$CREATED" == "true" ]]; then
      echo "✅ New server created!"
    else
      echo "✅ Connected to existing server"
    fi
    echo "🆔 Server ID: $SERVER_ID"
    echo "🔑 API Key: ${SERVER_TOKEN:0:20}..."
  else
    echo "⚠️ Auto-registration failed (HTTP $HTTP_CODE)"
    echo "Response: $BODY"
    echo "Falling back to manual token"
    read -rp "🔑 Enter server token: " SERVER_TOKEN
  fi
else
  read -rp "🔑 Enter server token: " SERVER_TOKEN
fi

if [[ -z "$SERVER_TOKEN" ]]; then
  echo "❌ Server token required"
  exit 1
fi
# ─────────────────────────────────────────────────────────────
# Agent version selection
# ─────────────────────────────────────────────────────────────
echo "🔍 Fetching available agent versions..."
VERSIONS_JSON=$(curl -fsSL "$GITHUB_API_URL" || true)
if [[ -z "$VERSIONS_JSON" ]]; then
  AGENT_VERSION="$DEFAULT_AGENT_VERSION"
else
  mapfile -t VERSIONS < <(
    echo "$VERSIONS_JSON" | jq -r '.[] | select(.type=="dir") | .name' | sort -V
  )
  if [[ ${#VERSIONS[@]} -eq 0 ]]; then
    AGENT_VERSION="$DEFAULT_AGENT_VERSION"
  else
    echo ""
    echo "📦 Available Agent Versions"
    echo "────────────────────────────────────────────"
    for i in "${!VERSIONS[@]}"; do
      printf "%2d) %s\n" "$((i+1))" "${VERSIONS[$i]}"
    done
    echo ""
    read -rp "👉 Select version [default: latest]: " CHOICE
    if [[ -z "$CHOICE" ]]; then
      AGENT_VERSION="${VERSIONS[-1]}"
    elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && ((CHOICE >= 1 && CHOICE <= ${#VERSIONS[@]})); then
      AGENT_VERSION="${VERSIONS[$((CHOICE-1))]}"
    else
      AGENT_VERSION="${VERSIONS[-1]}"
    fi
  fi
fi
echo "✅ Using agent version: $AGENT_VERSION"
echo ""

# ─────────────────────────────────────────────────────────────
# Install dependencies
# ─────────────────────────────────────────────────────────────
mkdir -p "$AGENT_DIR" "$ENV_DIR"
cd "$AGENT_DIR"

echo "📦 Installing system dependencies..."
apt-get update -qq
apt-get install -y python3 python3-venv python3-full curl ca-certificates jq > /dev/null

# ─────────────────────────────────────────────────────────────
# Download agent
# ─────────────────────────────────────────────────────────────
AGENT_URL="https://raw.githubusercontent.com/$GITHUB_REPO/main/agents/$AGENT_VERSION/agent.py"
echo "📥 Downloading agent v$AGENT_VERSION"
curl -fL "$AGENT_URL" -o agent.py
chmod +x agent.py

echo "$AGENT_VERSION" > agent_version

# ─────────────────────────────────────────────────────────────
# Python environment
# ─────────────────────────────────────────────────────────────
if [[ ! -d "$VENV_DIR" ]]; then
  echo "🐍 Creating Python venv..."
  python3 -m venv "$VENV_DIR"
fi

echo "📦 Installing Python dependencies..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet psutil requests

# ─────────────────────────────────────────────────────────────
# Environment file
# ─────────────────────────────────────────────────────────────
cat > "$ENV_FILE" <<EOF
SERVER_TOKEN=$SERVER_TOKEN
BASE_URL=$BASE_URL
INGEST_URL=$INGEST_URL
AGENT_VERSION=$AGENT_VERSION
EOF
chmod 600 "$ENV_FILE"

# ─────────────────────────────────────────────────────────────
# systemd service
# ─────────────────────────────────────────────────────────────
echo "⚙️ Creating systemd service..."
cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=MonTime.io Monitoring Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$AGENT_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$VENV_DIR/bin/python $AGENT_DIR/agent.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=montime-agent

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now $SERVICE_NAME >/dev/null

echo ""
echo "✅ MonTime Agent v$AGENT_VERSION Installed Successfully!"
echo ""
echo "🔍 Status: systemctl status $SERVICE_NAME"
echo "📋 Logs: journalctl -u $SERVICE_NAME -f"
echo "🔄 Restart: systemctl restart $SERVICE_NAME"
echo "🛑 Stop: systemctl stop $SERVICE_NAME"
echo ""
echo "📡 Ingest URL: $INGEST_URL"
[[ -n "${SERVER_ID:-}" ]] && echo "🆔 Server ID: $SERVER_ID"
echo ""
