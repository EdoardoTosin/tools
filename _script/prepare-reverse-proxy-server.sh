#!/bin/bash

################################################################################
# Raspberry Pi Reverse Proxy Server
#
# Script to automate the setup of an Nginx reverse proxy. The script checks
# for required dependencies, installs necessary packages, configures the Nginx
# reverse proxy with provided domain and IP:Port mappings, and handles backup
# and reload operations. It also supports logging and email notifications.
#
# Copyright (c) 2024 Edoardo Tosin
#
# This file is licensed under the terms of the MIT License.
# This program is licensed "as is" without any warranty of any kind, whether
# express or implied.
#
################################################################################

# Default configurations
VERBOSE=1
LOG_FILE="/var/log/nginx_setup.log"
PROXY_CONF="/etc/nginx/conf.d/reverse-proxy.conf"
EMAIL=""
LOCK_FILE="/var/run/nginx_setup.lock"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Function to print messages
log() {
    local message=$1
    local level=$2
    local func=${FUNCNAME[1]}
    case $level in
        "INFO") echo -e "${GREEN}INFO: [$func] $message${NC}" ;;
        "WARN") echo -e "${YELLOW}WARN: [$func] $message${NC}" ;;
        "ERROR") echo -e "${RED}ERROR: [$func] $message${NC}" ;;
        *) echo "[$func] $message" ;;
    esac
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $level - [$func] - $message" >> $LOG_FILE
}

# Function to check if required tools are available
check_dependencies() {
    for cmd in dpkg sudo apt nginx; do
        if ! command -v $cmd &> /dev/null; then
            log "Command $cmd could not be found. Please install it and retry." "ERROR"
            exit 1
        fi
    done
}

# Function to check if the script is run as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "Please run as root or use sudo." "ERROR"
        exit 1
    fi
}

# Function to check if a package is installed
check_package() {
    dpkg -s $1 &> /dev/null
    if [ $? -ne 0 ]; then
        log "$1 is not installed. Installing..." "INFO"
        sudo apt install -y $1
        if [ $? -ne 0 ]; then
            log "Failed to install $1. Exiting." "ERROR"
            exit 2
        fi
    else
        [ $VERBOSE -eq 1 ] && log "$1 is already installed." "INFO"
    fi
}

# Function to create a backup of a file
backup_file() {
    if [ -f $1 ]; then
        sudo cp $1 $1.backup
        log "Backup of $1 created." "INFO"
    else
        log "File $1 not found, skipping backup." "WARN"
    fi
}

# Function to remove default server block configuration
remove_default_server_block() {
    if [ -f /etc/nginx/sites-enabled/default ]; then
        sudo rm /etc/nginx/sites-enabled/default
        log "Default server block configuration removed." "INFO"
    else
        log "Default server block configuration not found, skipping removal." "WARN"
    fi
}

# Function to create initial reverse proxy configuration
create_initial_proxy_config() {
    local proxy_conf=$1
    sudo bash -c "cat > $proxy_conf <<EOL
server {
    listen 80;
    server_name _;
    return 444;
}
EOL"
    log "Initial reverse proxy configuration created." "INFO"
}

