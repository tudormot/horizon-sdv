#!/usr/bin/env python3

# Copyright (c) 2026 Accenture, All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import glob
import json
import time
import sys
import argparse
import subprocess
from pathlib import Path
import os
import signal
import uuid
import requests
from requests import HTTPError
import tempfile
import shutil
from dotenv import load_dotenv

# --- Load Environment Variables ---
def load_env_config():
    """
    Loads variables from ENV_FILE_PATH into os.environ.
    Search Hierarchy (First match returns):
    1. ENV_FILE_PATH (if set in terminal)
    2. ./.env (Current working directory)
    3. ~/.gemini/.env (Global Fallback)
    """
    # override=False ensures that if you already 'export' a var in the terminal,
    # the .env file will NOT overwrite it.

    # Option 1: Explicit override via export ENV_FILE_PATH=...
    explicit_path_str = os.environ.get("ENV_FILE_PATH")
    if explicit_path_str:
        explicit_path = Path(explicit_path_str)
        if explicit_path.exists():
            return load_dotenv(dotenv_path=explicit_path, override=False)
    
    # Option 2: Check Current Working Directory
    cwd_env = Path.cwd() / ".env"
    if cwd_env.exists():
        return load_dotenv(dotenv_path=cwd_env, override=False)
    
    # Option 3: Global fallback; Check Gemini-CLI Directory in Home
    home_env = Path.home() / ".gemini" / ".env"
    if home_env.exists():
        return load_dotenv(dotenv_path=home_env, override=False)

load_env_config()


# --- Constants ---
ENV_FILE_PATH = Path(os.environ.get("ENV_FILE_PATH", Path.home() / ".env"))
HORIZON_DOMAIN = os.environ.get("HORIZON_DOMAIN", "##DOMAIN##")  # e.g., myenv.horizon-sdv.com

# Keycloak
KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", f"https://{HORIZON_DOMAIN}/auth")
REALM = os.environ.get("REALM", "horizon")
CLIENT_ID = os.environ.get("CLIENT_ID", "mcp-gateway-registry-cli")
OIDC_URL = f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect"
DEVICE_AUTH_URL = f"{OIDC_URL}/auth/device"
TOKEN_URL = f"{OIDC_URL}/token"

# Gemini-CLI
GEMINI_CONFIG_HOME = Path(os.environ.get("GEMINI_CONFIG_HOME", Path.home() / ".gemini"))
GEMINI_CLI_SETTINGS_FILE = GEMINI_CONFIG_HOME / "settings.json"

# MCP
MCP_REGISTRY_URL = os.environ.get("MCP_REGISTRY_URL", f"https://mcp.{HORIZON_DOMAIN}")
TOKEN_FILE = GEMINI_CONFIG_HOME / "mcp-gateway-registry-token.json"

# Daemon state; Used as a single-instance state file for both daemon and foreground sync loops
DAEMON_STATE_FILE = GEMINI_CONFIG_HOME / "mcp-gateway-sync-state.json"
DAEMON_LOG_FILE = GEMINI_CONFIG_HOME / "mcp-gateway-sync.log"

EXPIRY_SAFETY_SECONDS = 60 # Refresh tokens this many seconds before expiry
REQUEST_TIMEOUT_SECONDS = 30 # Timeout for HTTP requests


# --- Helpers ---
def discover_android_studio_mcp_file_path():
    """
    Detects the IDE environment and returns the appropriate mcp.json path.
    Returns None if no Android Studio environment is detected (Code-OSS or non-Android mode).
    Handles both Android Studio and Android Studio for Platform installations.
    """
    # Check for environment variable override first
    env_override = os.environ.get("ANDROID_STUDIO_MCP_FILE_PATH")
    if env_override:
        return Path(env_override)

    # Pattern Match for Android Studio or AS for Platform
    google_root = Path.home() / ".config/Google"
    if google_root.exists():
        # Search for directories starting with AndroidStudio
        configs = glob.glob(str(google_root / "AndroidStudio*"))
        if configs:
            # Sort to get the most recent version if multiple exist
            configs.sort(reverse=True)
            return Path(configs[0]) / "mcp.json"

    return None

# Android Studio MCP file path
_android_studio_mcp_file_path = os.environ.get("ANDROID_STUDIO_MCP_FILE_PATH")
if _android_studio_mcp_file_path:
    ANDROID_STUDIO_MCP_FILE_PATH = Path(_android_studio_mcp_file_path)
else:
    ANDROID_STUDIO_MCP_FILE_PATH = discover_android_studio_mcp_file_path()


def ensure_configs_exist():
    """Ensures directories and basic files exist based on detected environment."""
    # Always ensure Gemini-CLI configs exists
    GEMINI_CONFIG_HOME.mkdir(parents=True, exist_ok=True)
    if not GEMINI_CLI_SETTINGS_FILE.exists():
        with open(GEMINI_CLI_SETTINGS_FILE, 'w') as f:
            json.dump({}, f, indent=2)
    # If Android Studio MCP file path is detected, ensure it exists
    if ANDROID_STUDIO_MCP_FILE_PATH:
        ANDROID_STUDIO_MCP_FILE_PATH.parent.mkdir(parents=True, exist_ok=True)
        if not ANDROID_STUDIO_MCP_FILE_PATH.exists():
            with open(ANDROID_STUDIO_MCP_FILE_PATH, 'w') as f:
                json.dump({}, f, indent=2)


