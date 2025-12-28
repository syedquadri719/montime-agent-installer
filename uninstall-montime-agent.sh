#!/bin/bash
# MonTime.io Agent Uninstaller
# Removes the agent, service, virtual environment, and all related files
set -e

echo "🛑 MonTime.io Agent Uninstaller"
echo ""

# Root check
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root (use sudo)"
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# User confirmation
# ─────────────────────────────────────────────────────────────
read -rp "Are you sure you want to uninstall the Montime agent? This will immediately stop sending metrics to Montime. (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "⚠️  Uninstall cancelled."
    exit 0
fi

echo ""
echo "🛑 Stopping and disabling service..."

# Stop and disable service if running
if systemctl is-active --quiet montime-agent; then
    systemctl stop montime-agent
fi
if systemctl is-enabled --quiet montime-agent; then
    systemctl disable montime-agent
fi

# Remove service files
echo "🗑️  Removing systemd service files..."
rm -f /etc/systemd/system/montime-agent.service
rm -rf /etc/systemd/system/montime-agent.service.d
systemctl daemon-reload
systemctl reset-failed montime-agent || true

# Remove agent directory and virtual environment
echo "🗑️  Removing agent files and virtual environment..."
rm -rf /opt/montime

echo ""
echo "✅ Montime.io agent completely uninstalled!"
echo "   No more metrics will be sent."
echo ""
echo "To reinstall, run:"
echo "sudo bash -c "$(curl -sL https://raw.githubusercontent.com/syedquadri719/montime-agent-installer/main/install-montime-agent.sh)""
echo ""