# Function to add or update server blocks for domains
add_server_blocks() {
    local proxy_conf=$1
    shift
    local domains=("$@")

    # Read the existing proxy configuration
    local existing_conf=$(cat "$proxy_conf" 2>/dev/null)

    for entry in "${domains[@]}"; do
        local domain
        local ip_port
        IFS='=' read -r domain ip_port <<< "$entry"
        
        # Trim leading and trailing whitespace
        domain=${domain##*( )}
        domain=${domain%%*( )}
        ip_port=${ip_port##*( )}
        ip_port=${ip_port%%*( )}

        # Check if domain and ip_port are non-empty
        if [ -z "$domain" ] || [ -z "$ip_port" ]; then
            log "Domain or IP:Port is empty for entry '$entry'. Skipping." "ERROR"
            continue
        fi

        # Validate IP:Port format
        if ! [[ $ip_port =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
            log "Invalid IP:Port format for domain '$domain'. Skipping." "ERROR"
            continue
        fi

        # Create the server block configuration
        local new_server_block=$(cat <<EOL

server {
    listen 80;
    server_name $domain;

    location / {
        proxy_pass http://$ip_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

EOL
)

        # Check if the domain already exists in the existing configuration
        if grep -q "server_name $domain;" <<< "$existing_conf"; then
            # Replace the existing server block for the domain
            existing_conf=$(echo "$existing_conf" | sed "/server_name $domain;/, '/}/c\\$new_server_block")
            log "Updated configuration for $domain." "INFO"
        else
            # Append the new server block
            existing_conf+="$new_server_block"
            log "Added configuration for $domain." "INFO"
        fi
    done

    # Write the updated configuration back to the proxy configuration file
    echo "$existing_conf" | sudo tee "$proxy_conf" > /dev/null
}

# Function to test Nginx configuration
test_nginx_config() {
    sudo nginx -t
    if [ $? -ne 0 ]; then
        log "Nginx configuration test failed. Please check the configuration file." "ERROR"
        return 1
    else
        log "Nginx configuration test successful." "INFO"
        return 0
    fi
}

# Function to reload Nginx
reload_nginx() {
    sudo systemctl reload nginx
    if [ $? -ne 0 ]; then
        log "Failed to reload Nginx. Please check the service status." "ERROR"
        return 1
    else
        log "Nginx reloaded successfully." "INFO"
        return 0
    fi
}

# Function to send email notification
send_email() {
    local subject=$1
    local body=$2
    if [ -n "$EMAIL" ]; then
        echo -e "$body" | mail -s "$subject" "$EMAIL"
    fi
}

# Function to display usage instructions
usage() {
    echo "Usage: $0 [-v] [-l LOG_FILE] [-c PROXY_CONF] [-e EMAIL] -d DOMAIN1=IP:PORT -d DOMAIN2=IP:PORT ... -f DOMAIN_FILE"
    echo "  -v                Enable verbose mode"
    echo "  -l LOG_FILE       Specify the log file (default: /var/log/nginx_setup.log)"
    echo "  -c PROXY_CONF     Specify the proxy configuration file (default: /etc/nginx/conf.d/reverse-proxy.conf)"
    echo "  -e EMAIL          Specify email to send notification on success or failure"
    echo "  -d DOMAIN=IP:PORT Specify domain and corresponding IP:Port"
    echo "  -f DOMAIN_FILE    Specify a file containing domain and corresponding IP:Port mappings"
    exit 1
}

# Parse arguments
DOMAINS=()
DOMAIN_FILE=""
while getopts "vl:c:e:d:f:" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        l) LOG_FILE=$OPTARG ;;
        c) PROXY_CONF=$OPTARG ;;
        e) EMAIL=$OPTARG ;;
        d) DOMAINS+=("$OPTARG") ;;
        f) DOMAIN_FILE=$OPTARG ;;
        *) usage ;;
    esac
done

# Load domains from file if specified
if [ -n "$DOMAIN_FILE" ]; then
    if [ ! -f "$DOMAIN_FILE" ]; then
        log "Domain file $DOMAIN_FILE not found. Exiting." "ERROR"
        exit 1
    fi
    while IFS='=' read -r domain ip_port || [ -n "$domain" ]; do
        # Skip lines starting with "#"
        trimmed_domain=$(echo "$domain" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [[ $trimmed_domain =~ ^# ]]; then
            continue
        fi
        DOMAINS+=("$trimmed_domain=$ip_port")
    done < "$DOMAIN_FILE"
fi

# Validate domains
if [ ${#DOMAINS[@]} -eq 0 ]; then
    log "No domains specified. Exiting." "ERROR"
    usage
fi

# Create associative array from domains
declare -A DOMAIN_MAP
for DOMAIN_ENTRY in "${DOMAINS[@]}"; do
    DOMAIN_ENTRY=$(echo "$DOMAIN_ENTRY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')  # Trim leading and trailing whitespace
    IFS='=' read -r DOMAIN IP_PORT <<< "$DOMAIN_ENTRY"
    DOMAIN_MAP["$DOMAIN"]="$IP_PORT"
done

# Check for lock file
if [ -f $LOCK_FILE ]; then
    log "Another instance of the script is running. Exiting." "ERROR"
    exit 1
fi

# Create lock file
touch $LOCK_FILE

# Trap to remove lock file on exit
trap "rm -f $LOCK_FILE" EXIT

# Check dependencies
check_dependencies

# Ensure the script is run as root
check_root

# Main script
log "Updating package list..." "INFO"
sudo apt update
if [ $? -ne 0 ]; then
    log "Failed to update package list. Exiting." "ERROR"
    send_email "Nginx Setup Failed" "Failed to update package list."
    exit 1
fi

# Check and install Nginx
check_package nginx

# Backup the original Nginx configuration file
backup_file /etc/nginx/nginx.conf

# Clear the default server block configuration
remove_default_server_block

# Create a new configuration file for the reverse proxy if it doesn't exist
if [ ! -f $PROXY_CONF ]; then
    create_initial_proxy_config $PROXY_CONF
fi

# Add or update server blocks for each domain
add_server_blocks $PROXY_CONF "${DOMAINS[@]}"

# Test Nginx configuration
test_nginx_config
TEST_RESULT=$?

# Reload Nginx to apply changes
if [ $TEST_RESULT -eq 0 ]; then
    reload_nginx
    RELOAD_RESULT=$?
else
    RELOAD_RESULT=1
fi

if [ $RELOAD_RESULT -eq 0 ]; then
    log "Reverse proxy configuration is complete." "INFO"
    send_email "Nginx Setup Successful" "The reverse proxy configuration has been successfully applied."
else
    log "Failed to apply reverse proxy configuration." "ERROR"
    send_email "Nginx Setup Failed" "Failed to apply the reverse proxy configuration."
    exit 1
fi
