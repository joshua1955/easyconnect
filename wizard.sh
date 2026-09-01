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
    echo "An existing OpenConnect service was detected."
    read -p "Do you want to replace the existing service? (y/n): " REMOVE_OLD
    if [[ ! "$REMOVE_OLD" =~ ^[Yy]$ ]]; then
        echo "No changes made. Exiting."
        exit 0
    fi
    
    systemctl is-active --quiet "$SERVICE_NAME" && systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl is-enabled --quiet "$SERVICE_NAME" && systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$SERVICE_FILE"
fi

# Save password to file (more reliable)
PASSWD_FILE="/etc/openconnect-pass"
echo "$VPN_PASS" > "$PASSWD_FILE"
chmod 600 "$PASSWD_FILE"

# Create systemd service file - clean and simple!
cat <<EOF >"$SERVICE_FILE"
[Unit]
Description=OpenConnect VPN Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/sbin/openconnect --non-inter --user=$VPN_USER --passwd-on-stdin --script=$VPNC_SCRIPT_PATH --interface $IFNAME $VPN_URL < $PASSWD_FILE
ExecStop=/bin/kill -SIGINT \$MAINPID
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "Service file created at $SERVICE_FILE."

# Reload systemd
systemctl daemon-reload

# Enable and start service
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
systemctl start "$SERVICE_NAME" >/dev/null 2>&1

# Final check
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "========================================="
    echo "✅ OpenConnect VPN service is running!"
    echo "========================================="
    echo ""
    echo "Service: $SERVICE_NAME"
    echo "VPN URL: $VPN_URL"
    echo "Username: $VPN_USER"
    echo "Interface: $IFNAME"
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
else
    echo "========================================="
    echo "❌ Service failed to start!"
    echo "========================================="
    echo ""
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager
fi