# --- Main Functionality ---
def device_login():
    """Initiates Device Authorization Flow and polls for token."""
    print(f"[*] Initiating Device Auth with {CLIENT_ID}...")

    try:
      resp = requests.post(DEVICE_AUTH_URL, data={"client_id": CLIENT_ID}, timeout=REQUEST_TIMEOUT_SECONDS)
      resp.raise_for_status()
      device_data = resp.json()

      device_code = device_data["device_code"]
      verification_uri = device_data["verification_uri_complete"]
      interval = device_data.get("interval", 5)
      expires_in = device_data.get("expires_in", 300)

      print(f"\nPlease authenticate via browser:\n\n   {verification_uri}\n")
      print(f"Waiting for login... (Expires in {expires_in}s)")

      start_time = time.time()
      while time.time() - start_time < expires_in:
          time.sleep(interval)

          token_resp = requests.post(TOKEN_URL, data={
              "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
              "device_code": device_code,
              "client_id": CLIENT_ID
          }, timeout=REQUEST_TIMEOUT_SECONDS)

          if token_resp.status_code == 200:
              print("\n[+] Login Successful!")
              return token_resp.json()

          err = token_resp.json().get("error")
          if err == "authorization_pending":
              continue
          elif err == "slow_down":
              interval += 2
          else:
              raise RuntimeError(f"Device flow failed: {err}")
    except HTTPError as e:
        status = e.response.status_code if e.response is not None else None
        if status == 401:
            raise RuntimeError(
                "Device authorization failed. This may indicate an issue with the Keycloak server. "
                "Please try again or contact your administrator."
            )
        elif status == 403:
            raise RuntimeError(
                "Access forbidden. Your account may not have permission to use this service. "
                "Please contact your administrator."
            )
        elif status is not None:
            raise RuntimeError(f"Server error ({status}): {e.response.text}")
        else:
            raise RuntimeError(f"HTTP error during device authorization: {e}")
    except requests.exceptions.ConnectionError as e:
        raise RuntimeError(f"Cannot connect to {DEVICE_AUTH_URL}. Check network/DNS.")
    except requests.exceptions.Timeout:
        raise RuntimeError(f"Device flow request timed out.")
    except requests.exceptions.RequestException as e:
        raise RuntimeError(f"Login failed: {e}")


def refresh_access_token(refresh_token):
    """Exchange a refresh token for a new access token pair."""
    try:
      resp = requests.post(TOKEN_URL, data={
          "grant_type": "refresh_token",
          "refresh_token": refresh_token,
          "client_id": CLIENT_ID
      }, timeout=REQUEST_TIMEOUT_SECONDS)
      resp.raise_for_status()
      return resp.json()
    except HTTPError as e:
        status = e.response.status_code if e.response is not None else None
        if status == 401:
            raise RuntimeError(
                f"Refresh token expired or revoked. Please run --login to re-authenticate."
            )
        elif status == 403:
            raise RuntimeError(
                "Access forbidden. Your account may not have permission to access this service. "
                "Please contact your administrator."
            )
        elif status is not None:
            raise RuntimeError(
                f"Token refresh failed. Server error ({status}): {e.response.text}. "
                "Please run --login to re-authenticate."
            )
        else:
            raise RuntimeError(
                f"Token refresh failed due to HTTP error: {e}. "
                "Please run --login to re-authenticate."
            )
    except requests.exceptions.ConnectionError as e:
        raise RuntimeError(f"Cannot connect to {TOKEN_URL}. Check network/DNS.")
    except requests.exceptions.Timeout:
        raise RuntimeError(f"Token refresh request timed out.")
    except requests.exceptions.RequestException as e:
        raise RuntimeError(f"Token refresh failed: {e}")


def fetch_mcp_servers(access_token):
    """Fetch the registry server catalog using the current access token."""
    headers = {"Authorization": f"Bearer {access_token}"}
    resp = requests.get(f"{MCP_REGISTRY_URL}/api/servers", headers=headers, timeout=REQUEST_TIMEOUT_SECONDS)
    resp.raise_for_status()
    data = resp.json()
    return data.get("servers", [])


def save_token_file(token_data):
    """
    Save token file atomically to prevent corruption.

    1. Write to a temporary file first
    2. If successful, replace the real file
    3. If crash happens, temp file is abandoned (real file untouched)
    """
    token_data = dict(token_data)
    token_data["obtained_at"] = int(time.time())

    # Create a temporary file in the same directory
    fd, temp_path = tempfile.mkstemp(
        dir=GEMINI_CONFIG_HOME,
        prefix=".token-temp-", # Hidden file
        suffix=".json"
    )

    # Write to temp file
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(token_data, f, indent=2)
        
        # Atomically replace old file with new file
        shutil.move(temp_path, TOKEN_FILE)
    except Exception:
        # Clean up the temp file
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise  # Re-raise the original exception


def load_token_file():
    """Read token JSON from disk and return it as a dict."""
    with open(TOKEN_FILE, 'r') as f:
        return json.load(f)


def is_access_token_fresh(token_data, *, safety_seconds=EXPIRY_SAFETY_SECONDS):
    """Checks if access token is still valid with safety margin."""
    access_token = token_data.get("access_token")
    expires_in = token_data.get("expires_in")
    obtained_at = token_data.get("obtained_at")

    if not access_token or not isinstance(expires_in, (int, float)) or not isinstance(obtained_at, (int, float)):
        return False

    expires_at = int(obtained_at) + int(expires_in)
    now = int(time.time())
    return now < (expires_at - int(safety_seconds))


def try_get_access_token_noninteractive():
    """Tries to get access token from existing token file, refreshing if needed."""
    if not TOKEN_FILE.exists():
        return None

    try:
        token_data = load_token_file()
    except Exception:
        return None

    if is_access_token_fresh(token_data):
        return token_data.get("access_token")

    refresh_token = token_data.get("refresh_token")
    if not refresh_token:
        return None

    try:
        new_tokens = refresh_access_token(refresh_token)
    except Exception:
        return None

    save_token_file(new_tokens)
    return new_tokens.get("access_token")


