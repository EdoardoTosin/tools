#!/bin/bash

################################################################################
# Shiori Setup Script for Raspberry Pi
#
# Script to install Shiori docker container on a Raspberry Pi.
#
# Copyright (c) 2024 Edoardo Tosin
#
# This file is licensed under the terms of the MIT License.
# This program is licensed "as is" without any warranty of any kind, whether
# express or implied.
#
################################################################################

# Exit immediately if a command exits with a non-zero status
set -e
# Exit if a pipeline fails
set -o pipefail

# Default Variables
readonly SHIORI_IMAGE="${SHIORI_IMAGE:-ghcr.io/go-shiori/shiori:latest}"  # Official Shiori Docker image
readonly LOGFILE="${LOGFILE:-/var/log/shiori-setup.log}"
readonly COMPOSE_FILE="${COMPOSE_FILE:-/home/pi/docker-compose.yml}"
readonly SYSTEMD_SERVICE_FILE="${SYSTEMD_SERVICE_FILE:-/etc/systemd/system/docker-compose-shiori.service}"
readonly TEMP_COMPOSE_FILE="${TEMP_COMPOSE_FILE:-/tmp/docker-compose.yml}"
readonly DEBUG="${DEBUG:-false}"  # Set to true to enable debug mode

# Function to log messages
log() {
    local message="$1"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $message" >> "$LOGFILE"
    if [ "$DEBUG" = true ]; then
        echo "$message"
    fi
}

# Function to handle errors
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Function to handle script exit
cleanup() {
    log "Cleaning up temporary files."
    [ -f "$TEMP_COMPOSE_FILE" ] && rm "$TEMP_COMPOSE_FILE"
}
trap cleanup EXIT

# Function to check command existence
check_command() {
    local cmd="$1"
    command -v $cmd &> /dev/null || error_exit "$cmd not found. Ensure it is installed."
}

# Function to validate file paths
validate_file_path() {
    local file_path="$1"
    if [ -z "$file_path" ] || [ ! -d "$(dirname "$file_path")" ]; then
        error_exit "Invalid path: $file_path. Ensure the directory exists."
    fi
}

# Function to check and create directories
check_and_create_dir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        log "Directory $dir does not exist. Creating it."
        sudo mkdir -p "$dir" || error_exit "Failed to create directory $dir."
        sudo chmod 755 "$dir"
    fi
}

# Function to check Docker Compose binary path
check_docker_compose_path() {
    local docker_compose_path
    docker_compose_path=$(command -v docker-compose)
    if [ -z "$docker_compose_path" ]; then
        error_exit "docker-compose not found. Ensure Docker Compose is installed."
    fi
    echo "$docker_compose_path"
}

# Function to pull Docker image
pull_docker_image() {
    log "Pulling Docker image: ${SHIORI_IMAGE}"
    docker pull ${SHIORI_IMAGE} || error_exit "Failed to pull Docker image: ${SHIORI_IMAGE}"
}

# Function to create or update Docker Compose file
create_or_update_docker_compose_file() {
    log "Creating or updating docker-compose.yml file."
    cat <<EOF > $TEMP_COMPOSE_FILE
services:
  shiori:
    image: ${SHIORI_IMAGE}
    container_name: shiori
    ports:
      - "8080:8080"
    volumes:
      - shiori_data:/data
    restart: always
    environment:
      - PORT=8080
      - DATABASE_TYPE=sqlite
      - DATABASE_URL=/data/shiori.db

volumes:
  shiori_data:
EOF
    log "Moving temporary docker-compose.yml file to $COMPOSE_FILE."
    if [ -f "$COMPOSE_FILE" ]; then
        log "Backing up existing $COMPOSE_FILE to ${COMPOSE_FILE}.bak"
        sudo cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak" || error_exit "Failed to back up existing docker-compose.yml."
    fi
    sudo mv $TEMP_COMPOSE_FILE $COMPOSE_FILE || error_exit "Failed to move docker-compose.yml file."
    sudo chmod 644 "$COMPOSE_FILE"
}

