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






