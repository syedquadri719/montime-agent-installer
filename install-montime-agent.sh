#!/bin/bash
# MonTime.io Agent Installer
# One-command install for Ubuntu/Debian systems
#
# Usage examples:
#   sudo bash -c "$(curl -sSL https://raw.githubusercontent.com/syedquadri719/montime-agent-installer/main/install-montime-agent.sh)"
#   sudo ./install-montime-agent.sh "your-installer-key" "your-tenant-uuid"
#   sudo INSTALLER_KEY="key" TENANT_ID="uuid" bash -c "$(curl -sSL ...)"
set -e

echo "🚀 Installing MonTime.io Monitoring Agent..."
echo ""

# ─────────────────────────────────────────────────────────────
# Root check
# ─────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (use sudo)"
   exit 1
fi

# ─────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────
BASE_URL="${BASE_URL:-https://www.montime.io}"
INSTALLER_API_URL="$BASE_URL/api/servers"
INGEST_URL="$BASE_URL/api/metrics/ingest"

# ─────────────────────────────────────────────────────────────
# Input: Support CLI args or environment vars or interactive
# ─────────────────────────────────────────────────────────────
INSTALLER_SECRET_KEY="${1:-$INSTALLER_SECRET_KEY}"
TENANT_ID="${2:-$TENANT_ID}"

if [[ -z "$INSTALLER_SECRET_KEY" ]]; then
    echo "📋 Server Registration"
    echo "─────────────────────────────────────────────────────"
    echo "This script can automatically register your server with Montime."
    echo "You can either:"
    echo "  1. Provide installer key and tenant ID for automatic registration"
    echo "  2. Skip and manually enter a server token"
    echo ""
    read -rp "🔑 Enter installer key (or press Enter to skip auto-registration): " INSTALLER_SECRET_KEY
fi

if [[ -n "$INSTALLER_SECRET_KEY" ]]; then
    if [[ -z "$TENANT_ID" ]]; then
        read -rp "🏢 Enter your tenant ID (UUID): " TENANT_ID
    fi

    if [[ -z "$TENANT_ID" ]]; then
        echo "❌ Tenant ID is required for automatic registration"
        exit 1
    fi

    # Basic UUID validation
    if ! echo "$TENANT_ID" | grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
        echo "❌ Invalid tenant ID format. Must be a valid UUID."
        exit 1
    fi

    # Get hostname
    HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown")
    if [[ "$HOSTNAME" == "unknown" || -z "$HOSTNAME" ]]; then
        read -rp "🖥️ Enter server hostname: " HOSTNAME
        if [[ -z "$HOSTNAME" ]]; then
            echo "❌ Hostname is required"
            exit 1
        fi
    else
        echo "🖥️ Detected hostname: $HOSTNAME"
    fi

    echo ""
    echo "📡 Registering server with Montime..."

    # Reliable HTTP code + body capture
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "x-installer-key: $INSTALLER_SECRET_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"tenant_id\":\"$TENANT_ID\",\"hostname\":\"$HOSTNAME\"}" \
        "$INSTALLER_API_URL")

    BODY=$(curl -s -X POST \
        -H "x-installer-key: $INSTALLER_SECRET_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"tenant_id\":\"$TENANT_ID\",\"hostname\":\"$HOSTNAME\"}" \
        "$INSTALLER_API_URL")

    if [[ "$HTTP_CODE" == "200" ]]; then
        SERVER_TOKEN=$(echo "$BODY" | jq -r '.api_key // empty')
        SERVER_ID=$(echo "$BODY" | jq -r '.id // empty')
        CREATED=$(echo "$BODY" | jq -r '.created // "false"')

        if [[ -z "$SERVER_TOKEN" || "$SERVER_TOKEN" == "null" ]]; then
            echo "❌ Failed to extract API key from response"
            echo "Response: $BODY"
            exit 1
        fi

        if [[ "$CREATED" == "true" ]]; then
            echo "✅ New server '$HOSTNAME' created and registered!"
        else
            echo "✅ Found existing server '$HOSTNAME' — connected successfully"
        fi
        echo "🆔 Server ID: $SERVER_ID"
        echo "🔑 API Key: ${SERVER_TOKEN:0:20}..."
        echo ""
    else
        echo "⚠️ Auto-registration failed (HTTP $HTTP_CODE)"
        case "$HTTP_CODE" in
            401) echo "   → Invalid installer key" ;;
            404) echo "   → Tenant not found" ;;
            403) echo "   → Tenant suspended" ;;
            400) echo "   → Bad request (check tenant ID / hostname)" ;;
            *)   echo "   Response: $BODY" ;;
        esac
        echo ""
        echo "❌ Automatic registration failed. Falling back to manual token entry."
        echo ""
        read -rp "🔑 Enter your server token manually: " SERVER_TOKEN
        if [[ -z "$SERVER_TOKEN" ]]; then
            echo "❌ Server token cannot be empty"
            exit 1
        fi
    fi
