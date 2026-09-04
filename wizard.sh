#!/bin/bash

# Ensure the script is run as root
[ "$EUID" -eq 0 ] || {
    echo "Error: This script must be run as root. Exiting."
    exit 1
}

# Function to check and install package
install_package() {
    local package=$1
    local package_name=$2
    
    echo "Checking for $package_name..."
    
    if command -v "$package" &>/dev/null; then
        echo "✅ $package_name is installed: $(command -v "$package")"
        return 0
    fi
    
    echo "❌ $package_name is not installed."
    echo "Attempting to install $package_name..."
    
    if command -v apt &>/dev/null; then
        apt update
        apt install -y "$package"
    elif command -v dnf &>/dev/null; then
        dnf install -y "$package"
    elif command -v yum &>/dev/null; then
        yum install -y "$package"
    elif command -v zypper &>/dev/null; then
        zypper install -y "$package"
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm "$package"
    else
        echo "Error: No supported package manager found (apt, dnf, yum, zypper, pacman)."
        echo "Please install $package_name manually."
        return 1
    fi
    
    # Verify installation
    if command -v "$package" &>/dev/null; then
        echo "✅ $package_name successfully installed: $(command -v "$package")"
        return 0
    else
        echo "❌ Failed to install $package_name. Please install it manually."
        return 1
    fi
}

# Check and install openconnect
echo "=== Checking OpenConnect ==="
if ! install_package "openconnect" "openconnect"; then
    exit 1
fi

# Check vpnc-scripts
echo "=== Checking VPNC Scripts ==="
VPNC_SCRIPT_PATH="/usr/share/vpnc-scripts/vpnc-script"
VPNC_SCRIPT_ALT="/etc/vpnc/vpnc-script"

# Check if vpnc-script exists in standard locations
if [ -f "$VPNC_SCRIPT_PATH" ]; then
    echo "✅ vpnc-script found at: $VPNC_SCRIPT_PATH"
elif [ -f "$VPNC_SCRIPT_ALT" ]; then
    echo "✅ vpnc-script found at: $VPNC_SCRIPT_ALT"
    VPNC_SCRIPT_PATH="$VPNC_SCRIPT_ALT"
else
    echo "❌ vpnc-script not found."
    echo "Attempting to install vpnc-scripts..."
    
    # Try to install vpnc-scripts package
    INSTALL_SUCCESS=false
    
    if command -v apt &>/dev/null; then
        apt update
        apt install -y vpnc-scripts
        [ -f "$VPNC_SCRIPT_PATH" ] && INSTALL_SUCCESS=true
    elif command -v dnf &>/dev/null; then
        dnf install -y vpnc-script
        [ -f "$VPNC_SCRIPT_PATH" ] && INSTALL_SUCCESS=true
    elif command -v yum &>/dev/null; then
        yum install -y vpnc-script
        [ -f "$VPNC_SCRIPT_PATH" ] && INSTALL_SUCCESS=true
    elif command -v zypper &>/dev/null; then
        zypper install -y vpnc-scripts
        [ -f "$VPNC_SCRIPT_PATH" ] && INSTALL_SUCCESS=true
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm vpnc-scripts
        [ -f "$VPNC_SCRIPT_PATH" ] && INSTALL_SUCCESS=true
    else
        echo "Error: No supported package manager found."
        echo "Please install vpnc-scripts manually:"
        echo "  - Ubuntu/Debian: apt install vpnc-scripts"
        echo "  - RHEL/CentOS: yum install vpnc-script"
        echo "  - Fedora: dnf install vpnc-script"
        echo "  - Arch: pacman -S vpnc-scripts"
        echo "  - SUSE: zypper install vpnc-scripts"
        exit 1
    fi
    
    # Verify installation
    if [ -f "$VPNC_SCRIPT_PATH" ] || [ -f "$VPNC_SCRIPT_ALT" ]; then
        echo "✅ vpnc-scripts successfully installed."
        [ -f "$VPNC_SCRIPT_ALT" ] && VPNC_SCRIPT_PATH="$VPNC_SCRIPT_ALT"
    else
        echo "❌ Failed to install vpnc-scripts."
        echo "Please install it manually and run this script again."
        exit 1
    fi
