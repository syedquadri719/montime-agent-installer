#!/bin/bash

# MonTime.io Agent Installer
# One-command install for Ubuntu/Debian systems
# Usage:
# sudo bash -c "$(curl -sL https://raw.githubusercontent.com/syedquadri719/montime-agent-installer/main/install-montime-agent.sh)"

set -e

echo "🚀 Installing MonTime.io Monitoring Agent..."

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
# Prompt for installer credentials
# ─────────────────────────────────────────────────────────────
echo ""
echo "📋 Server Registration"
echo "─────────────────────────────────────────────────────"
echo "This script can automatically register your server with Montime."
echo "You can either:"
echo "  1. Provide installer key and tenant ID for automatic registration"
echo "  2. Skip and manually enter a server token"
echo ""

# Prompt for installer key
read -rp "🔑 Enter installer key (or press Enter to skip auto-registration): " INSTALLER_SECRET_KEY

# Only prompt for tenant ID if installer key was provided
if [[ -n "$INSTALLER_SECRET_KEY" ]]; then
    # Prompt for tenant ID
    read -rp "🏢 Enter your tenant ID (UUID): " TENANT_ID
    
    if [[ -z "$TENANT_ID" ]]; then
        echo "❌ Tenant ID is required for automatic registration"
        exit 1
    fi
    
    # Basic UUID validation
    if ! echo "$TENANT_ID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -i; then
        echo "❌ Invalid tenant ID format. Please provide a valid UUID."
        exit 1
    fi
    
    # Get hostname automatically
    HOSTNAME=$(hostname 2>/dev/null || echo "")
    if [[ -z "$HOSTNAME" ]]; then
        read -rp "🖥️  Enter server hostname: " HOSTNAME
        if [[ -z "$HOSTNAME" ]]; then
            echo "❌ Hostname is required"
            exit 1
        fi
    else
        echo "🖥️  Detected hostname: $HOSTNAME"
    fi
    
    # Call find-or-create API using the prompted values
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
        # Extract API key from response
        if command -v jq &> /dev/null; then
            SERVER_TOKEN=$(echo "$BODY" | jq -r '.api_key')
            SERVER_ID=$(echo "$BODY" | jq -r '.id')
            CREATED=$(echo "$BODY" | jq -r '.created')
        else
            # Fallback: use grep and sed if jq is not available
            SERVER_TOKEN=$(echo "$BODY" | grep -o '"api_key":"[^"]*' | sed 's/"api_key":"//')
            SERVER_ID=$(echo "$BODY" | grep -o '"id":"[^"]*' | sed 's/"id":"//')
            CREATED=$(echo "$BODY" | grep -o '"created":[^,}]*' | grep -o '[tf][ru][el][us]')
        fi
        
        if [[ -z "$SERVER_TOKEN" ]] || [[ "$SERVER_TOKEN" == "null" ]]; then
            echo "❌ Failed to extract API key from response"
            echo "Response: $BODY"
            exit 1
        fi
        
        if [[ "$CREATED" == "true" ]]; then
            echo "✅ Server registered successfully (new server created)"
        else
            echo "✅ Server found (using existing registration)"
        fi
        echo "🆔 Server ID: $SERVER_ID"
        echo "🔑 API Key: ${SERVER_TOKEN:0:20}..."
        echo ""
    else
        echo "⚠️  Failed to auto-register server (HTTP $HTTP_CODE)"
        case "$HTTP_CODE" in
            401)
                echo "   Authentication failed. Check your installer key."
                ;;
            404)
                echo "   Tenant not found. Check your tenant ID."
                ;;
            403)
                echo "   Tenant access is suspended. Contact your administrator."
                ;;
            400)
                echo "   Invalid request. Check tenant_id and hostname."
                ;;
            *)
                echo "   Response: $BODY"
                ;;
        esac
        echo ""
        echo "❌ Automatic registration failed. Please try again or use manual token entry."
        exit 1
    fi
else
    # Manual token entry
    echo ""
    echo "⏭️  Skipping automatic registration"
    echo ""
    read -rp "🔑 Enter your server token: " SERVER_TOKEN
    
    if [[ -z "$SERVER_TOKEN" ]]; then
        echo "❌ Server token cannot be empty"
        exit 1
    fi
fi

echo "🌐 Using ingest URL: $INGEST_URL"

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
apt-get update
apt-get install -y \
  python3 \
  python3-venv \
  python3-full \
  curl \
  ca-certificates

# ─────────────────────────────────────────────────────────────
# Download agent
# ─────────────────────────────────────────────────────────────
echo "📥 Downloading agent..."
curl -fL \
  https://raw.githubusercontent.com/syedquadri719/montime-agent-installer/main/agent.py \
  -o "$AGENT_DIR/agent.py"

chmod +x "$AGENT_DIR/agent.py"

# Sanity check (prevents 404 saves)
head -n 1 "$AGENT_DIR/agent.py" | grep -q python || {
  echo "❌ agent.py does not look like a Python file"
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
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install psutil requests

# Validate deps
"$VENV_DIR/bin/python" - <<EOF
import psutil, requests
print("deps ok")
EOF

# ─────────────────────────────────────────────────────────────
# Create config file (optional, for agent reference)
# ─────────────────────────────────────────────────────────────
cat > "$AGENT_DIR/config.json" <<EOF
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
systemctl enable $SERVICE_NAME
systemctl reset-failed $SERVICE_NAME
systemctl restart $SERVICE_NAME

echo ""
echo "✅ MonTime.io agent installed and running!"
echo ""
echo "🔍 Status: systemctl status montime-agent"
echo "📋 Logs: journalctl -u montime-agent -f"
echo "🛑 Stop: systemctl stop montime-agent"
echo "🔄 Restart: systemctl restart montime-agent"
echo ""
echo "📡 Ingest URL: $INGEST_URL"
if [[ -n "$SERVER_ID" ]]; then
    echo "🆔 Server ID: $SERVER_ID"
fi
