#!/bin/bash
# macOS Launchd Agent Uninstaller for Connect Background Transfer Service
# Run with: sudo ./uninstall_launchd_agent.sh

set -e

SERVICE_NAME="com.connect.background-transfer"
PLIST_FILE="com.connect.background-transfer.plist"
BINARY_NAME="connect-background-transfer"
INSTALL_DIR="/usr/local/bin"
PLIST_DEST="/Library/LaunchDaemons/${PLIST_FILE}"

echo "Uninstalling Connect Background Transfer Service for macOS..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Unload and disable the service
echo "Stopping and disabling service..."
launchctl stop "${SERVICE_NAME}" 2>/dev/null || true
launchctl unload "${PLIST_DEST}" 2>/dev/null || true
launchctl disable "system/${SERVICE_NAME}" 2>/dev/null || true

# Remove plist
echo "Removing launchd plist..."
rm -f "${PLIST_DEST}"

# Remove binary
echo "Removing binary..."
rm -f "${INSTALL_DIR}/${BINARY_NAME}"

# Optionally remove data directories (commented out to preserve data)
# echo "Removing data directories..."
# rm -rf "/var/lib/connect"
# rm -rf "/Users/Shared/ConnectTransfers"
# rm -f "/var/log/connect-background-transfer.log"
# rm -f "/var/log/connect-background-transfer.error.log"

echo "Uninstallation complete!"
echo ""
echo "Note: Data directories and logs were preserved."
echo "To completely remove all data, run:"
echo "  sudo rm -rf /var/lib/connect /Users/Shared/ConnectTransfers"
echo "  sudo rm -f /var/log/connect-background-transfer.log /var/log/connect-background-transfer.error.log"