fi

# Gather VPN connection details
echo ""
echo "=== OpenConnect VPN Setup ==="
echo "Please provide the following VPN connection details:"

# Get VPN URL
while :; do
    read -e -p "VPN server URL (e.g., vpn.example.com or vpn.example.com:9443): " VPN_URL
    if [ -z "$VPN_URL" ]; then
        echo "Error: VPN URL cannot be empty. Please try again."
    else
        break
    fi
done

# Get VPN username
while :; do
    read -e -p "VPN username: " VPN_USER
    if [ -z "$VPN_USER" ]; then
        echo "Error: VPN username cannot be empty. Please try again."
    else
        break
    fi
done

# Get VPN password
while :; do
    read -sp "VPN password: " VPN_PASS
    echo
    if [ -z "$VPN_PASS" ]; then
        echo "Error: VPN password cannot be empty. Please try again."
    else
        break
    fi
done

# Get TUN interface name
read -e -i "tun0" -p "TUN interface name (default: tun0): " IFNAME
[ -z "$IFNAME" ] && IFNAME="tun0"

# Service name
SERVICE_NAME="openconnect.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

# Handle existing service
if [ -f "$SERVICE_FILE" ]; then
    echo ""
    echo "⚠️  An existing OpenConnect service was detected."
    read -p "Do you want to replace the existing service? (y/n): " REMOVE_OLD
    if [[ ! "$REMOVE_OLD" =~ ^[Yy]$ ]]; then
        echo "No changes made. Exiting."
        exit 0
    fi
    
    echo "Stopping and disabling existing service..."
    systemctl is-active --quiet "$SERVICE_NAME" && systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl is-enabled --quiet "$SERVICE_NAME" && systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$SERVICE_FILE"
fi

# Create systemd service file with environment variables
echo ""
echo "Creating systemd service file..."
cat <<EOF >"$SERVICE_FILE"
[Unit]
Description=OpenConnect VPN Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment="PASSWD=$VPN_PASS"
Environment="USER=$VPN_USER"
Environment="URL=$VPN_URL"
ExecStart=/bin/bash -c 'echo "\$PASSWD" | /usr/sbin/openconnect --non-inter --user="\$USER" --passwd-on-stdin --script=$VPNC_SCRIPT_PATH --interface $IFNAME "\$URL"'
ExecStop=/bin/kill -SIGINT \$MAINPID
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "✅ Service file created at $SERVICE_FILE."

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

# Enable and start service
echo "Enabling and starting service..."
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
systemctl start "$SERVICE_NAME" >/dev/null 2>&1

# Wait a moment for service to start
sleep 2

# Final check
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo ""
    echo "========================================="
    echo "✅ OpenConnect VPN service is running!"
    echo "========================================="
    echo ""
    echo "Service: $SERVICE_NAME"
    echo "VPN URL: $VPN_URL"
    echo "Username: $VPN_USER"
    echo "Interface: $IFNAME"
    echo "VPN Script: $VPNC_SCRIPT_PATH"
    echo ""
    echo "Commands:"
    echo "  Status:   sudo systemctl status $SERVICE_NAME"
    echo "  Logs:     sudo journalctl -u $SERVICE_NAME -f"
    echo "  Stop:     sudo systemctl stop $SERVICE_NAME"
    echo "  Restart:  sudo systemctl restart $SERVICE_NAME"
    echo ""
    echo "Check routing:"
    echo "  ip route show"
    echo "  ping -c 4 8.8.8.8"
    echo ""
    echo "To view VPN logs in real-time:"
    echo "  sudo journalctl -u $SERVICE_NAME -f"
else
    echo ""
    echo "========================================="
    echo "❌ Service failed to start!"
    echo "========================================="
    echo ""
    echo "Last 20 lines from journal:"
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager
    echo ""
    echo "For more details, run:"
    echo "  sudo journalctl -u $SERVICE_NAME -f"
    exit 1
fi
