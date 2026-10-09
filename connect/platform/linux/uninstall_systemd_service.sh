#!/bin/bash
# Linux systemd Service Uninstaller for Connect Background Transfer Service
# Run with: sudo ./uninstall_systemd_service.sh

set -e

SERVICE_NAME="connect-transfer"
SERVICE_FILE="connect-transfer.service"
BINARY_NAME="connect-background-transfer"
INSTALL_DIR="/usr/local/bin"
SERVICE_DEST="/etc/systemd/system/${SERVICE_FILE}"

echo "Uninstalling Connect Background Transfer Service for Linux..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Stop and disable service
echo "Stopping and disabling service..."
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

# Remove service file
echo "Removing systemd service file..."
rm -f "${SERVICE_DEST}"

# Reload systemd
systemctl daemon-reload

# Remove binary
echo "Removing binary..."
rm -f "${INSTALL_DIR}/${BINARY_NAME}"

# Optionally remove data directories (commented out to preserve data)
# echo "Removing data directories..."
# rm -rf "/var/lib/connect"
# rm -rf "/home/connect/ConnectTransfers"
# userdel connect 2>/dev/null || true

echo "Uninstallation complete!"
echo ""
echo "Note: Data directories and logs were preserved."
echo "To completely remove all data, run:"
echo "  sudo rm -rf /var/lib/connect /home/connect/ConnectTransfers"
echo "  sudo userdel connect"