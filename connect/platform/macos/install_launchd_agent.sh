#!/bin/bash
# macOS Launchd Agent Installer for Connect Background Transfer Service
# Run with: sudo ./install_launchd_agent.sh

set -e

SERVICE_NAME="com.connect.background-transfer"
PLIST_FILE="com.connect.background-transfer.plist"
BINARY_NAME="connect-background-transfer"
INSTALL_DIR="/usr/local/bin"
PLIST_DEST="/Library/LaunchDaemons/${PLIST_FILE}"
LOG_DIR="/var/log"
DATA_DIR="/var/lib/connect"
TRANSFER_DIR="/Users/Shared/ConnectTransfers"

echo "Installing Connect Background Transfer Service for macOS..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Check if binary exists
if [ ! -f "${BINARY_NAME}" ]; then
    echo "Error: Binary ${BINARY_NAME} not found in current directory"
    echo "Please build the service first: cargo build --release"
    exit 1
fi

# Create directories
echo "Creating directories..."
mkdir -p "${DATA_DIR}"
mkdir -p "${TRANSFER_DIR}"
mkdir -p "${LOG_DIR}"

# Copy binary
echo "Installing binary to ${INSTALL_DIR}/${BINARY_NAME}..."
cp "${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
chmod 755 "${INSTALL_DIR}/${BINARY_NAME}"

# Copy plist
echo "Installing launchd plist to ${PLIST_DEST}..."
cp "${PLIST_FILE}" "${PLIST_DEST}"
chmod 644 "${PLIST_DEST}"
chown root:wheel "${PLIST_DEST}"

# Set ownership of data directories
chown -R root:wheel "${DATA_DIR}"
chmod 755 "${DATA_DIR}"
chown -R root:wheel "${TRANSFER_DIR}"
chmod 755 "${TRANSFER_DIR}"

# Load the service
echo "Loading launchd service..."
launchctl load "${PLIST_DEST}"

# Enable at boot
launchctl enable "system/${SERVICE_NAME}"

echo "Installation complete!"
echo ""
echo "Service status:"
launchctl list | grep "${SERVICE_NAME}" || echo "Service not yet running (will start on next boot)"
echo ""
echo "To start now: sudo launchctl start ${SERVICE_NAME}"
echo "To stop: sudo launchctl stop ${SERVICE_NAME}"
echo "To uninstall: sudo ./uninstall_launchd_agent.sh"