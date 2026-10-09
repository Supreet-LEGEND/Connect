#!/bin/bash
# Linux systemd Service Installer for Connect Background Transfer Service
# Run with: sudo ./install_systemd_service.sh

set -e

SERVICE_NAME="connect-transfer"
SERVICE_FILE="connect-transfer.service"
BINARY_NAME="connect-background-transfer"
INSTALL_DIR="/usr/local/bin"
SERVICE_DEST="/etc/systemd/system/${SERVICE_FILE}"
LOG_DIR="/var/log"
DATA_DIR="/var/lib/connect"
TRANSFER_DIR="/home/connect/ConnectTransfers"
USER_NAME="connect"

echo "Installing Connect Background Transfer Service for Linux..."

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

# Create user if not exists
if ! id "${USER_NAME}" &>/dev/null; then
    echo "Creating user ${USER_NAME}..."
    useradd -r -s /bin/false -d /home/connect -m "${USER_NAME}"
fi

# Create directories
echo "Creating directories..."
mkdir -p "${DATA_DIR}"
mkdir -p "${TRANSFER_DIR}"
mkdir -p "${LOG_DIR}"

# Set ownership
chown -R "${USER_NAME}:${USER_NAME}" "${DATA_DIR}"
chown -R "${USER_NAME}:${USER_NAME}" "${TRANSFER_DIR}"
chmod 755 "${DATA_DIR}"
chmod 755 "${TRANSFER_DIR}"

# Copy binary
echo "Installing binary to ${INSTALL_DIR}/${BINARY_NAME}..."
cp "${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
chmod 755 "${INSTALL_DIR}/${BINARY_NAME}"

# Copy service file
echo "Installing systemd service to ${SERVICE_DEST}..."
cp "${SERVICE_FILE}" "${SERVICE_DEST}"
chmod 644 "${SERVICE_DEST}"

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

# Enable and start service
echo "Enabling service..."
systemctl enable "${SERVICE_NAME}"

echo "Starting service..."
systemctl start "${SERVICE_NAME}"

# Check status
sleep 2
systemctl status "${SERVICE_NAME}" --no-pager

echo "Installation complete!"
echo ""
echo "Service status:"
systemctl status "${SERVICE_NAME}" --no-pager
echo ""
echo "To check logs: journalctl -u ${SERVICE_NAME} -f"
echo "To stop: sudo systemctl stop ${SERVICE_NAME}"
echo "To uninstall: sudo ./uninstall_systemd_service.sh"