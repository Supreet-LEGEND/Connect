#!/bin/bash
# Linux systemd service setup for Connect Background Transfer
# Run as root for system service, or as user for user service

set -e

SERVICE_TYPE="${1:-user}"  # "system" or "user"
BINARY_PATH="${2:-$HOME/.local/bin/connect-background-transfer}"

echo "Setting up Connect Background Transfer Service ($SERVICE_TYPE)..."

if [[ "$SERVICE_TYPE" == "system" ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "System service installation requires root privileges"
        echo "Run with: sudo $0 system /usr/local/bin/connect-background-transfer"
        exit 1
    fi
    
    SERVICE_FILE="platform/linux/connect-transfer.service"
    TARGET_DIR="/etc/systemd/system"
    BINARY_DEST="/usr/local/bin/connect-background-transfer"
    
    # Create connect user if not exists
    if ! id "connect" &>/dev/null; then
        useradd -r -s /bin/false -d /var/lib/connect connect
        mkdir -p /var/lib/connect
        chown connect:connect /var/lib/connect
    fi
    
    # Create transfer directory
    mkdir -p /home/connect/ConnectTransfers
    chown connect:connect /home/connect/ConnectTransfers
    
else
    SERVICE_FILE="platform/linux/connect-transfer-user.service"
    TARGET_DIR="$HOME/.config/systemd/user"
    BINARY_DEST="$HOME/.local/bin/connect-background-transfer"
    mkdir -p "$HOME/.local/bin"
    mkdir -p "$HOME/ConnectTransfers"
    mkdir -p "$HOME/.local/share/connect"
fi

# Copy binary
if [[ -f "$BINARY_PATH" ]]; then
    cp "$BINARY_PATH" "$BINARY_DEST"
    chmod +x "$BINARY_DEST"
else
    echo "Binary not found at: $BINARY_PATH"
    echo "Please build the Rust service first:"
    echo "  cargo build --release --manifest-path platform/windows/background_service/Cargo.toml"
    exit 1
fi

# Copy service file
mkdir -p "$TARGET_DIR"
cp "$SERVICE_FILE" "$TARGET_DIR/"

# Reload systemd
if [[ "$SERVICE_TYPE" == "system" ]]; then
    systemctl daemon-reload
    systemctl enable connect-transfer.service
    echo "System service installed. Start with: sudo systemctl start connect-transfer"
else
    systemctl --user daemon-reload
    systemctl --user enable connect-transfer-user.service
    echo "User service installed. Start with: systemctl --user start connect-transfer-user"
fi

echo "Setup complete!"