def get_access_token_interactive_fallback():
    """Gets access token, trying existing session first, else interactive login."""
    access = try_get_access_token_noninteractive()
    if access:
        print("[*] Using existing session (no browser login needed).")
        return access

    token_data = device_login()
    save_token_file(token_data)
    return token_data["access_token"]


def build_bridge_env_payload():
    """Shared environment payload for bridge-based MCP server entries."""
    return {
        "HORIZON_DOMAIN": HORIZON_DOMAIN,
        "KEYCLOAK_URL": KEYCLOAK_URL,
        "REALM": REALM,
        "CLIENT_ID": CLIENT_ID,
        "MCP_REGISTRY_URL": MCP_REGISTRY_URL,
        "GEMINI_CONFIG_HOME": str(GEMINI_CONFIG_HOME),
        "ANDROID_STUDIO_MCP_FILE_PATH": str(ANDROID_STUDIO_MCP_FILE_PATH) if ANDROID_STUDIO_MCP_FILE_PATH else "",
        # Marker to safely identify and prune only registry-managed entries.
        "MCP_GATEWAY_REGISTRY_MANAGED": "1",
    }


def build_bridge_server_entry(server_name, server_http_url):
    """
    Build a command-mode MCP entry.
    This avoids storing short-lived access tokens in cached config files.
    """
    server_env = build_bridge_env_payload()
    server_env["httpUrl"] = server_http_url

    return {
        "command": sys.executable,
        "args": [str(Path(__file__).resolve()), "--mcp-client-bridge", "--mcp-server", server_name],
        "env": server_env,
    }


def get_entry_http_url(entry):
    """Return MCP URL from either direct httpUrl or env.httpUrl entry formats."""
    if not isinstance(entry, dict):
        return ""

    direct_url = entry.get("httpUrl")
    if isinstance(direct_url, str) and direct_url.strip():
        return direct_url.strip()

    env_payload = entry.get("env")
    if isinstance(env_payload, dict):
        env_url = env_payload.get("httpUrl")
        if isinstance(env_url, str) and env_url.strip():
            return env_url.strip()

    return ""


def update_gemini_cli_settings_file(servers, *, prune=False, force=False):
    """
    Sync registry-managed MCP entries into Gemini CLI `settings.json`.
    Uses command-mode bridge entries so tokens are not persisted in this file.
    """
    try:
        with open(GEMINI_CLI_SETTINGS_FILE, 'r') as f:
            config = json.load(f)
    except json.JSONDecodeError:
        config = {}

    if not isinstance(config, dict):
        config = {}

    # Clear existing mcpServers if force is set
    if force:
        config["mcpServers"] = {}

    # Initialize mcpServers if missing or invalid
    if "mcpServers" not in config or not isinstance(config["mcpServers"], dict):
        config["mcpServers"] = {}

    existing = config["mcpServers"]
    base = MCP_REGISTRY_URL.rstrip("/") # base URL without trailing slash

    desired_names = set()
    for server in servers:
        s_name = server.get("display_name")
        s_path = server.get("path")
        if not s_name or not s_path:
            print(f"[!] Skipping server with missing fields: {server}")
            continue

        desired_names.add(s_name) # track latest server names to prune unmanaged ones later
        s_path = "/" + s_path.strip("/")
        s_url = f"{base}{s_path}/mcp"

        existing[s_name] = build_bridge_server_entry(s_name, s_url)
        print(f"[+] Upserted MCP server (registry): {s_name}")

    # Prune previously managed servers that are no longer in the desired list if prune is set
    if prune:
        to_delete = []
        for name, entry in existing.items():
            # Check if server is managed by our registry tooling.
            if is_registry_managed_entry(entry, base):
                # If managed but not in current desired list, mark for deletion
                if name not in desired_names:
                    to_delete.append(name)

        # Delete the marked servers
        for name in to_delete:
            del existing[name]
            print(f"[-] Pruned MCP server (registry, no longer exists): {name}")

    with open(GEMINI_CLI_SETTINGS_FILE, 'w') as f:
        json.dump(config, f, indent=2)

    print(f"[*] Updated {GEMINI_CLI_SETTINGS_FILE}.")


def update_android_studio_mcp_file(servers, *, prune=False, force=False):
    """
    Sync registry-managed MCP entries into Android Studio `mcp.json`.
    Uses the same command-mode bridge pattern as Gemini CLI for token freshness.
    """
    try:
        with open(ANDROID_STUDIO_MCP_FILE_PATH, 'r') as f:
            config = json.load(f)
    except json.JSONDecodeError:
        config = {}

    if not isinstance(config, dict):
        config = {}

    # Clear existing mcpServers if force is set
    if force:
        config["mcpServers"] = {}

    # Initialize mcpServers if missing or invalid
    if "mcpServers" not in config or not isinstance(config["mcpServers"], dict):
        config["mcpServers"] = {}

    existing = config["mcpServers"]
    base = MCP_REGISTRY_URL.rstrip("/") # base URL without trailing slash

    desired_names = set()
    for server in servers:
        s_name = server.get("display_name")
        s_path = server.get("path")
        if not s_name or not s_path:
            print(f"[!] Skipping server with missing fields: {server}")
            continue

        desired_names.add(s_name) # track latest server names to prune unmanaged ones later
        s_path = "/" + s_path.strip("/")
        s_url = f"{base}{s_path}/mcp"

        existing[s_name] = build_bridge_server_entry(s_name, s_url)
        print(f"[+] Upserted MCP server (registry): {s_name}")

    # Prune previously managed servers that are no longer in the desired list if prune is set
    if prune:
        to_delete = []
        for name, entry in existing.items():
            if is_registry_managed_entry(entry, base):
                # If managed but not in current desired list, mark for deletion
                if name not in desired_names:
                    to_delete.append(name)

        # Delete the marked servers
        for name in to_delete:
            del existing[name]
            print(f"[-] Pruned MCP server (registry, no longer exists): {name}")

    with open(ANDROID_STUDIO_MCP_FILE_PATH, 'w') as f:
        json.dump(config, f, indent=2)

    print(f"[*] Updated {ANDROID_STUDIO_MCP_FILE_PATH}.")


