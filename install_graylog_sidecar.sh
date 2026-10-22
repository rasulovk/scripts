
#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# ============================================================
# Graylog Sidecar Installation Script
# Supports Debian/Ubuntu and RHEL-compatible distributions
# ============================================================

CONFIG_FILE="/etc/graylog/sidecar/sidecar.yml"
DEB_REPO_URL="https://downloads.graylog.org/repo/packages/graylog-sidecar-repository_1-6_all.deb"
RPM_REPO_URL="https://downloads.graylog.org/repo/packages/graylog-sidecar-repository-1-6.noarch.rpm"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

on_error() {
    local rc=$?
    echo >&2
    echo "ERROR: Installation failed near line ${BASH_LINENO[0]} (exit code ${rc})." >&2
    echo "Check the output above for the failing command." >&2
    exit "$rc"
}

trap on_error ERR

# ------------------------------------------------------------
# 1. Check privileges and operating system
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root: sudo bash install_graylog_sidecar.sh"
fi

[[ -r /etc/os-release ]] || die "Cannot identify operating system."

# shellcheck disable=SC1091
source /etc/os-release

log "Detected operating system: ${PRETTY_NAME:-unknown}"

if [[ -f /etc/debian_version ]]; then
    OS_FAMILY="debian"
elif [[ -f /etc/redhat-release ]] || \
     [[ "${ID:-}" =~ ^(rhel|centos|rocky|almalinux|ol|fedora)$ ]]; then
    OS_FAMILY="rhel"
else
    die "Unsupported OS: ${PRETTY_NAME:-unknown}"
fi

# ------------------------------------------------------------
# 2. Collect configuration
# ------------------------------------------------------------

echo
echo "=== Graylog Sidecar Configuration ==="

read -r -p "Graylog Server API URL [http://10.10.10.124:9000/api/]: " SERVER_URL
SERVER_URL="${SERVER_URL:-http://10.10.10.124:9000/api/}"

read -r -s -p "Graylog Server API token: " API_TOKEN
echo

read -r -p "Node name [$(hostname -s)]: " NODE_NAME
NODE_NAME="${NODE_NAME:-$(hostname -s)}"

read -r -p "Sidecar tag [linux]: " SIDECAR_TAG
SIDECAR_TAG="${SIDECAR_TAG:-linux}"

echo "===================================="

# Remove trailing slashes, then append exactly one /api/.
SERVER_URL="${SERVER_URL%/}"
if [[ "$SERVER_URL" != */api ]]; then
    SERVER_URL="${SERVER_URL}/api"
fi
SERVER_URL="${SERVER_URL}/"

