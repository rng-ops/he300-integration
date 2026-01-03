#!/bin/bash
# Install NVIDIA drivers and container toolkit on Ubuntu
set -euo pipefail

echo "=== Installing NVIDIA Drivers ==="

# Check if running on a GPU instance
if ! lspci | grep -i nvidia > /dev/null; then
    echo "No NVIDIA GPU detected. Skipping driver installation."
    exit 0
fi

# Add NVIDIA driver repository
sudo apt-get update
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:graphics-drivers/ppa
sudo apt-get update

# Install NVIDIA driver
DRIVER_VERSION="535"
sudo apt-get install -y "nvidia-driver-${DRIVER_VERSION}" "nvidia-utils-${DRIVER_VERSION}"

echo "=== Installing NVIDIA Container Toolkit ==="

# Add NVIDIA container toolkit repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# Configure Docker to use NVIDIA runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Verify installation
echo "=== Verifying NVIDIA Installation ==="
nvidia-smi || echo "nvidia-smi will work after reboot"

# Test Docker GPU access
sudo docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi || echo "GPU Docker test will work after reboot"

echo "=== NVIDIA installation complete ==="
echo "Note: A reboot may be required for drivers to fully load"
