#!/bin/bash

# Ubuntu Proxy Server Setup Script
# This script installs and configures either an HTTP proxy (Squid) or SOCKS5 proxy (Shadowsocks) on Ubuntu

# Exit on error
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Ubuntu Proxy Server Setup${NC}"
echo "This script will install and configure an HTTP or SOCKS5 proxy server"
echo "-----------------------------------------------------------"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

# Update system
echo -e "${GREEN}Updating system packages...${NC}"
apt update -y

# Install curl if not already installed (needed for getting public IP)
apt install -y curl

# Get public IP
echo -e "${GREEN}Detecting public IP address...${NC}"
PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || curl -s https://icanhazip.com)

if [ -z "$PUBLIC_IP" ]; then
  echo -e "${RED}Failed to detect public IP address. Using local IP instead.${NC}"
  PUBLIC_IP=$(hostname -I | awk '{print $1}')
  echo -e "${YELLOW}Using local IP: $PUBLIC_IP${NC}"
else
  echo -e "${GREEN}Detected public IP: $PUBLIC_IP${NC}"
fi

# Function to check if port is in use
check_port() {
  local port=$1
  if netstat -tuln | grep -q ":$port "; then
    echo -e "${RED}Port $port is already in use. Please choose another port.${NC}"
    return 1
  fi
  return 0
}

# Choose proxy type
echo -e "${YELLOW}Choose proxy type:${NC}"
echo "1) HTTP proxy (Squid)"
echo "2) SOCKS5 proxy (Shadowsocks)"
read -p "Enter your choice [1-2]: " PROXY_TYPE

case $PROXY_TYPE in
  2)
    # Install and configure SOCKS5 proxy using Shadowsocks
    echo -e "${GREEN}Installing SOCKS5 proxy server (Shadowsocks)...${NC}"
    
    # Install dependencies
    apt install -y python3-pip python3-setuptools
    
    # Install Shadowsocks
    echo -e "${GREEN}Installing Shadowsocks...${NC}"
    pip3 install shadowsocks
    
    # Set proxy port
    while true; do
      read -p "Enter port for SOCKS5 proxy server [8388]: " PROXY_PORT
      PROXY_PORT=${PROXY_PORT:-8388}
      if check_port $PROXY_PORT; then
        break
      fi
    done
    
    # Set password
    read -s -p "Enter password for Shadowsocks (required): " SS_PASS
    echo
    
    # Verify password is not empty
    while [ -z "$SS_PASS" ]; do
      echo -e "${RED}Password cannot be empty.${NC}"
      read -s -p "Enter password for Shadowsocks (required): " SS_PASS
      echo
    done
    
    # Create configuration directory
    mkdir -p /etc/shadowsocks
    
    # Create config file
    cat > /etc/shadowsocks/config.json << EOF
{
  "server": "0.0.0.0",
  "server_port": $PROXY_PORT,
  "password": "$SS_PASS",
  "timeout": 300,
  "method": "aes-256-cfb",
  "fast_open": false
}
EOF
    
    # Fix the issue with the Crypto library (common in newer Python versions)
    if ! pip3 show pycryptodome > /dev/null 2>&1; then
      echo -e "${GREEN}Installing PyCryptodome...${NC}"
      pip3 install pycryptodome
    fi
    
    # Fix the issue with the openssl module if necessary
    if grep -q "from OpenSSL import rand" /usr/local/lib/python*/dist-packages/shadowsocks/crypto/openssl.py 2>/dev/null; then
      echo -e "${GREEN}Patching Shadowsocks for compatibility...${NC}"
      sed -i 's/from OpenSSL import rand/from os import urandom as rand/g' /usr/local/lib/python*/dist-packages/shadowsocks/crypto/openssl.py
    fi
    
    # Create systemd service file
    cat > /etc/systemd/system/shadowsocks.service << EOF
