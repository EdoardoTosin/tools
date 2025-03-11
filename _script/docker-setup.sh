#!/bin/bash

################################################################################
# Docker Setup Script for Raspberry Pi
#
# Script to install Docker and Docker Compose on Raspberry Pi Zero W
# and Raspberry Pi Zero 2 W.
#
# Note: The script must run with root permissions.
#
# Copyright (c) 2024 Edoardo Tosin
#
# This file is licensed under the terms of the MIT License.
# This program is licensed "as is" without any warranty of any kind, whether
# express or implied.
#
################################################################################

set -e

# Use sudo if not already root.
if [ "$EUID" -ne 0 ]; then
    SUDO='sudo'
else
    SUDO=''
fi

# Detect the architecture and differentiate armv6 from armv7.
detect_architecture() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        "armv6l")
            echo "armv6"
            ;;
        "armv7l")
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

# Update package lists and install prerequisites.
update_and_install_prerequisites() {
    echo "Updating and upgrading packages..."
    $SUDO apt-get update
    $SUDO apt-get upgrade -y

    echo "Installing prerequisites..."
    $SUDO apt-get install -y apt-transport-https ca-certificates curl software-properties-common python3-pip
}

# Install Docker using the official convenience script.
install_docker() {
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh

    # Add the current user to the docker group so that docker can be run without sudo.
    $SUDO usermod -aG docker "$USER"
    $SUDO systemctl enable docker
    $SUDO systemctl start docker
    echo "Docker installed successfully."

    # Attempt to refresh group membership for this session.
    # Note: This may not work in all shells; logging out and back in is recommended.
    newgrp docker <<EOF
echo "Docker group refreshed for current session."
EOF
}

# Install Docker Compose.
install_docker_compose() {
    local arch
    arch=$(detect_architecture)
    
    if [ "$arch" = "armv6" ]; then
        echo "Installing Docker Compose via pip for armv6..."
        # For older Raspberry Pi (armv6), use pip installation.
        $SUDO pip3 install docker-compose
        if ! docker-compose --version >/dev/null 2>&1; then
            echo "Docker Compose installation via pip failed."
            exit 1
        fi
    else
        echo "Installing Docker Compose..."
        local version
        version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
        echo "Latest Docker Compose version is $version"
        
        local compose_url=""
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
        $SUDO curl -L "$compose_url" -o "$compose_bin"

        if [ ! -s "$compose_bin" ]; then
            echo "Failed to download Docker Compose: file is empty."
            exit 1
        fi

        if ! $SUDO file "$compose_bin" | grep -q "executable"; then
            echo "Downloaded file is not a valid Docker Compose binary."
            exit 1
        fi

        $SUDO chmod +x "$compose_bin"
        if ! docker-compose --version >/dev/null 2>&1; then
            echo "Docker Compose installation failed."
            exit 1
        fi
    fi
    echo "Docker Compose installed successfully."
}

main() {
    update_and_install_prerequisites
    install_docker
    install_docker_compose
    echo "Docker and Docker Compose have been installed successfully."
    echo "Note: You may need to log out and log back in for docker group changes to take effect."
}

main
