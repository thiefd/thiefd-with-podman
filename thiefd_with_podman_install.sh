#!/bin/bash

# THIEFD Install Script

# Exit immediately if a command exits with a non-zero status
set -e

# Function to print error messages
error() {
    echo "[ERROR] $1" >&2
}

# Function to print info messages
info() {
    echo "[INFO] $1"
}

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
   exit 1
fi

# Update package lists
info "Updating package lists..."
apt-get update

# Install system dependencies
info "Installing system dependencies..."
apt-get install -y lua5.3 liblua5.3-dev luarocks build-essential libssl-dev

# Install Lua dependencies
info "Installing Lua dependencies..."
luarocks install luasocket
luarocks install luasec
luarocks install lanes
luarocks install luafilesystem

# Install Certbot
info "Installing Certbot..."
apt-get install -y certbot

# Create configuration file
info "Creating configuration file..."
cat > /etc/thiefd.conf << EOL
# THIEFD Configuration

# Set to true for forward mode, false otherwise
THIEFD_FORWARD_MODE=false

# Podman image to use (replace with your image)
THIEFD_PODMAN_IMAGE="docker.io/registry/image:latest"

# API credentials (replace with secure values)
THIEFD_API_USERNAME="your-api-username"
THIEFD_API_PASSWORD="your-api-password"

# Server configuration
THIEFD_SERVER_PORT=443
THIEFD_DOMAIN="your-domain.com"
THIEFD_EMAIL="your-email@example.com"

# Custom endpoint (optional)
THIEFD_CUSTOM_ENDPOINT="/thiefd"

# Forward webhook URL (only needed if THIEFD_FORWARD_MODE is true)
# THIEFD_FORWARD_WEBHOOK_URL="https://your-webhook-url.com"
EOL

info "Configuration file created at /etc/thiefd.conf"
info "Please edit this file with your specific settings before running THIEFD"

# Download THIEFD script
info "Downloading THIEFD script..."
curl -o /usr/local/bin/thiefd.lua https://raw.githubusercontent.com/yourusername/thiefd/main/thiefd.lua
chmod +x /usr/local/bin/thiefd.lua

# Create systemd service file
info "Creating systemd service file..."
cat > /etc/systemd/system/thiefd.service << EOL
[Unit]
Description=THIEFD - Functions-as-a-Service in Lua with Podman
After=network.target

[Service]
ExecStart=/usr/bin/lua /usr/local/bin/thiefd.lua
Restart=always
User=root
Group=root
Environment=LD_LIBRARY_PATH=/usr/local/lib
EnvironmentFile=/etc/thiefd.conf

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd
systemctl daemon-reload

info "Installation completed successfully!"
info "Next steps:"
info "1. Edit the configuration file at /etc/thiefd.conf with your specific settings"
info "2. Start the THIEFD service: sudo systemctl start thiefd"
info "3. Enable THIEFD to start on boot: sudo systemctl enable thiefd"
info "4. Check the status of THIEFD: sudo systemctl status thiefd"

exit 0