[Unit]
Description=Shadowsocks Proxy Server
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd, enable and start service
    systemctl daemon-reload
    systemctl enable shadowsocks
    
    # Start service with error handling
    if ! systemctl start shadowsocks; then
      echo -e "${RED}Failed to start Shadowsocks service. Trying alternative method...${NC}"
      # Try running ssserver directly to see error output
      echo -e "${YELLOW}Running Shadowsocks server directly to check for errors:${NC}"
      echo "--------------------------------"
      ssserver -c /etc/shadowsocks/config.json -d start
      echo "--------------------------------"
      
      # Check if it's running
      sleep 2
      if pgrep -f ssserver > /dev/null; then
        echo -e "${GREEN}Shadowsocks is now running using the direct method.${NC}"
      else
        echo -e "${RED}Failed to start Shadowsocks. Please check the error output above.${NC}"
        exit 1
      fi
    fi
    
    # Configure firewall
    echo -e "${GREEN}Configuring firewall...${NC}"
    apt install -y ufw
    ufw allow ssh
    ufw allow $PROXY_PORT/tcp
    ufw allow $PROXY_PORT/udp
    ufw --force enable
    
    # Display proxy information
    echo -e "${YELLOW}SOCKS5 Proxy Server Information:${NC}"
    echo "Public IP: $PUBLIC_IP"
    echo "Port: $PROXY_PORT"
    echo "Password: $SS_PASS"
    echo "Encryption: aes-256-cfb"
    
    echo -e "${YELLOW}To use this Shadowsocks proxy:${NC}"
    echo "Server: $PUBLIC_IP"
    echo "Port: $PROXY_PORT"
    echo "Password: $SS_PASS"
    echo "Encryption: aes-256-cfb"
    
    echo -e "${YELLOW}You can connect using any Shadowsocks client:${NC}"
    echo "- Windows/macOS/Linux: Shadowsocks client"
    echo "- Android: Shadowsocks for Android"
    echo "- iOS: Shadowrocket"
    ;;
    
  *)
    # Default to HTTP proxy (Squid)
    echo -e "${GREEN}Installing HTTP proxy server (Squid)...${NC}"
    apt install -y squid apache2-utils
    
    # Determine squid configuration directory
    if [ -d /etc/squid ]; then
      SQUID_CONFIG_DIR="/etc/squid"
    else
      SQUID_CONFIG_DIR="/etc/squid3"
      # If neither exists, install squid and check again
      if [ ! -d "$SQUID_CONFIG_DIR" ]; then
        apt install -y squid
        SQUID_CONFIG_DIR="/etc/squid"
      fi
    fi
    
    # Backup original configuration
    echo -e "${GREEN}Backing up original Squid configuration...${NC}"
    if [ -f "$SQUID_CONFIG_DIR/squid.conf" ]; then
      cp "$SQUID_CONFIG_DIR/squid.conf" "$SQUID_CONFIG_DIR/squid.conf.bak"
    fi
    
    # Set proxy port (default: 3128)
    while true; do
      read -p "Enter port for HTTP proxy server [3128]: " PROXY_PORT
      PROXY_PORT=${PROXY_PORT:-3128}
      if check_port $PROXY_PORT; then
        break
      fi
    done
    
    # Ask if authentication is needed
    read -p "Do you want to set up authentication? (y/n): " AUTH_NEEDED
    
    if [[ "$AUTH_NEEDED" =~ ^[Yy]$ ]]; then
      # Create authentication file
      echo -e "${GREEN}Setting up authentication...${NC}"
      read -p "Enter username for proxy: " PROXY_USER
      
      # Create password file
      touch "$SQUID_CONFIG_DIR/passwd"
      htpasswd -bc "$SQUID_CONFIG_DIR/passwd" "$PROXY_USER" $(read -s -p "Enter password: " PASS && echo $PASS)
      chown proxy:proxy "$SQUID_CONFIG_DIR/passwd" 2>/dev/null || true
      
      # Determine the path to basic_ncsa_auth
      BASIC_AUTH_PATH=""
      for path in "/usr/lib/squid/basic_ncsa_auth" "/usr/lib/squid3/basic_ncsa_auth" "/usr/libexec/squid/basic_ncsa_auth"; do
        if [ -f "$path" ]; then
          BASIC_AUTH_PATH="$path"
          break
        fi
      done
      
      if [ -z "$BASIC_AUTH_PATH" ]; then
        echo -e "${RED}Could not find basic_ncsa_auth. Authentication might not work properly.${NC}"
        # Find the path dynamically
        BASIC_AUTH_PATH=$(find /usr -name basic_ncsa_auth 2>/dev/null | head -n 1)
        if [ -z "$BASIC_AUTH_PATH" ]; then
          echo -e "${RED}Still could not find basic_ncsa_auth. Using default path.${NC}"
          BASIC_AUTH_PATH="/usr/lib/squid/basic_ncsa_auth"
        else
          echo -e "${GREEN}Found basic_ncsa_auth at $BASIC_AUTH_PATH${NC}"
        fi
      fi
      
      # Create new Squid configuration with authentication
      cat > "$SQUID_CONFIG_DIR/squid.conf" << EOF
