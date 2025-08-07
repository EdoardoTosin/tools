#!/bin/bash

################################################################################
# Docker Setup Script for Raspberry Pi
#
# Installation script for Docker and Docker Compose on all Raspberry Pi models
# following official Docker documentation and best practices.
#
# Supports:
# - Raspberry Pi Zero W (armv6l) - uses convenience script   pip docker-compose
# - Raspberry Pi 2/3/4/5 32-bit (armhf) - uses official Raspbian repository
# - Raspberry Pi 3/4/5 64-bit (aarch64) - uses official Debian repository
# - Proper OS detection and architecture-specific installation methods
# - Modern Docker Compose plugin for supported systems
# - Legacy docker-compose for older/32-bit systems where needed
#
# Requirements: Raspberry Pi running Raspberry Pi OS (any variant)
#
# Copyright (c) 2024-25 Edoardo Tosin
#
# This file is licensed under the terms of the MIT License.
# This program is licensed "as is" without any warranty of any kind, whether
# express or implied.
#
################################################################################

set -e # Exit on any error

# Color codes for output
RED='33[0;31m'
GREEN='33[0;32m'
YELLOW='33[1;33m'
BLUE='33[0;34m'
NC='33[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Use sudo if not already root
if [ "$EUID" -ne 0 ]; then
  SUDO='sudo'
else
  SUDO=''
fi

# System information detection
detect_system_info() {
  log_info "Detecting system information..."

  # Architecture detection
  ARCH=$(uname -m)
  case "$ARCH" in
  "armv6l")
    DETECTED_ARCH="armv6"
    ;;
  "armv7l")
    DETECTED_ARCH="armv7"
    ;;
  "aarch64")
    DETECTED_ARCH="aarch64"
    ;;
  *)
    log_error "Unsupported architecture: $ARCH"
    exit 1
    ;;
  esac

  # OS Detection
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION_ID="$VERSION_ID"
    OS_VERSION_CODENAME="$VERSION_CODENAME"
  else
    log_error "Cannot detect OS version"
    exit 1
  fi

  # Determine if this is 32-bit or 64-bit Raspberry Pi OS
  if [ "$OS_ID" = "raspbian" ] || ([ "$OS_ID" = "debian" ] && [ -f /usr/bin/raspi-config ]); then
    if [ "$ARCH" = "aarch64" ]; then
      RASPI_OS_TYPE="64-bit"
      DOCKER_REPO_TYPE="debian" # 64-bit Pi OS uses Debian repos
    else
      RASPI_OS_TYPE="32-bit"
      DOCKER_REPO_TYPE="raspbian" # 32-bit Pi OS uses Raspbian repos
    fi
    IS_RASPBERRY_PI_OS=true
  else
    log_error "This script is designed for Raspberry Pi OS only"
    exit 1
  fi

  log_success "System detected:"
  echo "  Architecture: $DETECTED_ARCH"
  echo "  OS: $OS_ID $OS_VERSION_CODENAME ($RASPI_OS_TYPE)"
  echo "  Docker repo type: $DOCKER_REPO_TYPE"
}

# Update system packages
update_system() {
  log_info "Updating system packages..."
  $SUDO apt-get update -qq
  $SUDO apt-get upgrade -y -qq
  log_success "System updated successfully"
}

# Install prerequisites
install_prerequisites() {
  log_info "Installing prerequisites..."
  $SUDO apt-get install -y ca-certificates curl

  # Additional packages for pip-based installations if needed
  if [ "$DETECTED_ARCH" = "armv6" ]; then
    $SUDO apt-get install -y python3-pip libffi-dev
  fi
  log_success "Prerequisites installed"
}

# Remove conflicting packages
remove_conflicting_packages() {
  log_info "Removing conflicting Docker packages..."
  for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    $SUDO apt-get remove -y "$pkg" 2>/dev/null || true
  done
  log_success "Conflicting packages removed"
}

# Install Docker using official repository (for 64-bit Pi OS and 32-bit Pi OS)
install_docker_official_repo() {
  log_info "Installing Docker using official repository method..."

  # Create keyrings directory
  $SUDO install -m 0755 -d /etc/apt/keyrings

  # Download Docker GPG key based on repository type
  if [ "$DOCKER_REPO_TYPE" = "debian" ]; then
    # For 64-bit Raspberry Pi OS (uses Debian repos)
    $SUDO curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    REPO_URL="https://download.docker.com/linux/debian"
  else
    # For 32-bit Raspberry Pi OS (uses Raspbian repos)
    $SUDO curl -fsSL https://download.docker.com/linux/raspbian/gpg -o /etc/apt/keyrings/docker.asc
    REPO_URL="https://download.docker.com/linux/raspbian"
  fi

  $SUDO chmod a r /etc/apt/keyrings/docker.asc

  # Add repository
  echo
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] $REPO_URL 
        $OS_VERSION_CODENAME stable" |
    $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

  # Update package index
  $SUDO apt-get update -qq

  # Install Docker packages
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  log_success "Docker installed using official repository"
}

# Install Docker using convenience script (for armv6 only)
install_docker_convenience_script() {
  log_info "Installing Docker using convenience script..."
  curl -fsSL https://get.docker.com | sh
  log_success "Docker installed using convenience script"
}