def is_managed_server(server_http_url, registry_base_url):
    """
    Check if a server entry is managed by MCP Gateway Registry.
    Managed servers are identified by their URL pointing to the registry.
    """
    if not isinstance(server_http_url, str) or not server_http_url.strip():
        return False

    # Normalize URLs for comparison
    normalized_url = server_http_url.rstrip("/")
    normalized_base = registry_base_url.rstrip("/")
    
    # Server is managed if its URL starts with our registry base
    return normalized_url.startswith(normalized_base)


def is_registry_managed_entry(entry, registry_base_url):
    """
    Detect registry-managed entries across old and new entry shapes.
    """
    if not isinstance(entry, dict):
        return False

    env_payload = entry.get("env", {})
    if isinstance(env_payload, dict):
        managed_flag = str(env_payload.get("MCP_GATEWAY_REGISTRY_MANAGED", "")).strip().lower()
        if managed_flag in {"1", "true", "yes"}:
            return True

    # Backward compatibility: older entries may not have the marker flag.
    return is_managed_server(get_entry_http_url(entry), registry_base_url)


def fetch_servers_with_auto_retry(access_token):
    """Fetch servers, retrying once on 401 Unauthorized after refreshing token."""
    try:
        return fetch_mcp_servers(access_token)
    except HTTPError as e:
        status = e.response.status_code if e.response is not None else None
        if status == 401:
            print("[*] Token expired, attempting refresh...")
            new_access = try_get_access_token_noninteractive()
            if new_access and new_access != access_token:
                try:
                    return fetch_mcp_servers(new_access)
                except HTTPError as e2:
                    if e2.response and e2.response.status_code == 401:
                        raise RuntimeError(
                            "Authentication failed even after token refresh. "
                            "Please run --login to re-authenticate."
                        )
                    raise # Re-raise other HTTP errors
            else:
                raise RuntimeError(
                    "Token expired and refresh failed. "
                    "Please run --login to re-authenticate."
                )
        elif status == 403:
            raise RuntimeError(
                "Access forbidden (403). Ensure your user has appropriate MCP Registry access permissions. "
                "If you recently changed permissions, please wait a few minutes and try again."
            )
        elif status is not None:
            raise RuntimeError(f"Server error ({status}): {e.response.text}")
        else:
            raise RuntimeError(f"HTTP error while fetching servers: {e}")
    except requests.exceptions.ConnectionError as e:
        raise RuntimeError(f"Cannot connect to {MCP_REGISTRY_URL}. Check network/DNS.")
    except requests.exceptions.Timeout:
        raise RuntimeError(f"Request to {MCP_REGISTRY_URL} timed out.")
    except requests.exceptions.JSONDecodeError:
        raise RuntimeError(
            f"Registry returned invalid JSON. "
            f"Server may be experiencing issues. Please try again later."
        )
    except requests.exceptions.RequestException as e:
        raise RuntimeError(f"Request failed: {e}")


# ---Cross platform (Win + Linux) Daemon helpers for managing both foreground and daemon (background) sync loops---
def _pid_is_running(pid: int) -> bool:
    """Return True when a process with this PID appears active on the current OS."""
    if pid <= 0:
        return False

    if sys.platform.startswith("win"):
        try:
            result = subprocess.run(
                ["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"],
                capture_output=True,
                text=True,
                check=False,
                timeout=5
            )
            # CSV format is more reliable
            return str(pid) in result.stdout
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return False
    else:
        # POSIX existence check: signal 0 does not kill; it only checks.
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False


