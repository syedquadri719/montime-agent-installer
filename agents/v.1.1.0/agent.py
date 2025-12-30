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
BASE_URL = os.environ.get('BASE_URL', 'https://montime-mauve.vercel.app')
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


def detect_os():
    """Detect OS information (Linux or Windows).
    Returns: (os_type, os_name, os_version) tuple, with None for unavailable values.
    """
    os_type = None
    os_name = None
    os_version = None
    
    try:
        if sys.platform.startswith('linux'):
            os_type = 'linux'
            # Try /etc/os-release (most reliable for Linux)
            try:
                with open('/etc/os-release', 'r') as f:
                    content = f.read()
                    for line in content.split('\n'):
                        if line.startswith('PRETTY_NAME='):
                            os_name = line.split('=', 1)[1].strip().strip('"').strip("'")
                        elif line.startswith('NAME=') and not os_name:
                            os_name = line.split('=', 1)[1].strip().strip('"').strip("'")
                        elif line.startswith('ID=') and not os_name:
                            os_name = line.split('=', 1)[1].strip().strip('"').strip("'")
                        elif line.startswith('VERSION_ID='):
                            os_version = line.split('=', 1)[1].strip().strip('"').strip("'")
                        elif line.startswith('VERSION=') and not os_version:
                            # Try to extract version number
                            version_str = line.split('=', 1)[1].strip().strip('"').strip("'")
                            import re
                            match = re.search(r'\d+\.\d+', version_str)
                            if match:
                                os_version = match.group(0)
            except (IOError, OSError):
                pass
        
        elif sys.platform.startswith('win'):
            os_type = 'windows'
            # Use platform module for Windows
            try:
                import platform
                os_name = platform.system()  # "Windows"
                # Try to get Windows version
                os_version = platform.release()  # "10", "Server2019", etc.
                # Try to get more detailed version
                try:
                    import winreg
                    key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, 
                                       r"SOFTWARE\Microsoft\Windows NT\CurrentVersion")
                    product_name = winreg.QueryValueEx(key, "ProductName")[0]
                    if product_name:
                        os_name = product_name
                    winreg.CloseKey(key)
                except (ImportError, OSError, WindowsError):
                    pass
            except Exception:
                pass
    
    except Exception:
        # If detection fails, return None values (agent continues)
        pass
    
    return (os_type, os_name, os_version)


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


# Cache OS detection (detect once, reuse)
_detected_os_cache = None

def send_metrics(cpu, memory, disk, status):
    global _detected_os_cache
    
    # Detect OS once and cache it
    if _detected_os_cache is None:
        _detected_os_cache = detect_os()
    
    os_type, os_name, os_version = _detected_os_cache
    
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
    
    # Add OS fields if detected
    if os_type:
        payload['os_type'] = os_type
    if os_name:
        payload['os_name'] = os_name
    if os_version:
        payload['os_version'] = os_version

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
