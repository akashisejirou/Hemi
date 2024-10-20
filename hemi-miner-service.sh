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

# Detect the architecture before creating the Dockerfile
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

# Ask user for POPM_BTC_PRIVKEY and POPM_STATIC_FEE
read -p "Do you want to use an existing wallet or generate a new one? (existing/new): " wallet_choice

if [ "$wallet_choice" == "existing" ]; then
    read -p "Enter your POPM_BTC_PRIVKEY: " POPM_BTC_PRIVKEY
else
    echo "Generating a new wallet..."
    ./keygen -secp256k1 -json -net="testnet" > ~/popm-address.json
    show "New wallet generated. Wallet info:"
    cat ~/popm-address.json
    POPM_BTC_PRIVKEY=$(jq -r '.privkey' ~/popm-address.json)
fi

read -p "Enter your POPM_STATIC_FEE: " POPM_STATIC_FEE

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

# Enable and start the service
sudo systemctl enable hemi-miner.service
sudo systemctl start hemi-miner.service
show "Hemi miner service started."

# Display real-time logs
show "Displaying real-time logs. Press Ctrl+C to stop."
journalctl -u hemi-miner.service -f
