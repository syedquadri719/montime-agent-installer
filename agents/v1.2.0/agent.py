#!/usr/bin/env python3
import os
import sys
sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')
import time
import json
import subprocess
from datetime import datetime, timezone

AGENT_VERSION = "v1.3.0"

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
METADATA_TIMEOUT = 1

# ----------------------------
# Logging
# ----------------------------
def log(message):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {message}", flush=True)

def log_detection(label, value=None, source=None, reason=None):
    if value:
        msg = f"{label} detected: {value}"
        if source:
            msg += f" (source={source})"
    else:
        msg = f"{label} unavailable"
        if reason:
            msg += f" (reason={reason})"
    log(msg)

# ----------------------------
# Token resolution
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
    log("ERROR: SERVER_TOKEN not found")
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
        r = subprocess.run(
            ["ping", "-c", "1", "-W", "2", PING_HOST],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=3,
        )
        return "up" if r.returncode == 0 else "down"
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
            with open("/etc/os-release") as f:
                for line in f:
                    if line.startswith("PRETTY_NAME="):
                        os_name = line.split("=", 1)[1].strip().strip('"')
                    elif line.startswith("VERSION_ID="):
                        os_version = line.split("=", 1)[1].strip().strip('"')

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
# Cloud detection
# ----------------------------
CLOUD_PROVIDER = None
INSTANCE_TYPE = None
DETECTION_SOURCE = None

def detect_cloud_provider():
    try:
        r = requests.get("http://metadata.google.internal", headers={"Metadata-Flavor": "Google"}, timeout=METADATA_TIMEOUT)
        if r.status_code == 200:
            return "gcp", "metadata"
    except:
        pass

    try:
        r = requests.get("http://169.254.169.254/latest/meta-data/instance-id", timeout=METADATA_TIMEOUT)
        if r.status_code == 200:
            return "aws", "metadata"
    except:
        pass

    try:
        r = requests.get("http://169.254.169.254/metadata/instance?api-version=2021-02-01", headers={"Metadata": "true"}, timeout=METADATA_TIMEOUT)
        if r.status_code == 200 and "compute" in r.text:
            return "azure", "metadata"
    except:
        pass

    try:
        r = requests.get("http://169.254.169.254/metadata/v1.json", timeout=METADATA_TIMEOUT)
        if r.status_code == 200 and "droplet_id" in r.text:
            return "digitalocean", "metadata"
    except:
        pass

    return "unknown", "unavailable"

def detect_instance_type_metadata(provider):
    try:
        if provider == "aws":
            return requests.get("http://169.254.169.254/latest/meta-data/instance-type", timeout=METADATA_TIMEOUT).text.strip()
        if provider == "gcp":
            r = requests.get(
                "http://metadata.google.internal/computeMetadata/v1/instance/machine-type",
                headers={"Metadata-Flavor": "Google"},
                timeout=METADATA_TIMEOUT,
            )
            return r.text.split("/")[-1]
        if provider == "azure":
            r = requests.get(
                "http://169.254.169.254/metadata/instance?api-version=2021-02-01",
                headers={"Metadata": "true"},
                timeout=METADATA_TIMEOUT,
            )
            return r.json()["compute"]["vmSize"]
    except:
        pass
    return None

def detect_instance_type_heuristic(provider):
    try:
        cpu = psutil.cpu_count(logical=True)
        mem_gb = round(psutil.virtual_memory().total / (1024 ** 3))

        if provider == "digitalocean":
            return f"s-{cpu}vcpu-{mem_gb}gb"
    except:
        pass
    return None

def initialize_environment():
    global CLOUD_PROVIDER, INSTANCE_TYPE, DETECTION_SOURCE

    CLOUD_PROVIDER, provider_source = detect_cloud_provider()
    log_detection("Cloud provider", CLOUD_PROVIDER, provider_source)

    instance = detect_instance_type_metadata(CLOUD_PROVIDER)
    if instance:
        INSTANCE_TYPE = instance
        DETECTION_SOURCE = "metadata"
        log_detection("Instance type", INSTANCE_TYPE, "metadata")
    else:
        heuristic = detect_instance_type_heuristic(CLOUD_PROVIDER)
        if heuristic:
            INSTANCE_TYPE = heuristic
            DETECTION_SOURCE = "heuristic"
            log_detection("Instance type", INSTANCE_TYPE, "heuristic")
        else:
            DETECTION_SOURCE = "unavailable"
            log_detection("Instance type", None, reason="not_exposed_by_metadata")

    log(f"Metadata payload preview: {{'cloud_provider': {CLOUD_PROVIDER}, 'instance_type': {INSTANCE_TYPE}, 'cloud_detection_source': {DETECTION_SOURCE}}}")

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
        "cloud_provider": CLOUD_PROVIDER,
        "instance_type": INSTANCE_TYPE,
        "cloud_detection_source": DETECTION_SOURCE,
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
# Main
# ----------------------------
def main():
    log("Montime Agent started")
    log(f"Agent version: {AGENT_VERSION}")
    log(f"Base URL: {BASE_URL}")
    log(f"Interval: {INTERVAL}s")

    initialize_environment()

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