else
    echo "⏭️ Skipping automatic registration"
    echo ""
    read -rp "🔑 Enter your server token manually: " SERVER_TOKEN
    if [[ -z "$SERVER_TOKEN" ]]; then
        echo "❌ Server token cannot be empty"
        exit 1
    fi
fi

echo "🌐 Using ingest URL: $INGEST_URL"
echo ""

# ─────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────
AGENT_DIR="/opt/montime"
VENV_DIR="$AGENT_DIR/venv"
SERVICE_NAME="montime-agent"

mkdir -p "$AGENT_DIR"
cd "$AGENT_DIR"

# ─────────────────────────────────────────────────────────────
# System dependencies
# ─────────────────────────────────────────────────────────────
echo "📦 Installing system dependencies..."
apt-get update -qq
apt-get install -y python3 python3-venv python3-full curl ca-certificates > /dev/null

# ─────────────────────────────────────────────────────────────
# Download agent
# ─────────────────────────────────────────────────────────────
echo "📥 Downloading agent..."
curl -fL https://raw.githubusercontent.com/syedquadri719/montime-agent-installer/main/agent.py -o agent.py
chmod +x agent.py

# Sanity check
head -n 1 agent.py | grep -q python || {
    echo "❌ Failed to download valid agent.py"
    exit 1
}

# ─────────────────────────────────────────────────────────────
# Python virtual environment
# ─────────────────────────────────────────────────────────────
if [[ ! -d "$VENV_DIR" ]]; then
    echo "🐍 Creating Python virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

# ─────────────────────────────────────────────────────────────
# Python dependencies
# ─────────────────────────────────────────────────────────────
echo "📦 Installing Python dependencies..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet psutil requests

# Validate
"$VENV_DIR/bin/python" - <<EOF >/dev/null
import psutil, requests
print("deps ok")
EOF

# ─────────────────────────────────────────────────────────────
# Config file (for reference)
# ─────────────────────────────────────────────────────────────
cat > config.json <<EOF
{
  "api_key": "$SERVER_TOKEN",
  "api_url": "$INGEST_URL",
  "interval": 60
}
EOF

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
Environment="SERVER_TOKEN=$SERVER_TOKEN"
Environment="SERVER_URL=$INGEST_URL"
ExecStart=$VENV_DIR/bin/python $AGENT_DIR/agent.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=montime-agent

[Install]
WantedBy=multi-user.target
EOF

# ─────────────────────────────────────────────────────────────
# Enable & start
# ─────────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable --now $SERVICE_NAME >/dev/null

echo ""
echo "✅ MonTime.io agent installed and running!"
echo ""
echo "🔍 Status: systemctl status montime-agent"
echo "📋 Logs: journalctl -u montime-agent -f"
echo "🛑 Stop: systemctl stop montime-agent"
echo "🔄 Restart: systemctl restart montime-agent"
echo ""
echo "📡 Ingest URL: $INGEST_URL"
[[ -n "$SERVER_ID" ]] && echo "🆔 Server ID: $SERVER_ID"
echo ""