def _read_daemon_state():
    """Load daemon state JSON; return None when missing or unreadable."""
    if not DAEMON_STATE_FILE.exists():
        return None
    try:
        with open(DAEMON_STATE_FILE, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


def _write_daemon_state(pid: int, mode: str):
    """Write daemon state atomically using temp file pattern."""
    fd, temp_path = tempfile.mkstemp(
        dir=GEMINI_CONFIG_HOME,
        prefix=".state-temp-",
        suffix=".json"
    )
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump({
                "pid": pid,
                "mode": mode,
                "script": str(Path(__file__).resolve()),
                "started_at": int(time.time()),
            }, f, indent=2)
        shutil.move(temp_path, DAEMON_STATE_FILE)
    except Exception:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise


def _clear_daemon_state():
    """Best-effort removal of daemon state file."""
    try:
        DAEMON_STATE_FILE.unlink(missing_ok=True)
    except Exception:
        pass
    

def daemon_status():
    """Check if any sync loop (daemon or foreground) is running."""
    state = _read_daemon_state()
    if not state:
        return False, None, None

    pid = int(state.get("pid", 0)) or None
    mode = state.get("mode")
    script = state.get("script")

    # Check if the recorded script matches this script
    if script != str(Path(__file__).resolve()):
        return False, pid, mode

    # Check if the recorded PID is running
    if pid and _pid_is_running(pid):
        return True, pid, mode

    # Script not running; clean up stale state
    _clear_daemon_state()
    return False, None, None


def daemon_stop():
    """Stop an active sync loop process (foreground/daemon) and clear state."""
    running, pid, mode = daemon_status()
    if not pid:
        print("[*] Sync is not running.")
        return

    if not running:
        print(f"[*] Sync is not running (stale PID {pid}). Cleaning state.")
        _clear_daemon_state()
        return

    print(f"[*] Stopping sync (mode={mode}, PID {pid})...")
    try:
        if sys.platform.startswith("win"):
            subprocess.run(["taskkill", "/PID", str(pid), "/F"], check=False, timeout=5)
        else:
            os.kill(pid, signal.SIGTERM)
            time.sleep(0.5)
            if _pid_is_running(pid):
                os.kill(pid, signal.SIGKILL)
    except subprocess.TimeoutExpired:
        print("[!] Warning: Stop command timed out")
    finally:
        _clear_daemon_state()

    print("[*] Stop requested.")


def _start_detached_sync_process():
    """Start the current script in --watch mode but as a detached background process (daemon)."""
    python_exe = str(Path(sys.executable).resolve())
    script_path = str(Path(__file__).resolve())
    args = [python_exe, script_path, "--watch"]

    if sys.platform.startswith("win"):
        if python_exe.lower().endswith("python.exe"):
            pythonw_exe = python_exe[:-10] + "pythonw.exe"
            if Path(pythonw_exe).exists():
                python_exe = pythonw_exe
                args[0] = python_exe  # Update first arg
        
        creationflags = 0
        if hasattr(subprocess, "CREATE_NEW_PROCESS_GROUP"):
            creationflags |= subprocess.CREATE_NEW_PROCESS_GROUP
        if hasattr(subprocess, "DETACHED_PROCESS"):
            creationflags |= subprocess.DETACHED_PROCESS

        p = subprocess.Popen(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=creationflags
        )
        return p.pid

    # POSIX detach: new session; parent can exit cleanly
    p = subprocess.Popen(
        args,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        start_new_session=True
    )
    return p.pid


def ensure_no_parallel_sync():
    """Guard against running multiple sync loops at the same time."""
    running, pid, mode = daemon_status()
    if running:
        raise SystemExit(
            f"Sync is already running (mode={mode}, PID={pid}). "
            f"Stop it first. If its a daemon, use '--daemon-stop' option."
        )


def daemon_start():
    """Start daemon background sync with verification."""
    ensure_no_parallel_sync()

    spawned_pid = _start_detached_sync_process()
    print(f"[*] Started background sync (initial PID {spawned_pid}).")
    
    max_wait = 5
    start = time.time()
    while time.time() - start < max_wait:
        time.sleep(0.5)
        running, actual_pid, mode = daemon_status()
        if running and actual_pid:
            print(f"[*] Daemon confirmed running (PID {actual_pid}).")
            return
    
    print(f"[!] Warning: Could not confirm daemon started within {max_wait}s.")
    print(f"[!] Check {DAEMON_LOG_FILE} for errors.")


def sync_loop(*, prune=False, force=False):
    """
    Foreground sync loop (refresh token + update Gemini config).
    When started via --daemon-start, it runs detached in the background.
    """

    # Prevent parallel runs (also auto-cleans stale state)
    ensure_no_parallel_sync()

    # Write current PID and mode to state file
    mode = "foreground" if sys.stdin.isatty() else "daemon"  # detect if run in terminal (a tty)
    _write_daemon_state(os.getpid(), mode)

    # Set up logging for daemon mode
    log_handle = None
    if mode == "daemon":
        log_handle = open(DAEMON_LOG_FILE, "a", encoding="utf-8", buffering=1)  # line-buffered
        sys.stdout = log_handle
        sys.stderr = log_handle
        print(f"\n[*] Daemon started at {time.strftime('%Y-%m-%d %H:%M:%S')}")

    # Load existing token file
    try:
        token_data = load_token_file()
    except Exception:
        raise SystemExit(f"Token file not found/invalid: {TOKEN_FILE}. Run --login first.")

    # Loop starts here
    try:
        while True:
            refresh_token = token_data.get("refresh_token")
            if not refresh_token:
                raise SystemExit("No refresh_token available; login again.")

            expires_in = token_data.get("expires_in", 300)
            sleep_time = max(10, int(expires_in) - EXPIRY_SAFETY_SECONDS)
            try:
                time.sleep(sleep_time)
            except KeyboardInterrupt:
                # User pressed Ctrl+C during sleep
                raise  # Re-raise to outer handler

            try:
                new_tokens = refresh_access_token(refresh_token)
            except RuntimeError as e:
                # refresh_access_token already converted to RuntimeError
                raise SystemExit(f"Token refresh failed: {e}. SSO session likely expired. Please run --login to re-authenticate.")
            except Exception as e:
                # Unexpected error
                raise SystemExit(f"Unexpected error during token refresh: {e}")

            token_data = new_tokens
            save_token_file(token_data)

            servers = fetch_mcp_servers(token_data["access_token"])
            if not servers:
                # In watch mode, log warning but don't crash
                print(f"[!] No servers in registry at {time.strftime('%H:%M:%S')}")
                # Skip config update this cycle
            else:
                update_gemini_cli_settings_file(servers, prune=prune, force=force)
                # Also update Android Studio MCP file if detected
                if ANDROID_STUDIO_MCP_FILE_PATH:
                    update_android_studio_mcp_file(servers, prune=prune, force=force)
    except KeyboardInterrupt:
        # Graceful shutdown
        if mode == "foreground":
            print("\n[*] Sync stopped by user (Ctrl+C)")
        # Daemon mode: just exit silently
    except Exception as e:
        print(f"[!] Unexpected error in sync loop: {e}")
        import traceback
        traceback.print_exc()
    finally:
        _clear_daemon_state()

        if log_handle:
            try:
                log_handle.flush()
                log_handle.close()
                sys.stdout = sys.__stdout__
                sys.stderr = sys.__stderr__
            except Exception:
                pass

def _load_server_entry_from_settings(server_name):
    """Load server entry from settings.json by name (legacy fallback path)."""
    try:
        with open(GEMINI_CLI_SETTINGS_FILE, 'r') as f:
            config = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None

    if not isinstance(config, dict):
        return None

    mcp_servers = config.get("mcpServers", {})
    if not isinstance(mcp_servers, dict):
        return None

    entry = mcp_servers.get(server_name)
    return entry if isinstance(entry, dict) else None


def _resolve_bridge_server_entry(server_name):
    """
    Resolve target server entry for bridge mode.
    Prefer entry data passed in process env (works with cached client configs),
    then fall back to settings.json for backward compatibility with older entries.
    """
    env_http_url = os.environ.get("httpUrl")
    if isinstance(env_http_url, str) and env_http_url.strip():
        return {"httpUrl": env_http_url.strip()}

    server_entry = _load_server_entry_from_settings(server_name)
    if server_entry:
        return server_entry

    raise RuntimeError(
        f"Could not resolve MCP server '{server_name}'. "
        f"Expected env.httpUrl or settings entry in {GEMINI_CLI_SETTINGS_FILE}."
    )


def _get_bridge_access_token():
    """
    Get a fresh access token from local token cache, refreshing non-interactively when needed.
    """
    access_token = try_get_access_token_noninteractive()
    if access_token:
        return access_token

    raise RuntimeError(
        f"No valid access token available in {TOKEN_FILE}. "
        "Run --login to re-authenticate."
    )


def _bridge_read_message(stdin_buffer):
    """
    Read a single JSON-RPC message from stdin.
    Supports:
    - MCP stdio framed mode: Content-Length headers + payload bytes (Gemini CLI)
    - NDJSON mode: one JSON object per line (legacy IDE behavior)
    Returns (message_obj, io_mode) where io_mode is "framed" or "ndjson".
    Returns (None, None) on EOF.
    """
    while True:
        first_line = stdin_buffer.readline()
        if not first_line:
            return None, None

        if not first_line.strip():
            continue

        stripped = first_line.lstrip()
        if stripped.startswith(b"{") or stripped.startswith(b"["):
            try:
                return json.loads(first_line.decode("utf-8").strip()), "ndjson"
            except (UnicodeDecodeError, json.JSONDecodeError) as e:
                raise RuntimeError(f"Invalid NDJSON message: {e}")

        if b":" in first_line:
            headers = {}
            line = first_line
            while line and line.strip():
                try:
                    header_text = line.decode("ascii", errors="strict").strip()
                except UnicodeDecodeError:
                    raise RuntimeError("Invalid non-ASCII header in framed MCP message.")

                if ":" not in header_text:
                    raise RuntimeError(f"Malformed MCP header line: {header_text}")

                k, v = header_text.split(":", 1)
                headers[k.strip().lower()] = v.strip()
                line = stdin_buffer.readline()

            if "content-length" not in headers:
                raise RuntimeError("Missing Content-Length header in framed MCP message.")

            try:
                payload_len = int(headers["content-length"])
            except ValueError:
                raise RuntimeError(f"Invalid Content-Length value: {headers['content-length']}")

            if payload_len < 0:
                raise RuntimeError(f"Negative Content-Length is invalid: {payload_len}")

            payload = stdin_buffer.read(payload_len)
            if payload is None or len(payload) < payload_len:
                raise RuntimeError("Unexpected EOF while reading framed MCP payload.")

            try:
                return json.loads(payload.decode("utf-8")), "framed"
            except (UnicodeDecodeError, json.JSONDecodeError) as e:
                raise RuntimeError(f"Invalid JSON payload in framed MCP message: {e}")

        try:
            return json.loads(first_line.decode("utf-8").strip()), "ndjson"
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise RuntimeError("Could not parse MCP stdin as framed or NDJSON message.")


def _bridge_write_message(message, io_mode):
    """Write one MCP message to stdout in framed or NDJSON format."""
    # Reply in the same transport mode we detected from stdin.
    payload = json.dumps(message)
    if io_mode == "framed":
        payload_bytes = payload.encode("utf-8")
        sys.stdout.buffer.write(f"Content-Length: {len(payload_bytes)}\r\n\r\n".encode("ascii"))
        sys.stdout.buffer.write(payload_bytes)
        sys.stdout.buffer.flush()
        return

    sys.stdout.write(payload + "\n")
    sys.stdout.flush()


def _is_valid_jsonrpc_id(value):
    """Validate reply id shape accepted by Gemini CLI's MCP parser."""
    # Gemini CLI's MCP parser rejects id=null; only string/number ids are safe here.
    return isinstance(value, (str, int, float)) and not isinstance(value, bool)


def _write_bridge_error(req_id, message, io_mode):
    """Emit a JSON-RPC error response when the request has a valid id."""
    # Do not emit replies for notifications (no id); JSON-RPC notifications expect no response.
    if not _is_valid_jsonrpc_id(req_id):
        print(f"[bridge] Non-request error (no valid id): {message}", file=sys.stderr)
        return

    err = {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32603, "message": message}}
    _bridge_write_message(err, io_mode)


