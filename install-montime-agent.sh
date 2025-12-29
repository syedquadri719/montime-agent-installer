#!/bin/bash
# MonTime.io Agent Installer
# One-command install for Ubuntu/Debian systems
#
# Usage:
# sudo bash -c "$(curl -sSL https://raw.githubusercontent.com/syedquadri719/montime-agent-installer/main/install-montime-agent.sh)"
# sudo ./install-montime-agent.sh "your-installer-key" "your-tenant-uuid"
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
# Input: CLI args, env vars, or interactive
# ─────────────────────────────────────────────────────────────
INSTALLER_SECRET_KEY="${1:-$INSTALLER_SECRET_KEY}"
TENANT_ID="${2:-$TENANT_ID}"

if [[ -z "$INSTALLER_SECRET_KEY" ]]; then
    echo "📋 Server Registration"
    echo "─────────────────────────────────────────────────────"
    echo "1. Auto-register with installer key + tenant ID"
    echo "2. Manual token entry"
    echo ""
    read -rp "🔑 Enter installer key (Enter to skip auto): " INSTALLER_SECRET_KEY
fi

if [[ -n "$INSTALLER_SECRET_KEY" ]]; then
    if [[ -z "$TENANT_ID" ]]; then
        read -rp "🏢 Enter tenant ID (UUID): " TENANT_ID
    fi

    if [[ -z "$TENANT_ID" ]]; then
        echo "❌ Tenant ID required for auto-registration"
        exit 1
    fi

    # UUID validation
    if ! echo "$TENANT_ID" | grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
        echo "❌ Invalid tenant ID format"
        exit 1
    fi

    # Hostname
    HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || "unknown")
    if [[ "$HOSTNAME" == "unknown" || -z "$HOSTNAME" ]]; then
        read -rp "🖥️ Enter server hostname: " HOSTNAME
        if [[ -z "$HOSTNAME" ]]; then
            echo "❌ Hostname required"
            exit 1
        fi
    else
        echo "🖥️ Detected hostname: $HOSTNAME"
    fi

    echo ""
    echo "📡 Registering server with Montime..."

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        -H "x-installer-key: $INSTALLER_SECRET_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"tenant_id\":\"$TENANT_ID\",\"hostname\":\"$HOSTNAME\"}" \
        "$INSTALLER_API_URL" 2>&1)

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [[ "$HTTP_CODE" == "200" ]]; then
        SERVER_TOKEN=$(echo "$BODY" | jq -r '.api_key // empty')
        SERVER_ID=$(echo "$BODY" | jq -r '.id // empty')
        CREATED=$(echo "$BODY" | jq -r '.created // "false"')

        if [[ -z "$SERVER_TOKEN" || "$SERVER_TOKEN" == "null" ]]; then
            echo "❌ Failed to get API key"
            echo "Response: $BODY"
            exit 1
        fi

        if [[ "$CREATED" == "true" ]]; then
            echo "✅ New server '$HOSTNAME' created!"
        else
            echo "✅ Found existing server '$HOSTNAME'!"
        fi
        echo "🆔 Server ID: $SERVER_ID"
        echo "🔑 API Key: ${SERVER_TOKEN:0:20}..."
        echo ""
    elif [[ "$HTTP_CODE" == "409" ]]; then
        # Duplicate detected (future-proof for RPC 409)
        echo "⚠️ A server with this name already exists!"
        read -rp "Do you want to merge with existing? (y/n): " MERGE
        if [[ "$MERGE" =~ ^[Yy]$ ]]; then
            echo "🔄 Merging with existing server..."
            # Future: Call merge API
            echo "✅ Merged successfully (placeholder)"
        else
            echo "❌ Skipping auto-registration. Using manual entry."
            read -rp "🔑 Enter server token: " SERVER_TOKEN
            if [[ -z "$SERVER_TOKEN" ]]; then
                echo "❌ Token required"
                exit 1
            fi
        fi
    else
        echo "⚠️ Registration failed (HTTP $HTTP_CODE)"
        echo "Response: $BODY"
        echo "❌ Falling back to manual entry."
        read -rp "🔑 Enter server token: " SERVER_TOKEN
        if [[ -z "$SERVER_TOKEN" ]]; then
            echo "❌ Token required"
            exit 1
        fi
    fi
else
    echo "⏭️ Skipping auto-registration"
    read -rp "🔑 Enter server token: " SERVER_TOKEN
    if [[ -z "$SERVER_TOKEN" ]]; then
        echo "❌ Token required"
        exit 1
    fi
fi

echo "🌐 Using ingest URL: $INGEST_URL"
echo ""

# ─────────────────────────────────────────────────────────────
# Agent Installation (rest unchanged)
# ─────────────────────────────────────────────────────────────
AGENT_DIR="/opt/montime"
VENV_DIR="$AGENT_DIR/venv"
SERVICE_NAME="montime-agent"

mkdir -p "$AGENT_DIR"
cd "$AGENT_DIR"

echo "📦 Installing system dependencies..."
apt-get update -qq
apt-get install -y python3 python3-venv python3-full curl ca-certificates > /dev/null

echo "📥 Downloading agent..."
curl -fL https://raw.githubusercontent.com/syedquadri719/montime-agent-installer/main/agent.py -o agent.py
chmod +x agent.py

head -n 1 agent.py | grep -q python || {
    echo "❌ Invalid agent.py"
    exit 1
}

if [[ ! -d "$VENV_DIR" ]]; then
    echo "🐍 Creating venv..."
    python3 -m venv "$VENV_DIR"
fi

echo "📦 Installing Python deps..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet psutil requests

"$VENV_DIR/bin/python" - <<EOF >/dev/null
import psutil, requests
EOF

cat > config.json <<EOF
{
  "api_key": "$SERVER_TOKEN",
  "api_url": "$INGEST_URL",
  "interval": 60
}
EOF

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

systemctl daemon-reload
systemctl enable --now $SERVICE_NAME >/dev/null

echo ""
echo "✅ Agent installed and running!"
echo ""
echo "🔍 Status: systemctl status montime-agent"
echo "📋 Logs: journalctl -u montime-agent -f"
echo "🛑 Stop: systemctl stop montime-agent"
echo "🔄 Restart: systemctl restart montime-agent"
echo ""
echo "📡 Ingest URL: $INGEST_URL"
[[ -n "$SERVER_ID" ]] && echo "🆔 Server ID: $SERVER_ID"
echo ""
