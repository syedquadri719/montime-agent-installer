#!/bin/bash

# MonTime.io Agent Installer
# One-command install for Ubuntu/Debian systems
# Single command install -- sudo bash -c "$(curl -sL https://raw.githubusercontent.com/syedquadri719/montime/main/install-montime-agent.sh)" -- YOUR_TOKEN_HERE https://montime-mauve.vercel.app

set -e

echo "🚀 Installing MonTime.io Monitoring Agent..."

# Check for root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (use sudo)"
   exit 1
fi

# Default values (change these or pass as args)
SERVER_TOKEN="${1:-YOUR_TOKEN_HERE}"
SERVER_URL="${2:-https://montime-mauve.vercel.app}"

if [[ "$SERVER_TOKEN" == "YOUR_TOKEN_HERE" || -z "$SERVER_TOKEN" ]]; then
    echo "❌ Usage: sudo bash install-montime-agent.sh <YOUR_SERVER_TOKEN> [SERVER_URL]"
    echo "   Example: sudo bash install-montime-agent.sh abc123def456 https://your-app.vercel.app"
    exit 1
fi

# Install directory
AGENT_DIR="/opt/montime"
mkdir -p "$AGENT_DIR"

# Download latest agent
echo "📥 Downloading agent..."
curl -sL https://raw.githubusercontent.com/syedquadri719/montime/main/agents/agent.py -o "$AGENT_DIR/agent.py"

# Make executable
chmod +x "$AGENT_DIR/agent.py"

# Create systemd service
echo "⚙️ Creating systemd service..."
cat > /etc/systemd/system/montime-agent.service <<EOF
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
ExecStart=/usr/bin/python3 $AGENT_DIR/agent.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=montime-agent

[Install]
WantedBy=multi-user.target
EOF

# Reload and start
systemctl daemon-reload
systemctl enable montime-agent
systemctl start montime-agent

echo "✅ MonTime.io agent installed and running!"
echo ""
echo "🔍 Status: systemctl status montime-agent"
echo "📋 Logs: journalctl -u montime-agent -f"
echo "🛑 Stop: systemctl stop montime-agent"
echo "🔄 Restart: systemctl restart montime-agent"
echo ""
echo "Your server is now being monitored at $SERVER_URL"
