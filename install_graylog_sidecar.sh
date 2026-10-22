#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or use sudo."
  exit 1
fi

# 1. Collect user configuration details
echo "=== Graylog Sidecar Configuration ==="
read -p "Enter Graylog Server API URL (e.g., http://192.168.1): " SERVER_URL
read -p "Enter Graylog Server API Token: " API_TOKEN
read -p "Enter Node Name for this client (e.g., prod-web-01): " NODE_NAME
read -p "Enter Sidecar Tag (e.g., linux): " SIDECAR_TAG
echo "====================================="

# 2. Detect OS and install the Sidecar package
if [ -f /etc/debian_version ]; then
    echo "Detected Debian/Ubuntu-based system. Installing repository..."
    # Using the correct URL for the official Graylog sidecar repository package
    wget -q https://graylog2.org -O /tmp/graylog-sidecar-repository.deb
    dpkg -i /tmp/graylog-sidecar-repository.deb
    
    # Run apt update and force clean, non-interactive installations
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y graylog-sidecar filebeat

elif [ -f /etc/redhat-release ]; then
    echo "Detected RHEL/CentOS-based system. Installing repository..."
    # Using the correct URL for RHEL package delivery
    rpm -Uvh --quiet https://graylog2.org || true
    
    if command -v dnf &> /dev/null; then
        dnf install -y graylog-sidecar filebeat
    else
        yum install -y graylog-sidecar filebeat
    fi
else
    echo "Unsupported operating system."
    exit 1
fi

# 3. Use sed to inject configurations into sidecar.yml
CONFIG_FILE="/etc/graylog/sidecar/sidecar.yml"

if [ -f "$CONFIG_FILE" ]; then
    echo "Configuring sidecar.yml..."
    
    # Escape special characters for sed in the URL
    ESC_URL=$(echo "$SERVER_URL" | sed 's/[&/]/\\&/g')

    # Update the server_url, server_api_token, node_name, and tags fields
    sed -i "s|^#\?server_url:.*|server_url: \"$ESC_URL\"|" "$CONFIG_FILE"
    sed -i "s|^#\?server_api_token:.*|server_api_token: \"$API_TOKEN\"|" "$CONFIG_FILE"
    sed -i "s|^#\?node_name:.*|node_name: \"$NODE_NAME\"|" "$CONFIG_FILE"
    sed -i "s|^#\?tags:.*|tags: [\"$SIDECAR_TAG\"]|" "$CONFIG_FILE"
else
    echo "Error: Configuration file $CONFIG_FILE not found!"
    exit 1
fi

# 4. Install and start the Sidecar system service
echo "Registering and starting Graylog Sidecar service..."
graylog-sidecar -service install || true
systemctl enable graylog-sidecar
systemctl restart graylog-sidecar

# 5. Output Final Status
echo "====================================="
echo "Graylog Sidecar installation complete!"
systemctl status graylog-sidecar --no-pager
