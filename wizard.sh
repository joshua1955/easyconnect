#!/bin/bash

# Ensure the script is run as root
[ "$EUID" -eq 0 ] || {
    echo "Error: This script must be run as root. Exiting."
    exit 1
}

# Check if openconnect is installed
OCPATH=$(command -v openconnect)
[ -n "$OCPATH" ] || {
    echo "Error: 'openconnect' is not installed."
    echo "Install it using your package manager, e.g., 'apt install openconnect' or 'yum install openconnect'."
    exit 1
}

# Check if vpnc-script exists
VPNC_SCRIPT_PATH="/usr/share/vpnc-scripts/vpnc-script"
if [ ! -f "$VPNC_SCRIPT_PATH" ]; then
    echo "Warning: Standard vpnc-script not found at $VPNC_SCRIPT_PATH"
    echo "Installing vpnc-scripts package..."
    
    # Detect package manager and install
    if command -v apt &>/dev/null; then
        apt update && apt install -y vpnc-scripts
    elif command -v dnf &>/dev/null; then
        dnf install -y vpnc-script
    elif command -v yum &>/dev/null; then
        yum install -y vpnc-script
    else
        echo "Error: Cannot install vpnc-scripts. Please install manually."
        exit 1
    fi
fi

# Gather VPN connection details
echo "=== OpenConnect VPN Setup ==="
echo "Please provide the following VPN connection details:"

# Get VPN URL (hostname:port)
while :; do
    read -e -p "VPN server URL (e.g., vpn.example.com or vpn.example.com:9443): " VPN_URL
    if [ -z "$VPN_URL" ]; then
        echo "Error: VPN URL cannot be empty. Please try again."
    else
        break
    fi
done

# Extract hostname and port from URL
if [[ "$VPN_URL" =~ ^([^:]+):([0-9]+)$ ]]; then
    VPN_HOST="${BASH_REMATCH[1]}"
    VPN_PORT="${BASH_REMATCH[2]}"
else
    VPN_HOST="$VPN_URL"
    VPN_PORT="443"
fi

# Validate hostname
if ! getent ahosts "$VPN_HOST" >/dev/null 2>&1; then
    echo "Warning: Hostname '$VPN_HOST' could not be resolved. Please check your input."
    read -p "Continue anyway? (y/n): " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

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
while :; do
    read -e -i "tun0" -p "TUN interface name (default: tun0): " IFNAME
    if [ -z "$IFNAME" ]; then
        IFNAME="tun0"
    fi
    break
done

# Service name
SERVICE_NAME="openconnect.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

# Handle existing service
if [ -f "$SERVICE_FILE" ]; then
    echo "An existing OpenConnect service was detected."
    read -p "Do you want to replace the existing service? (y/n): " REMOVE_OLD
    if [[ ! "$REMOVE_OLD" =~ ^[Yy]$ ]]; then
        echo "No changes made. Exiting."
        exit 0
    fi
    
    # Stop and disable existing service
    systemctl is-active --quiet "$SERVICE_NAME" && systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl is-enabled --quiet "$SERVICE_NAME" && systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$SERVICE_FILE"
fi

# Build OpenConnect options
OCOPTIONS="--user $VPN_USER --passwd-on-stdin --script=$VPNC_SCRIPT_PATH"

# Add interface if specified
[ -n "$IFNAME" ] && OCOPTIONS+=" --interface $IFNAME"

# Build URL with port if not default
if [ "$VPN_PORT" -eq 443 ]; then
    CONNECT_URL="$VPN_HOST"
else
    CONNECT_URL="$VPN_HOST:$VPN_PORT"
fi

# Create systemd service file (with proper escaping for special characters)
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
Environment="URL=$CONNECT_URL"
ExecStart=/bin/bash -c 'echo "\$PASSWD" | $OCPATH \$OCOPTIONS \$URL'
ExecStop=/bin/kill -SIGINT \$MAINPID
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Fix the ExecStart line - we need to expand OCOPTIONS properly
sed -i 's|ExecStart=/bin/bash -c '\''echo "\\\$PASSWD" | $OCPATH \\\$OCOPTIONS \\\$URL'\''|ExecStart=/bin/bash -c '\''echo "$PASSWD" | /usr/sbin/openconnect --user="$USER" --passwd-on-stdin --script=/usr/share/vpnc-scripts/vpnc-script --interface tun0 "$URL"'\''|' "$SERVICE_FILE"

echo "Service file created at $SERVICE_FILE."

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

# Enable and start service
echo "Enabling service..."
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || {
    echo "Error: Failed to enable service."
}

echo "Starting service..."
systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || {
    echo "Error: Failed to start service. Check logs."
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager
}

# Final check
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "========================================="
    echo "✅ OpenConnect VPN service is running!"
    echo "========================================="
    echo ""
    echo "Service name: $SERVICE_NAME"
    echo "VPN URL: $CONNECT_URL"
    echo "Username: $VPN_USER"
    echo "Interface: $IFNAME"
    echo ""
    echo "Commands:"
    echo "  Status:   sudo systemctl status $SERVICE_NAME"
    echo "  Logs:     sudo journalctl -u $SERVICE_NAME -f"
    echo "  Stop:     sudo systemctl stop $SERVICE_NAME"
    echo "  Restart:  sudo systemctl restart $SERVICE_NAME"
    echo ""
    echo "To check routing:"
    echo "  ip route show"
    echo "  ping -c 4 8.8.8.8"
else
    echo "========================================="
    echo "❌ Service failed to start!"
    echo "========================================="
    echo ""
    echo "Check logs for details:"
    echo "  sudo journalctl -u $SERVICE_NAME -n 50 --no-pager"
    echo ""
    echo "Try manually:"
    echo "  echo \"$VPN_PASS\" | sudo openconnect --user=$VPN_USER --script=/usr/share/vpnc-scripts/vpnc-script $CONNECT_URL"
fi
