#!/bin/bash

################################################################################
# Docker Setup Script for Raspberry Pi
#
# Script to install Docker and Docker Compose on Raspberry Pi Zero W
# and Raspberry Pi Zero 2 W.
#
# Copyright (c) 2024 Edoardo Tosin
#
# This file is licensed under the terms of the MIT License.
# This program is licensed "as is" without any warranty of any kind, whether
# express or implied.
#
################################################################################

set -e  # Exit immediately if a command exits with a non-zero status.

# Function to detect the architecture
detect_architecture() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        "armv6l"|"armv7l")
            echo "armv7"
            ;;
        "aarch64")
            echo "aarch64"
            ;;
        *)
            echo "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

# Function to install Docker
install_docker() {
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    sudo systemctl enable docker
    sudo systemctl start docker
    echo "Docker installed successfully."
}

# Function to install Docker Compose
install_docker_compose() {
    echo "Installing Docker Compose..."
    local version
    version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
    echo "Latest Docker Compose version is $version"
    
    local arch
    arch=$(detect_architecture)
    local compose_url
    
    # Construct the URL based on detected architecture
    case "$arch" in
        "armv7")
            compose_url="https://github.com/docker/compose/releases/download/${version}/docker-compose-$(uname -s)-armv7"
            ;;
        "aarch64")
            compose_url="https://github.com/docker/compose/releases/download/${version}/docker-compose-$(uname -s)-aarch64"
            ;;
        *)
            echo "Unsupported architecture for Docker Compose."
            exit 1
            ;;
    esac
    
    local compose_bin="/usr/local/bin/docker-compose"
    
    echo "Downloading Docker Compose from $compose_url..."
    
    # Download Docker Compose
    sudo curl -L "$compose_url" -o "$compose_bin"
    
    # Check the file size
    if [ ! -s "$compose_bin" ]; then
        echo "Failed to download Docker Compose. The file is empty or download was unsuccessful."
        exit 1
    fi
    
    # Check if the file is a binary
    if ! sudo file "$compose_bin" | grep -q "executable"; then
        echo "Downloaded file is not a valid Docker Compose binary."
        exit 1
    fi
    
    sudo chmod +x "$compose_bin"
    
    # Verify installation
    if ! docker-compose --version; then
        echo "Docker Compose installation failed"
        exit 1
    fi
    echo "Docker Compose installed successfully."
}

# Function to update and install prerequisites
update_and_install_prerequisites() {
    echo "Updating and upgrading existing packages..."
    sudo apt-get update
    sudo apt-get upgrade -y

    echo "Installing prerequisites..."
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
}

# Main script execution
update_and_install_prerequisites
install_docker
install_docker_compose

echo "Docker and Docker Compose have been installed successfully."