# Main Docker installation logic
install_docker() {
  case "$DETECTED_ARCH" in
  "armv6")
    # Pi Zero W - use convenience script as it's most reliable
    install_docker_convenience_script
    ;;
  "armv7" | "aarch64")
    # Pi 2/3/4/5 - use official repository
    install_docker_official_repo
    ;;
  esac

  # Post-installation steps
  log_info "Configuring Docker..."

  # Add user to docker group
  $SUDO usermod -aG docker "$USER"

  # Enable and start Docker service
  $SUDO systemctl enable docker
  $SUDO systemctl start docker

  log_success "Docker installation completed"
}

# Install Docker Compose
install_docker_compose() {
  log_info "Setting up Docker Compose..."

  case "$DETECTED_ARCH" in
  "armv6")
    # Pi Zero W - install via pip (v1.29.2 for armv6 compatibility)
    log_info "Installing Docker Compose v1.29.2 via pip for armv6..."
    $SUDO pip3 install docker-compose==1.29.2
    COMPOSE_COMMAND="docker-compose"
    ;;
  "armv7")
    # 32-bit Pi 2/3/4 - Docker Compose plugin should be installed, but verify
    if command -v docker-compose >/dev/null 2>&1; then
      COMPOSE_COMMAND="docker-compose"
      log_success "Docker Compose standalone found"
    else
      COMPOSE_COMMAND="docker compose"
      log_success "Docker Compose plugin installed"
    fi
    ;;
  "aarch64")
    # 64-bit Pi 3/4/5 - use plugin (installed with docker-compose-plugin)
    COMPOSE_COMMAND="docker compose"
    log_success "Docker Compose plugin installed"
    ;;
  esac

  log_success "Docker Compose setup completed"
}

# Verify installation
verify_installation() {
  log_info "Verifying Docker installation..."

  # Check Docker version
  if docker --version >/dev/null 2>&1; then
    DOCKER_VERSION=$(docker --version)
    log_success "Docker installed: $DOCKER_VERSION"
  else
    log_error "Docker installation verification failed"
    exit 1
  fi

  # Check Docker Compose
  if [ "$DETECTED_ARCH" = "armv6" ] || ([ "$DETECTED_ARCH" = "armv7" ] && command -v docker-compose >/dev/null 2>&1); then
    if docker-compose --version >/dev/null 2>&1; then
      COMPOSE_VERSION=$(docker-compose --version)
      log_success "Docker Compose installed: $COMPOSE_VERSION"
    else
      log_warning "Docker Compose verification failed"
    fi
  else
    if docker compose version >/dev/null 2>&1; then
      COMPOSE_VERSION=$(docker compose version)
      log_success "Docker Compose plugin installed: $COMPOSE_VERSION"
    else
      log_warning "Docker Compose plugin verification failed"
    fi
  fi

  # Test Docker with hello-world
  log_info "Testing Docker with hello-world container..."
  if $SUDO docker run --rm hello-world >/dev/null 2>&1; then
    log_success "Docker hello-world test passed!"
  else
    log_warning "Docker hello-world test failed - check Docker installation"
  fi
}

# Display final instructions
show_final_instructions() {
  echo ""
  echo "========================================="
  log_success "Docker installation completed successfully!"
  echo "========================================="
  echo ""

  log_info "System Information:"
  echo "  • Raspberry Pi architecture: $DETECTED_ARCH"
  echo "  • OS type: $RASPI_OS_TYPE Raspberry Pi OS"
  echo "  • Docker repository: $DOCKER_REPO_TYPE"
  echo ""

  log_info "Usage Instructions:"
  case "$DETECTED_ARCH" in
  "armv6")
    echo "  • Docker commands: docker <command>"
    echo "  • Docker Compose: docker-compose <command> (legacy syntax)"
    echo "  • Example: docker-compose up -d"
    ;;
  "armv7")
    echo "  • Docker commands: docker <command>"
    if command -v docker-compose >/dev/null 2>&1; then
      echo "  • Docker Compose: docker-compose <command> (legacy syntax)"
      echo "  • Example: docker-compose up -d"
    else
      echo "  • Docker Compose: docker compose <command> (modern syntax)"
      echo "  • Example: docker compose up -d"
    fi
    ;;
  "aarch64")
    echo "  • Docker commands: docker <command>"
    echo "  • Docker Compose: docker compose <command> (modern syntax)"
    echo "  • Example: docker compose up -d"
    ;;
  esac

  echo ""
  log_warning "IMPORTANT: You must log out and log back in (or reboot) for docker group changes to take effect!"
  echo ""
  log_info "After logging back in, test Docker without sudo:"
  echo "  docker run hello-world"
  echo ""
  log_info "Useful commands:"
  echo "  • Check Docker status: systemctl status docker"
  echo "  • View Docker info: docker info"
  echo "  • List running containers: docker ps"
  echo "  • View available images: docker images"
  echo ""
  log_success "Happy containerizing! 🐳"
}

# Main execution
main() {
  echo "========================================="
  echo "   Docker Setup for Raspberry Pi"
  echo "========================================="
  echo ""

  detect_system_info
  echo ""

  update_system
  install_prerequisites
  remove_conflicting_packages
  install_docker
  install_docker_compose
  verify_installation
  show_final_instructions
}

# Run main function
main "$@"