# Bridge service for Gemini clients that cache MCP config files
def run_mcp_client_bridge(server_name):
    """
    Hidden bridge mode called by Gemini clients.
    Reads JSON-RPC requests from stdin and forwards them to the remote MCP server.
    Authentication is injected per request from TOKEN_FILE, not from settings.json.
    """
    session = requests.Session()
    server_issued_session_id = None
    io_mode = None

    try:
        while True:
            # Read request from Gemini MCP client via stdin transport.
            gemini_request_data = None
            try:
                gemini_request_data, detected_mode = _bridge_read_message(sys.stdin.buffer)
                if gemini_request_data is None:
                    break
                if not isinstance(gemini_request_data, dict):
                    raise RuntimeError("Invalid JSON-RPC message: expected a JSON object.")

                if not io_mode:
                    io_mode = detected_mode or "ndjson"

                server_entry = _resolve_bridge_server_entry(server_name)
                base_url = get_entry_http_url(server_entry)
                if not base_url:
                    raise RuntimeError(
                        f"Server '{server_name}' has no httpUrl configured "
                        "in either entry.httpUrl or entry.env.httpUrl."
                    )
                # Security guard: inject registry token only for registry-managed server URLs.
                if not is_managed_server(base_url, MCP_REGISTRY_URL.rstrip("/")):
                    raise RuntimeError(
                        "Refusing token injection for non-registry MCP server URL. "
                        "This bridge mode is only for MCP Gateway Registry managed servers."
                    )

                connector = "&" if "?" in base_url else "?"
                headers = {}
                raw_headers = server_entry.get("headers", {})
                if isinstance(raw_headers, dict):
                    headers.update(raw_headers)
                headers.pop("Authorization", None)

                access_token = _get_bridge_access_token()
                headers["Authorization"] = f"Bearer {access_token}"
                current_session_id = server_issued_session_id if server_issued_session_id else str(uuid.uuid4())

                # Keep server-issued MCP session once available; send client seed session for first call.
                if server_issued_session_id:
                    target_url = f"{base_url}{connector}mcpSessionId={current_session_id}"
                    headers.update({"mcp-session-id": current_session_id, "X-Session-Id": current_session_id})
                else:
                    target_url = f"{base_url}{connector}sessionId={current_session_id}"
                    headers.update({"X-Session-Id": current_session_id})

                headers.update({
                    "Content-Type": "application/json",
                    "Accept": "application/json, text/event-stream"
                })

                # Forward request to MCP server
                response = session.post(
                    target_url,
                    json=gemini_request_data,
                    headers=headers,
                    timeout=REQUEST_TIMEOUT_SECONDS,
                    stream=True
                )
                try:
                    # If auth raced token expiry, retry once with a freshly refreshed token.
                    if response.status_code == 401:
                        response.close()
                        retry_token = try_get_access_token_noninteractive()
                        if retry_token and retry_token != access_token:
                            headers["Authorization"] = f"Bearer {retry_token}"
                            response = session.post(
                                target_url,
                                json=gemini_request_data,
                                headers=headers,
                                timeout=REQUEST_TIMEOUT_SECONDS,
                                stream=True
                            )

                    # Capture server-issued session ID for future requests.
                    if response.headers.get("mcp-session-id"):
                        server_issued_session_id = response.headers.get("mcp-session-id")

                    if response.status_code == 200:
                        for chunk in response.iter_lines():
                            if not chunk:
                                continue

                            try:
                                line_text = chunk.decode('utf-8').strip()

                                # Ignore SSE metadata and heartbeats; these are protocol-level noise, not JSON-RPC.
                                if not line_text or line_text.startswith(':') or line_text.startswith('event:'):
                                    continue

                                payload = None
                                if line_text.startswith("data:"):
                                    payload = line_text[5:].strip()
                                elif line_text.startswith("{") or line_text.startswith("["):
                                    payload = line_text

                                if payload:
                                    parsed_payload = json.loads(payload)
                                    if not isinstance(parsed_payload, dict):
                                        # MCP messages must be JSON objects.
                                        continue
                                    _bridge_write_message(parsed_payload, io_mode)

                            except (json.JSONDecodeError, UnicodeDecodeError):
                                # If a chunk is partial or corrupt, don't kill the bridge.
                                continue

                    else:
                        if response.status_code in [400, 401, 403]:
                            server_issued_session_id = None  # reset session on auth/session errors

                        response_text = response.text.strip() if response.text else ""
                        if response_text:
                            response_text = response_text[:300]
                            message = f"MCP Client Bridge Error {response.status_code}: {response_text}"
                        else:
                            message = f"MCP Client Bridge Error {response.status_code}"
                        _write_bridge_error(gemini_request_data.get("id"), message, io_mode)
                finally:
                    response.close()

            except Exception as e:
                req_id = gemini_request_data.get("id") if isinstance(gemini_request_data, dict) else None
                _write_bridge_error(req_id, str(e), io_mode or "ndjson")
    finally:
        session.close()


