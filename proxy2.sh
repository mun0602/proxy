#!/bin/bash

# Ubuntu Proxy Server Setup Script
# This script installs and configures a Squid proxy server on Ubuntu

# Exit on error
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Ubuntu Proxy Server Setup${NC}"
echo "This script will install and configure a Squid proxy server"
echo "-----------------------------------------------------------"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

# Update system
echo -e "${GREEN}Updating system packages...${NC}"
apt update && apt upgrade -y

# Install Squid
echo -e "${GREEN}Installing Squid proxy server...${NC}"
apt install -y squid apache2-utils

# Backup original configuration
echo -e "${GREEN}Backing up original Squid configuration...${NC}"
cp /etc/squid/squid.conf /etc/squid/squid.conf.bak

# Get server IP
SERVER_IP=$(hostname -I | awk '{print $1}')

# Set proxy port (default: 3128)
read -p "Enter port for proxy server [3128]: " PROXY_PORT
PROXY_PORT=${PROXY_PORT:-3128}

# Ask if authentication is needed
read -p "Do you want to set up authentication? (y/n): " AUTH_NEEDED

if [[ "$AUTH_NEEDED" =~ ^[Yy]$ ]]; then
  # Create authentication file
  echo -e "${GREEN}Setting up authentication...${NC}"
  read -p "Enter username for proxy: " PROXY_USER
  
  # Create password file
  touch /etc/squid/passwd
  htpasswd -c /etc/squid/passwd $PROXY_USER
  chown proxy:proxy /etc/squid/passwd
  
  # Create new Squid configuration with authentication
  cat > /etc/squid/squid.conf << EOF
# Squid configuration with basic authentication

# Define ACL for localhost
acl localhost src 127.0.0.1/32 ::1
acl localnet src $SERVER_IP/32

# Port configuration
http_port $PROXY_PORT

# Authentication settings
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd
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
  cat > /etc/squid/squid.conf << EOF
# Squid configuration without authentication

# Define ACL for localhost
acl localhost src 127.0.0.1/32 ::1
acl localnet src $SERVER_IP/32

# Port configuration
http_port $PROXY_PORT

# Access control
http_access allow localnet
http_access allow localhost
http_access deny all

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

# Restart Squid service
echo -e "${GREEN}Restarting Squid service...${NC}"
systemctl restart squid
systemctl enable squid

# Verify service is running
if systemctl is-active --quiet squid; then
  echo -e "${GREEN}Squid proxy server is now running!${NC}"
else
  echo -e "${RED}Failed to start Squid proxy server. Check logs with: journalctl -u squid${NC}"
  exit 1
fi

# Display proxy information
echo -e "${YELLOW}Proxy Server Information:${NC}"
echo "Server IP: $SERVER_IP"
echo "Port: $PROXY_PORT"
if [[ "$AUTH_NEEDED" =~ ^[Yy]$ ]]; then
  echo "Username: $PROXY_USER"
  echo "Authentication: Enabled"
else
  echo "Authentication: Disabled"
fi

echo -e "${YELLOW}To use this proxy:${NC}"
echo "Proxy Server: $SERVER_IP:$PROXY_PORT"
if [[ "$AUTH_NEEDED" =~ ^[Yy]$ ]]; then
  echo "Credentials required: Yes (username and password)"
fi

echo -e "${GREEN}Setup complete!${NC}"
