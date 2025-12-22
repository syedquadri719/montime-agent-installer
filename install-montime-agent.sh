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
# Prompt for server token (interactive)
# ─────────────────────────────────────────────────────────────
read -rp "🔑 Enter your server token: " SERVER_TOKEN

if [[ -z "$SERVER_TOKEN" ]]; then
    echo "❌ Server token cannot be empty"
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# Default ingest URL (preview for now)
# ─────────────────────────────────────────────────────────────
SERVER_URL="https://montime-mauve.vercel.app/api/metrics/ingest"

echo "🌐 Using ingest URL: $SERVER_URL"

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
Environment="SERVER_URL=$SERVER_URL"
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
echo "📡 Ingest URL: $SERVER_URL"
