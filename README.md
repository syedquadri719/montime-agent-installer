# Montime.io Monitoring Agent

The **Montime.io Monitoring Agent** is a lightweight system agent that collects server metrics and sends them securely to Montime every 60 seconds.

It is designed to be:
- Easy to install (one command)
- Safe on modern Linux distributions
- Reliable in production
- Friendly for MSPs, freelancers, and small teams

---

## Features

- **CPU Usage** – real-time CPU utilization
- **Memory Usage** – RAM usage percentage
- **Disk Usage** – root filesystem (`/`) usage
- **Server Status** – online/offline detection
- **Secure Ingestion** – token-based authentication
- **Lightweight** – minimal CPU & memory overhead
- **Systemd Managed** – auto-restart and logging
- **Modern Linux Safe** – uses Python virtualenv (no system pip)

---

## Supported Platforms

- Ubuntu 20.04+
- Debian 11+
- Most modern Debian-based Linux systems

> Other distributions may work but are not officially supported yet.

---

## Quick Start (Recommended)

### 1. Get Your Server Token

1. Log in to your Montime dashboard
2. Go to **Dashboard → Add Server**
3. Copy the generated **Server Token**

---

### 2. Install the Agent (One Command)

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/syedquadri719/montime-agent-installer/main/install-montime-agent.sh)"
```
You will be prompted to enter your server token during installation.

### 3. Verify Installation
```systemctl status montime-agent```

View live logs:
```journalctl -u montime-agent -f
```
Once running, your server should appear online in the Montime dashboard within ~60 seconds.

### What the Installer Does

The installer automatically:

Installs required system packages (python3, python3-venv, etc.)

Downloads the latest agent.py

Creates an isolated Python virtual environment at:

```/opt/montime/venv```

Installs required Python dependencies (psutil, requests)

Creates and enables a systemd service named montime-agent
No manual pip installs are required.

###File Locations
Component	Path
Agent code	```/opt/montime/agent.py```
Python virtualenv	```/opt/montime/venv/```
Systemd service	```/etc/systemd/system/montime-agent.service```
Logs	```journalctl -u montime-agent```

###Configuration
Environment Variables

These are managed automatically by systemd.

Variable	Required	Description
SERVER_TOKEN	Yes	Unique token identifying the server
SERVER_URL	No	Metrics ingestion endpoint

###Default Ingest Endpoint
https://montime-mauve.vercel.app/api/metrics/ingest


This will switch to https://montime.io when production is finalized.


###Metrics Collected

Every 60 seconds, the agent sends:

CPU usage (%)

Memory usage (%)

Disk usage (%)

Timestamp

Server identity

{
  "cpu": 42.3,
  "memory": 68.9,
  "disk": 37.1
}

Authorization: Bearer <SERVER_TOKEN>
Content-Type: application/json

Troubleshooting
Agent Not Showing Online
systemctl status montime-agent
journalctl -u montime-agent -n 50


Check environment variables:

systemctl show montime-agent --property=Environment

Agent Crashes on Start

Re-run the installer safely:

sudo bash -c "$(curl -sL https://raw.githubusercontent.com/syedquadri719/montime-agent-installer/main/install-montime-agent.sh)"

Test Ingest Endpoint Manually
curl -X POST https://montime-mauve.vercel.app/api/metrics/ingest \
  -H "Authorization: Bearer YOUR_TOKEN_HERE" \
  -H "Content-Type: application/json" \
  -d '{"cpu":50,"memory":60,"disk":40}'

Uninstallation
sudo systemctl stop montime-agent
sudo systemctl disable montime-agent
sudo rm /etc/systemd/system/montime-agent.service
sudo systemctl daemon-reload
sudo rm -rf /opt/montime

Security Notes

Keep your server token secure

HTTPS-only communication

Requires outbound port 443

Runs inside isolated Python virtualenv

Auto-restarts on failure

Roadmap

Agent version reporting

Auto-update support

Debug / dry-run mode

Kubernetes support

AWS integrations

Support

Dashboard: https://montime.io/dashboard

Issues: GitHub Issues

Email: support@montime.io

License

MIT License
See LICENSE for details.
