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
        LATEST_VERSION=$(curl -s $REPO_URL | jq -r '.tag_name')
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

# Detect the architecture
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

# Create a directory named 'hemi' if it doesn't exist
if [ ! -d "hemi" ]; then
    mkdir hemi
    show "Created folder: hemi"
fi

# Download the file into the 'hemi' folder
show "Downloading $ARCH_FOLDER..."
curl -L $DOWNLOAD_URL -o "hemi/${ARCH_FOLDER}.tar.gz"
if [ $? -ne 0 ]; then
    show "Failed to download file. Please check your internet connection."
    exit 1
fi
show "Downloaded: hemi/${ARCH_FOLDER}.tar.gz"

# Extract the downloaded file into the 'hemi' folder
show "Extracting file..."
tar -xzf "hemi/${ARCH_FOLDER}.tar.gz" -C hemi
if [ $? -ne 0 ]; then
    show "Failed to extract file."
    exit 1
fi
show "Extraction complete."

# Check if the service exists
SERVICE_NAME="hemi-miner.service"
if systemctl list-units --full --quiet --all "$SERVICE_NAME"; then
    # If the service exists, check if it's active
    if systemctl is-active --quiet $SERVICE_NAME; then
        show "Service $SERVICE_NAME is currently running. Stopping service..."
        sudo systemctl stop $SERVICE_NAME
    fi

    # Retrieve latest binaries
    show "Downloading latest binaries..."
    curl -L $DOWNLOAD_URL -o "hemi/${ARCH_FOLDER}.tar.gz"
    if [ $? -ne 0 ]; then
        show "Failed to download file. Please check your internet connection."
        exit 1
    fi
    show "Downloaded: hemi/${ARCH_FOLDER}.tar.gz"

    show "Extracting file..."
    tar -xzf "hemi/${ARCH_FOLDER}.tar.gz" -C hemi
    if [ $? -ne 0 ]; then
        show "Failed to extract file."
        exit 1
    fi
    show "Extraction complete."

    # Ask user for POPM_BTC_PRIVKEY and POPM_STATIC_FEE
    read -p "Do you want to change your POPM_BTC_PRIVKEY? (yes/no): " change_key
    if [ "$change_key" == "yes" ]; then
        read -p "Enter your POPM_BTC_PRIVKEY: " POPM_BTC_PRIVKEY
    else
        POPM_BTC_PRIVKEY=$(systemctl show $SERVICE_NAME | grep POPM_BTC_PRIVKEY | cut -d '=' -f2)
        show "Using existing POPM_BTC_PRIVKEY: $POPM_BTC_PRIVKEY"
    fi

    read -p "Do you want to change your POPM_STATIC_FEE? (yes/no): " change_fee
    if [ "$change_fee" == "yes" ]; then
        read -p "Enter your new POPM_STATIC_FEE: " POPM_STATIC_FEE
    else
        POPM_STATIC_FEE=$(systemctl show $SERVICE_NAME | grep POPM_STATIC_FEE | cut -d '=' -f2)
        show "Using existing POPM_STATIC_FEE: $POPM_STATIC_FEE"
    fi

    # Restart the service
    systemctl daemon-reload
    show "Restarting service $SERVICE_NAME..."
    sudo systemctl start $SERVICE_NAME
    show "Service restarted."

else
    # If service does not exist, ask for POPM_BTC_PRIVKEY and POPM_STATIC_FEE
    show "Service $SERVICE_NAME does not exist. Proceeding to set up the miner..."

    read -p "Do you want to use an existing wallet or generate a new one? (existing/new): " wallet_choice

    if [ "$wallet_choice" == "existing" ]; then
        read -p "Enter your POPM_BTC_PRIVKEY: " POPM_BTC_PRIVKEY
    else
        echo "Generating a new wallet..."
        KEYGEN_BINARY="./hemi/heminetwork_${LATEST_VERSION}_linux_amd64/keygen"  # Update this path as needed
        $KEYGEN_BINARY -secp256k1 -json -net="testnet" > ~/popm-address.json
        show "New wallet generated. Wallet info:"
        cat ~/popm-address.json
        POPM_BTC_PRIVKEY=$(jq -r '.privkey // empty' ~/popm-address.json)
        
        if [ -z "$POPM_BTC_PRIVKEY" ]; then
            show "Error: Private key not found in generated wallet info."
            exit 1
        fi
    fi

    read -p "Enter your POPM_STATIC_FEE: " POPM_STATIC_FEE
fi

# Create a systemd service file
SERVICE_FILE="/etc/systemd/system/hemi-miner.service"

cat <<EOL | sudo tee $SERVICE_FILE
[Unit]
Description=Hemi Proof of Proof Miner Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/root/hemi/heminetwork_${LATEST_VERSION}_linux_amd64/popmd
Restart=on-failure
Environment=POPM_BTC_PRIVKEY=$POPM_BTC_PRIVKEY
Environment=POPM_STATIC_FEE=$POPM_STATIC_FEE
Environment=POPM_BFG_URL=wss://testnet.rpc.hemi.network/v1/ws/public

[Install]
WantedBy=multi-user.target
EOL

show "Service file created at $SERVICE_FILE"

# Enable and start the service if it was just created
if ! systemctl list-units --full --quiet --all "$SERVICE_NAME"; then
    sudo systemctl enable hemi-miner.service
    sudo systemctl start hemi-miner.service
    show "Hemi miner service started."
fi

# Display real-time logs
show "Displaying real-time logs. Press Ctrl+C to stop."
journalctl -u hemi-miner.service -f