[[ "$SERVER_URL" =~ ^https?://[^[:space:]]+/api/$ ]] ||
    die "Invalid API URL. Example: http://10.10.10.124:9000/api/"

[[ -n "$API_TOKEN" ]] || die "API token cannot be empty."
[[ -n "$NODE_NAME" ]] || die "Node name cannot be empty."
[[ -n "$SIDECAR_TAG" ]] || die "Sidecar tag cannot be empty."

# Store secrets/configuration for the Python process without
# placing the API token in command-line arguments.
export SERVER_URL API_TOKEN NODE_NAME SIDECAR_TAG CONFIG_FILE

# ------------------------------------------------------------
# 3. Install Graylog Sidecar repository and package
# ------------------------------------------------------------

if [[ "$OS_FAMILY" == "debian" ]]; then
    log "Updating APT and installing required utilities..."

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl python3 python3-yaml

    log "Downloading official Graylog Sidecar repository package..."

    curl --fail --show-error --location --retry 3 \
        "$DEB_REPO_URL" \
        --output /tmp/graylog-sidecar-repository.deb

    log "Validating repository package..."

    dpkg-deb --info /tmp/graylog-sidecar-repository.deb >/dev/null ||
        die "Downloaded file is not a valid Debian package."

    log "Installing repository configuration..."

    dpkg -i /tmp/graylog-sidecar-repository.deb

    log "Refreshing package index..."

    apt-get update

    log "Installing Graylog Sidecar..."

    apt-get install -y graylog-sidecar

elif [[ "$OS_FAMILY" == "rhel" ]]; then
    log "Installing required utilities..."

    if command -v dnf >/dev/null 2>&1; then
        dnf install -y curl python3 python3-pyyaml
    else
        yum install -y curl python3 PyYAML
    fi

    log "Downloading official Graylog Sidecar repository package..."

    curl --fail --show-error --location --retry 3 \
        "$RPM_REPO_URL" \
        --output /tmp/graylog-sidecar-repository.rpm

    log "Validating RPM package..."

    rpm -qp /tmp/graylog-sidecar-repository.rpm >/dev/null ||
        die "Downloaded file is not a valid RPM package."

    log "Installing repository configuration..."

    rpm -Uvh /tmp/graylog-sidecar-repository.rpm

    log "Installing Graylog Sidecar..."

    if command -v dnf >/dev/null 2>&1; then
        dnf install -y graylog-sidecar
    else
        yum install -y graylog-sidecar
    fi
fi

# ------------------------------------------------------------
# 4. Verify installed package and configuration file
# ------------------------------------------------------------

command -v graylog-sidecar >/dev/null 2>&1 ||
    die "graylog-sidecar executable was not found after installation."

[[ -f "$CONFIG_FILE" ]] ||
    die "Configuration file not found: $CONFIG_FILE"

# ------------------------------------------------------------
# 5. Safely update sidecar.yml
# ------------------------------------------------------------

log "Configuring $CONFIG_FILE..."

python3 <<'PY'
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("ERROR: PyYAML is required to update sidecar.yml.")

path = Path(os.environ["CONFIG_FILE"])

try:
    original = path.read_text()
    config = yaml.safe_load(original) or {}
except Exception as exc:
    sys.exit(f"ERROR: Cannot read existing YAML configuration: {exc}")

if not isinstance(config, dict):
    sys.exit("ERROR: Existing sidecar.yml must contain a YAML mapping.")

config["server_url"] = os.environ["SERVER_URL"]
config["server_api_token"] = os.environ["API_TOKEN"]
config["node_name"] = os.environ["NODE_NAME"]
config["tags"] = [os.environ["SIDECAR_TAG"]]

# Preserve the original configuration in a restricted backup.
backup = path.with_name(path.name + ".bak")
backup.write_text(original)
os.chmod(backup, 0o600)

try:
    rendered = yaml.safe_dump(
        config,
        sort_keys=False,
        default_flow_style=False,
        allow_unicode=True
    )

    # Validate generated YAML before replacing the active file.
    yaml.safe_load(rendered)

    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(rendered)
    os.chmod(temporary, 0o600)
    temporary.replace(path)
    os.chmod(path, 0o600)

except Exception as exc:
    sys.exit(f"ERROR: Failed to update sidecar.yml: {exc}")

print("Configuration updated successfully.")
print(f"Backup saved to: {backup}")
PY

# ------------------------------------------------------------
# 6. Register and start system service
# ------------------------------------------------------------

log "Registering Graylog Sidecar service..."

graylog-sidecar -service install

systemctl daemon-reload

log "Enabling and starting Graylog Sidecar..."

systemctl enable graylog-sidecar
systemctl restart graylog-sidecar

sleep 3

# ------------------------------------------------------------
# 7. Check service status and report results
# ------------------------------------------------------------

echo
echo "=== Graylog Sidecar Service Status ==="

if systemctl is-active --quiet graylog-sidecar; then
    systemctl status graylog-sidecar --no-pager -l
else
    systemctl status graylog-sidecar --no-pager -l || true

    echo
    echo "=== Recent Service Logs ==="
    journalctl -u graylog-sidecar -n 50 --no-pager || true

    echo
    echo "=== Sidecar Application Log ==="
    tail -n 50 /var/log/graylog-sidecar/sidecar.log 2>/dev/null || true

    die "Sidecar service is not active."
fi

echo
echo "=== Installation Summary ==="
echo "OS:            ${PRETTY_NAME:-unknown}"
echo "Node name:     $NODE_NAME"
echo "Graylog API:   $SERVER_URL"
echo "Sidecar tag:   $SIDECAR_TAG"
echo "Service:       active"
echo "Config file:   $CONFIG_FILE"
echo
echo "Installation completed and service is running."
echo "Check the Sidecar application log to confirm Graylog registration:"
echo "  /var/log/graylog-sidecar/sidecar.log"
echo
echo "In Graylog, open System > Sidecars and verify the node."
echo "Note: Filebeat/another collector and a matching collector configuration"
echo "may still be needed to begin receiving logs."