def main():
    """CLI entrypoint: parse args and dispatch to login/sync/daemon/bridge modes."""
    parser = argparse.ArgumentParser(
        description="""
            Configures and synchronizes MCP servers for Gemini CLI and Gemini Code Assist.

            This script simplifies using MCP (Model Context Protocol) servers by handling authentication and configuration for you.

            What it does:
              1. Authenticates: Connects to the MCP Gateway Registry using a simple browser-based login (Keycloak Device Flow).
              2. Fetches Config: Retrieves your authentication token (JWT) and the list of available MCP servers.
              3. Updates Tools:
                * Configures Gemini CLI by updating `~/.gemini/settings.json`.
                * Configures Gemini Code Assist in VS Code, Android Studio, and Android Studio for Platform (ASfP).
              4. Keeps you logged in: Can run continuously in the background to automatically refresh your token and server list.

            Special Note for Gemini clients:
            Some clients cache MCP config files. To avoid stale-token failures, registry-managed servers are configured through an MCP-client bridge command. The bridge transparently forwards requests and injects a fresh authentication token from the local token file on every request.
        """, formatter_class=argparse.RawDescriptionHelpFormatter
    )

    primary_mode = parser.add_mutually_exclusive_group()
    primary_mode.add_argument(
        "--login",
        action="store_true",
        help="Default mode. Interactive login if needed. Reuses existing token/refresh token first to avoid repeated browser login."
    )
    primary_mode.add_argument(
        "--watch",
        action="store_true",
        help="Continuously sync server list and refresh token in foreground mode. Use Ctrl+C to stop."
    )
    primary_mode.add_argument(
        "--daemon-status",
        action="store_true",
        help="Show background sync status and exit."
    )
    primary_mode.add_argument(
        "--daemon-stop",
        action="store_true",
        help="Stop background sync and exit."
    )
    primary_mode.add_argument(
        "--mcp-client-bridge",
        action="store_true",
        help=argparse.SUPPRESS  # Hidden option for internal use only
    )

    parser.add_argument(
        "--mcp-server",
        action="store", # requires an argument; the name of the MCP server to 
        help=argparse.SUPPRESS  # Hidden option for internal use only
    )

    parser.add_argument(
        "--daemon-start",
        action="store_true",
        help="Continuously sync server list and refresh token in (background) daemon mode."
    )

    config_mode = parser.add_mutually_exclusive_group()
    config_mode.add_argument(
        "--prune",
        action="store_true",
        help="Sync removes managed servers no longer in registry. Does not affect non-managed servers."
    )
    config_mode.add_argument(
        "--force",
        action="store_true",
        help="Sync replaces entire mcpServers block with only registry servers (more destructive, removes all non-managed servers)."
    )

    # Some MCP clients may append extra launcher args in command mode.
    # In bridge mode we tolerate unknown extras to avoid startup disconnects.
    if "--mcp-client-bridge" in sys.argv:
        args, _ = parser.parse_known_args()
    else:
        args = parser.parse_args()

    ensure_configs_exist()

    # --- Arguments validation---
    if (args.daemon_status or args.daemon_stop or args.watch) and args.daemon_start:
        parser.error("--daemon-start is not valid with options --watch, --daemon-status, or --daemon-stop.")
    if (args.daemon_status or args.daemon_stop) and (args.prune or args.force):
        parser.error("--prune and --force are not valid with options --daemon-status or --daemon-stop.")
    if args.mcp_client_bridge or args.mcp_server:
        is_valid_pair = args.mcp_client_bridge and args.mcp_server
        other_active_args = []
        for arg in vars(args):
            if arg not in ("mcp_client_bridge", "mcp_server") and getattr(args, arg) != parser.get_default(arg):
                other_active_args.append(arg)
        if not is_valid_pair or other_active_args:
            parser.error("--mcp-client-bridge and --mcp-server must be used together and without any other options.")

    # Bridge mode can run from cached command entries even when this env var is not exported in shell.
    if (not args.mcp_client_bridge) and (not HORIZON_DOMAIN or HORIZON_DOMAIN == "##DOMAIN##"):
        raise SystemExit(
            "ERROR: HORIZON_DOMAIN environment variable not set.\n"
            "Example: export HORIZON_DOMAIN=myenv.horizon-sdv.com"
        )


    # --- Entry points for various options ---

    if args.mcp_client_bridge:
        run_mcp_client_bridge(args.mcp_server)
        return

    if args.daemon_status:
        running, pid, mode = daemon_status()
        if running:
            print(f"[*] Sync is running (mode={mode}, PID {pid}).")
        else:
            print("[*] Sync is not running.")
        return

    if args.daemon_stop:
        daemon_stop()
        return

    if args.watch:
        print("[*] Starting foreground continuous sync (Ctrl+C to stop)...")
        print(f"[*] Options: prune={args.prune}, force={args.force}")
        sync_loop(prune=args.prune, force=args.force)
        return

    # Default flow
    if not args.login:
        args.login = True

    ensure_no_parallel_sync()
    access_token = get_access_token_interactive_fallback()
    servers = fetch_servers_with_auto_retry(access_token)
    if not servers:
        raise RuntimeError(f"No servers returned from {MCP_REGISTRY_URL}/api/servers.")

    if args.force:
        print("[!] --force is set: this will replace the entire mcpServers block in settings.json.")

    update_gemini_cli_settings_file(servers, prune=args.prune, force=args.force)
    # Also update Android Studio MCP file if detected
    if ANDROID_STUDIO_MCP_FILE_PATH:
        update_android_studio_mcp_file(servers, prune=args.prune, force=args.force)

    if args.daemon_start:
        daemon_start()
        print("[*] Done.")
        return

    is_running, pid, mode = daemon_status()
    if is_running:
        print(f"[*] Background sync is already active (PID {pid}, mode={mode}).")
    else:
        try:
            answer = input("Start background sync for this session now? (y/N): ").strip().lower()
            if answer in ("y", "yes"):
                daemon_start()
            elif answer in ("n", "no", ""):
                print("[*] Background sync not started.")
        except KeyboardInterrupt:
            print("\n[*] Operation cancelled.")

    print("[*] Done.")


if __name__ == "__main__":
    main()
