#!/usr/bin/env python3

import os
import sys
import time
import json
import subprocess
from datetime import datetime

try:
    import psutil
except ImportError:
    print("psutil not found. Installing...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "psutil"])
    import psutil

try:
    import requests
except ImportError:
    print("requests not found. Installing...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "requests"])
    import requests


SERVER_TOKEN = os.environ.get('SERVER_TOKEN')
BASE_URL = os.environ.get('BASE_URL', 'https://www.montime.io')
PING_HOST = '8.8.8.8'
INTERVAL = 60
MAX_RETRIES = 3
RETRY_DELAY = 5


def log(message):
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    print(f"[{timestamp}] {message}", flush=True)


def get_cpu_usage():
    return round(psutil.cpu_percent(interval=1), 2)


def get_memory_usage():
    memory = psutil.virtual_memory()
    return round(memory.percent, 2)


def get_disk_usage():
    disk = psutil.disk_usage('/')
    return round(disk.percent, 2)


def check_connectivity():
    try:
        result = subprocess.run(
            ['ping', '-c', '1', '-W', '2', PING_HOST],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=3
        )
        return 'up' if result.returncode == 0 else 'down'
    except Exception:
        return 'down'


def send_metrics(cpu, memory, disk, status):
    url = f"{BASE_URL}/api/metrics/ingest"
    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {SERVER_TOKEN}'
    }
    payload = {
        'cpu': cpu,
        'memory': memory,
        'disk': disk,
        'status': status
    }

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            response = requests.post(url, json=payload, headers=headers, timeout=10)

            if response.status_code == 200:
                log(f"✓ Sent metrics OK (CPU: {cpu}%, MEM: {memory}%, DISK: {disk}%, STATUS: {status})")
                return True
            else:
                if attempt < MAX_RETRIES:
                    log(f"✗ Failed to send metrics (HTTP {response.status_code}). Retrying in {RETRY_DELAY}s... ({attempt}/{MAX_RETRIES})")
                    time.sleep(RETRY_DELAY)
                else:
                    log(f"✗ Failed to send metrics after {MAX_RETRIES} attempts (HTTP {response.status_code})")
                    return False

        except requests.exceptions.RequestException as e:
            if attempt < MAX_RETRIES:
                log(f"✗ Request error: {str(e)}. Retrying in {RETRY_DELAY}s... ({attempt}/{MAX_RETRIES})")
                time.sleep(RETRY_DELAY)
            else:
                log(f"✗ Failed to send metrics after {MAX_RETRIES} attempts: {str(e)}")
                return False

    return False


def main():
    if not SERVER_TOKEN:
        log("ERROR: SERVER_TOKEN environment variable is not set")
        log("Usage: export SERVER_TOKEN='your-server-token' && python3 agent.py")
        sys.exit(1)

    log("Montime.io Agent Started")
    log(f"Base URL: {BASE_URL}")
    log(f"Interval: {INTERVAL}s")

    while True:
        try:
            cpu = get_cpu_usage()
            memory = get_memory_usage()
            disk = get_disk_usage()
            connectivity = check_connectivity()

            send_metrics(cpu, memory, disk, connectivity)

        except KeyboardInterrupt:
            log("Agent stopped by user")
            sys.exit(0)
        except Exception as e:
            log(f"Error collecting metrics: {str(e)}")

        time.sleep(INTERVAL)


if __name__ == '__main__':
    main()
