#!/bin/bash

# Function to display messages
show() {
    echo "$1"
}

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    show "jq not found, installing..."
    sudo apt-get update
    sudo apt-get install -y jq > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        show "Failed to install jq. Please check your package manager."
        exit 1
    fi
fi

# Function to get the latest version
check_latest_version() {
    local REPO_URL="https://api.github.com/repos/hemilabs/heminetwork/releases/latest"

    for i in {1..3}; do
        LATEST_VERSION=$(curl -s "$REPO_URL" | jq -r '.tag_name')
        if [ $? -ne 0 ]; then
            show "curl failed. Please ensure curl is installed and working properly."
            exit 1
        fi

        if [ -n "$LATEST_VERSION" ]; then
            show "Latest version available: $LATEST_VERSION"
            return 0
        fi

        show "Attempt $i: Failed to fetch the latest version. Retrying..."
        sleep 2
    done

    show "Failed to fetch the latest version after 3 attempts. Please check your internet connection or GitHub API limits."
    exit 1
}

# Call the function to get the latest version
check_latest_version

# Detect the architecture before downloading binaries
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    ARCH_FOLDER="heminetwork_${LATEST_VERSION}_linux_amd64"
    DOWNLOAD_URL="https://github.com/hemilabs/heminetwork/releases/download/${LATEST_VERSION}/heminetwork_${LATEST_VERSION}_linux_amd64.tar.gz"
elif [ "$ARCH" = "arm64" ]; then
    ARCH_FOLDER="heminetwork_${LATEST_VERSION}_linux_arm64"
    DOWNLOAD_URL="https://github.com/hemilabs/heminetwork/releases/download/${LATEST_VERSION}/heminetwork_${LATEST_VERSION}_linux_arm64.tar.gz"
else
    show "Unsupported architecture: $ARCH"
    exit 1
fi

# Create 'hemi' directory if it doesn't exist
HEMI_DIR="/root/hemi"
if [ ! -d "$HEMI_DIR" ]; then
    show "Creating directory: $HEMI_DIR"
    mkdir -p "$HEMI_DIR"
    if [ $? -ne 0 ]; then
        show "Failed to create directory $HEMI_DIR."
        exit 1
    fi
fi

# Check if the current version matches the latest version
CURRENT_VERSION=$(grep -oP '(?<=heminetwork_)[^/]*' "$HEMI_DIR/heminetwork_${LATEST_VERSION}_linux_amd64/popmd" 2>/dev/null)

if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
    # If not up to date, download the latest version
    show "Downloading $ARCH_FOLDER..."
    curl -L "$DOWNLOAD_URL" -o "$HEMI_DIR/${ARCH_FOLDER}.tar.gz"
    if [ $? -ne 0 ]; then
        show "Failed to download file. Please check your internet connection."
        exit 1
    fi
    show "Downloaded: $HEMI_DIR/${ARCH_FOLDER}.tar.gz"

    # Extract the downloaded file into the 'hemi' folder
    show "Extracting file..."
    tar -xzf "$HEMI_DIR/${ARCH_FOLDER}.tar.gz" -C "$HEMI_DIR"
    if [ $? -ne 0 ]; then
        show "Failed to extract file."
        exit 1
    fi
    show "Extraction complete."
else
    show "You are already using the latest version: $LATEST_VERSION."
fi

# Set the service name
SERVICE_NAME="hemi-miner.service"

# Reload systemd daemon before checking anything
sudo systemctl daemon-reload