# Function to restart Docker Compose
restart_docker_compose() {
    log "Restarting Shiori container..."
    docker-compose -f $COMPOSE_FILE down || error_exit "Failed to stop Shiori container."
    docker-compose -f $COMPOSE_FILE up -d || error_exit "Failed to start Shiori container."
}

# Function to create systemd service
create_systemd_service() {
    log "Creating systemd service file at $SYSTEMD_SERVICE_FILE."
    local docker_compose_path
    docker_compose_path=$(check_docker_compose_path)
    cat <<EOF | sudo tee $SYSTEMD_SERVICE_FILE
[Unit]
Description=Docker Compose Shiori service
After=network.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=$docker_compose_path -f $COMPOSE_FILE up -d
ExecStop=$docker_compose_path -f $COMPOSE_FILE down

[Install]
WantedBy=multi-user.target
EOF
    [ $? -eq 0 ] || error_exit "Failed to create systemd service file."
    sudo chmod 644 "$SYSTEMD_SERVICE_FILE"
}

# Function to reload systemd and enable service
reload_systemd() {
    log "Reloading systemd and enabling service."
    sudo systemctl daemon-reload || error_exit "Failed to reload systemd daemon."
    sudo systemctl enable docker-compose-shiori || error_exit "Failed to enable docker-compose-shiori service."
}

# Function to validate Docker Compose setup
validate_docker_compose() {
    log "Validating Docker Compose setup."
    docker-compose -f $COMPOSE_FILE ps || error_exit "Docker Compose setup validation failed. Please check the configuration."
}

# Function to handle log rotation
rotate_logs() {
    local max_size=10485760  # 10 MB
    if [ -f "$LOGFILE" ]; then
        local file_size
        file_size=$(stat -c%s "$LOGFILE")
        if [ "$file_size" -ge "$max_size" ]; then
            log "Log file $LOGFILE size exceeds $max_size bytes. Rotating logs."
            mv "$LOGFILE" "${LOGFILE}.1"
            gzip "${LOGFILE}.1" || error_exit "Failed to compress rotated log file."
        fi
    fi
}

# Function to check if the script is running with sufficient privileges
check_privileges() {
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "This script must be run as root. Please use sudo."
    fi
}

# Function to show help
show_help() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help                Show this help message."
    echo "  -d, --debug               Enable debug mode."
    echo "  -i, --image IMAGE         Set the Docker image for Shiori."
    echo "  -c, --compose-file FILE   Set the path for Docker Compose file."
    echo "  -s, --systemd-service FILE Set the path for systemd service file."
    exit 0
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -d|--debug)
            DEBUG=true
            shift
            ;;
        -i|--image)
            SHIORI_IMAGE="$2"
            shift 2
            ;;
        -c|--compose-file)
            COMPOSE_FILE="$2"
            validate_file_path "$COMPOSE_FILE"
            shift 2
            ;;
        -s|--systemd-service)
            SYSTEMD_SERVICE_FILE="$2"
            validate_file_path "$SYSTEMD_SERVICE_FILE"
            shift 2
            ;;
        *)
            error_exit "Unknown option $1. Use -h or --help for usage information."
            ;;
    esac
done

# Main script execution
main() {
    log "Starting Shiori setup script."

    # Check for script privileges
    check_privileges

    # Rotate logs to prevent file from growing too large
    rotate_logs

    # Check for required commands and dependencies
    check_command docker
    check_command docker-compose

    # Check and create necessary directories
    check_and_create_dir "$(dirname "$COMPOSE_FILE")"
    check_and_create_dir "$(dirname "$SYSTEMD_SERVICE_FILE")"

    # Pull Docker image
    pull_docker_image

    # Create or update Docker Compose file
    create_or_update_docker_compose_file

    # Restart Docker Compose
    restart_docker_compose

    # Create and enable systemd service
    create_systemd_service
    reload_systemd

    # Validate Docker Compose setup
    validate_docker_compose

    log "Setup complete. Docker Compose service will start on boot."
}

# Execute the main function
main
