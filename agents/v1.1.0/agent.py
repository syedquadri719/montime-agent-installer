#!/usr/bin/env python3
import os
import sys
import time
import json
import subprocess
from datetime import datetime

AGENT_VERSION = "v1.1.0"

# ----------------------------
# Dependency bootstrap
# ----------------------------
try:
    import psutil
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "psutil"])
    import psutil

try:
    import requests
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "requests"])
    import requests

# ----------------------------
# Constants
# ----------------------------
DEFAULT_BASE_URL = "https://www.montime.io"
PING_HOST = "8.8.8.8"
INTERVAL = 60
MAX_RETRIES = 3
RETRY_DELAY = 5

# ----------------------------
# Logging
# ----------------------------
def log(message):
    ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {message}", flush=True)

# ----------------------------
# Token resolution (CRITICAL FIX)
# ----------------------------
def load_config_token():
    try:
        with open("config.json", "r") as f:
            return json.load(f).get("api_key")
    except Exception:
        return None

SERVER_TOKEN = os.getenv("SERVER_TOKEN") or load_config_token()
BASE_URL = os.getenv("BASE_URL", DEFAULT_BASE_URL)

if not SERVER_TOKEN:
    log("ERROR: SERVER_TOKEN not found (env or config.json)")
    sys.exit(1)

# ----------------------------
# Metrics helpers
# ----------------------------
def get_cpu_usage():
    return round(psutil.cpu_percent(interval=1), 2)

def get_memory_usage():
    return round(psutil.virtual_memory().percent, 2)

def get_disk_usage():
    return round(psutil.disk_usage("/").percent, 2)

def check_connectivity():
    try:
        result = subprocess.run(
            ["ping", "-c", "1", "-W", "2", PING_HOST],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=3,
        )
        return "up" if result.returncode == 0 else "down"
    except Exception:
        return "down"

# ----------------------------
# OS detection (cached)
# ----------------------------
_os_cache = None

def detect_os():
    global _os_cache
    if _os_cache:
        return _os_cache

    os_type = os_name = os_version = None

    try:
        if sys.platform.startswith("linux"):
            os_type = "linux"
            try:
                with open("/etc/os-release") as f:
                    for line in f:
                        if line.startswith("PRETTY_NAME="):
                            os_name = line.split("=", 1)[1].strip().strip('"')
                        elif line.startswith("VERSION_ID="):
                            os_version = line.split("=", 1)[1].strip().strip('"')
            except Exception:
                pass

        elif sys.platform.startswith("win"):
            import platform
            os_type = "windows"
            os_name = platform.system()
            os_version = platform.release()

    except Exception:
        pass

    _os_cache = (os_type, os_name, os_version)
    return _os_cache

# ----------------------------
# Send metrics
# ----------------------------
def send_metrics(cpu, memory, disk, status):
    os_type, os_name, os_version = detect_os()

    payload = {
        "cpu": cpu,
        "memory": memory,
        "disk": disk,
        "status": status,
        "agent_version": AGENT_VERSION,
    }

    if os_type:
        payload["os_type"] = os_type
    if os_name:
        payload["os_name"] = os_name
    if os_version:
        payload["os_version"] = os_version

    headers = {
        "Authorization": f"Bearer {SERVER_TOKEN}",
        "Content-Type": "application/json",
    }

    url = f"{BASE_URL}/api/metrics/ingest"

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            r = requests.post(url, json=payload, headers=headers, timeout=10)
            if r.status_code == 200:
                log(f"✓ Metrics sent (CPU {cpu}%, MEM {memory}%, DISK {disk}%)")
                return
            else:
                log(f"✗ HTTP {r.status_code}, retry {attempt}/{MAX_RETRIES}")
        except Exception as e:
            log(f"✗ Send error: {e}")

        time.sleep(RETRY_DELAY)

# ----------------------------
# Main loop
# ----------------------------
def main():
    log("MonTime Agent started")
    log(f"Agent version: {AGENT_VERSION}")
    log(f"Base URL: {BASE_URL}")
    log(f"Interval: {INTERVAL}s")

    while True:
        try:
            send_metrics(
                get_cpu_usage(),
                get_memory_usage(),
                get_disk_usage(),
                check_connectivity(),
            )
        except KeyboardInterrupt:
            log("Agent stopped")
            sys.exit(0)
        except Exception as e:
            log(f"Unexpected error: {e}")

        time.sleep(INTERVAL)

if __name__ == "__main__":
    main()