# Squid configuration with basic authentication

# Define ACL for localhost
acl localhost src 127.0.0.1/32 ::1
acl to_localhost dst 127.0.0.0/8 0.0.0.0/32 ::1

# Port configuration
http_port $PROXY_PORT

# Authentication settings
auth_param basic program $BASIC_AUTH_PATH $SQUID_CONFIG_DIR/passwd
auth_param basic realm Proxy Authentication Required
auth_param basic credentialsttl 2 hours
acl authenticated_users proxy_auth REQUIRED

# Access control
http_access allow authenticated_users
http_access allow localhost
http_access deny all

# DNS settings for better privacy
dns_nameservers 8.8.8.8 8.8.4.4

# Basic performance settings
cache_mem 256 MB
maximum_object_size 100 MB
EOF
    
    else
      # Create new Squid configuration without authentication
      cat > "$SQUID_CONFIG_DIR/squid.conf" << EOF
# Squid configuration without authentication

# Define ACL for localhost
acl localhost src 127.0.0.1/32 ::1
acl to_localhost dst 127.0.0.0/8 0.0.0.0/32 ::1

# Port configuration
http_port $PROXY_PORT

# Access control
http_access allow all

# DNS settings for better privacy
dns_nameservers 8.8.8.8 8.8.4.4

# Basic performance settings
cache_mem 256 MB
maximum_object_size 100 MB
EOF
    
    fi
    
    # Configure firewall
    echo -e "${GREEN}Configuring firewall...${NC}"
    apt install -y ufw
    ufw allow ssh
    ufw allow $PROXY_PORT/tcp
    ufw --force enable
    
    # Determine squid service name
    if systemctl list-units --type=service | grep -q "squid.service"; then
      SQUID_SERVICE="squid"
    elif systemctl list-units --type=service | grep -q "squid3.service"; then
      SQUID_SERVICE="squid3"
    else
      # Try to install squid if service not found
      apt install -y squid
      SQUID_SERVICE="squid"
    fi
    
    # Restart Squid service
    echo -e "${GREEN}Restarting Squid service...${NC}"
    if ! systemctl restart $SQUID_SERVICE; then
      echo -e "${RED}Failed to restart Squid service. Checking configuration...${NC}"
      if [ -x /usr/sbin/squid ]; then
        /usr/sbin/squid -k parse
      elif [ -x /usr/sbin/squid3 ]; then
        /usr/sbin/squid3 -k parse
      fi
      echo -e "${RED}Please fix the configuration issues and restart Squid manually.${NC}"
      exit 1
    fi
    
    systemctl enable $SQUID_SERVICE
    
    # Verify service is running
    if systemctl is-active --quiet $SQUID_SERVICE; then
      echo -e "${GREEN}HTTP proxy server is now running!${NC}"
    else
      echo -e "${RED}Failed to start HTTP proxy server. Check logs with: journalctl -u $SQUID_SERVICE${NC}"
      exit 1
    fi
    
    # Display proxy information
    echo -e "${YELLOW}HTTP Proxy Server Information:${NC}"
    echo "Public IP: $PUBLIC_IP"
    echo "Port: $PROXY_PORT"
    if [[ "$AUTH_NEEDED" =~ ^[Yy]$ ]]; then
      echo "Username: $PROXY_USER"
      echo "Authentication: Enabled"
    else
      echo "Authentication: Disabled"
    fi
    
    echo -e "${YELLOW}To use this proxy:${NC}"
    echo "HTTP Proxy: $PUBLIC_IP:$PROXY_PORT"
    if [[ "$AUTH_NEEDED" =~ ^[Yy]$ ]]; then
      echo "Credentials required: Yes (username and password)"
    fi
    ;;
esac

echo -e "${GREEN}Setup complete!${NC}"