# Check if the service exists
if systemctl status "$SERVICE_NAME" > /dev/null 2>&1; then
    # If the service exists, check if it's running
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        sudo systemctl stop "$SERVICE_NAME"
        show "$SERVICE_NAME stopped."
    fi

    # Get existing private key and fee if available
    POPM_BTC_PRIVKEY=$(systemctl show "$SERVICE_NAME" -p Environment | grep -oP '(?<=POPM_BTC_PRIVKEY=).*')
    POPM_STATIC_FEE=$(systemctl show "$SERVICE_NAME" -p Environment | grep -oP '(?<=POPM_STATIC_FEE=).*')

    # Ask if the user wants to update the private key or fees
    read -p "Do you want to change your POPM_BTC_PRIVKEY? (yes/no): " change_key
    if [ "$change_key" == "yes" ]; then
        read -p "Enter your new POPM_BTC_PRIVKEY: " POPM_BTC_PRIVKEY
    fi

    read -p "Do you want to change your POPM_STATIC_FEE? (yes/no): " change_fee
    if [ "$change_fee" == "yes" ]; then
        read -p "Enter your new POPM_STATIC_FEE: " POPM_STATIC_FEE
    fi

    # Ask if the wallet information is correct
    if [ -n "$POPM_BTC_PRIVKEY" ] && [ -n "$POPM_STATIC_FEE" ]; then
        echo "{\"private_key\": \"$POPM_BTC_PRIVKEY\", \"static_fee\": \"$POPM_STATIC_FEE\"}" > ~/popm-address.json
        show "Wallet info:"
        cat ~/popm-address.json
        
        while true; do
            read -p "Is the wallet information correct? (yes/no): " confirm
            if [ "$confirm" == "yes" ]; then
                break
            else
                read -p "Do you want to change your POPM_BTC_PRIVKEY or fees? (key/fee/no): " change_choice
                if [ "$change_choice" == "key" ]; then
                    read -p "Enter your new POPM_BTC_PRIVKEY: " POPM_BTC_PRIVKEY
                elif [ "$change_choice" == "fee" ]; then
                    read -p "Enter your new POPM_STATIC_FEE: " POPM_STATIC_FEE
                fi
            fi
        done
    fi

else
    # If the service does not exist, ask for POPM_BTC_PRIVKEY and POPM_STATIC_FEE
    show "Service $SERVICE_NAME does not exist. Proceeding to set up the miner..."

    read -p "Do you want to use an existing wallet or generate a new one? (existing/new): " wallet_choice

    if [ "$wallet_choice" == "existing" ]; then
        while true; do
            read -p "Enter your POPM_BTC_PRIVKEY: " POPM_BTC_PRIVKEY
            read -p "Enter your POPM_STATIC_FEE: " POPM_STATIC_FEE  # Ask for the static fee
            # Show the private key and static fee in a dummy JSON format to simulate the address file
            echo "{\"private_key\": \"$POPM_BTC_PRIVKEY\", \"static_fee\": \"$POPM_STATIC_FEE\"}" > ~/popm-address.json
            show "Wallet info:"
            cat ~/popm-address.json
            
            # Ask if the information is correct
            read -p "Is the wallet information correct? (yes/no): " confirm
            if [ "$confirm" == "yes" ]; then
                break
            else
                read -p "Do you want to change your POPM_BTC_PRIVKEY or fees? (key/fee/no): " change_choice
                if [ "$change_choice" == "key" ]; then
                    read -p "Enter your new POPM_BTC_PRIVKEY: " POPM_BTC_PRIVKEY
                elif [ "$change_choice" == "fee" ]; then
                    read -p "Enter your new POPM_STATIC_FEE: " POPM_STATIC_FEE  # Allow changing of the fee
                fi
            fi
        done
    else
        echo "Generating a new wallet..."
        KEYGEN_BINARY="$HEMI_DIR/heminetwork_${LATEST_VERSION}_linux_amd64/keygen"  # Update this path as needed
        $KEYGEN_BINARY -secp256k1 -json -net="testnet" > ~/popm-address.json
        show "New wallet generated. Wallet info:"
        cat ~/popm-address.json
        POPM_BTC_PRIVKEY=$(jq -r '.private_key // empty' ~/popm-address.json)
        POPM_STATIC_FEE=$(jq -r '.static_fee // empty' ~/popm-address.json)  # Assuming the static fee is available

        if [ -z "$POPM_BTC_PRIVKEY" ]; then
            show "Error: Private key not found in generated wallet info."
            exit 1
        fi
    fi

    read -p "Enter your POPM_STATIC_FEE: " POPM_STATIC_FEE
fi

# Create or update the systemd service file
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

cat <<EOL | sudo tee "$SERVICE_FILE"
[Unit]
Description=Hemi Proof of Proof Miner Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$HEMI_DIR/heminetwork_${LATEST_VERSION}_linux_amd64/popmd
Restart=always
Environment=POPM_BTC_PRIVKEY=$POPM_BTC_PRIVKEY
Environment=POPM_STATIC_FEE=$POPM_STATIC_FEE

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd to apply changes and start the service
sudo systemctl daemon-reload
sudo systemctl start "$SERVICE_NAME"
show "$SERVICE_NAME started."

# Real-time service logs
sudo journalctl -f -u "$SERVICE_NAME" &
