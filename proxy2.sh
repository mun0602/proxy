#!/bin/bash

# Ubuntu Proxy Server Setup Script
# This script installs and configures either an HTTP proxy (Squid) or SOCKS5 proxy (Dante) on Ubuntu

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
apt update && apt upgrade -y

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

# Choose proxy type
echo -e "${YELLOW}Choose proxy type:${NC}"
echo "1) HTTP proxy (Squid)"
echo "2) SOCKS5 proxy (Dante)"
read -p "Enter your choice [1-2]: " PROXY_TYPE

case $PROXY_TYPE in
  2)
    # Install and configure SOCKS5 proxy (Dante)
    echo -e "${GREEN}Installing SOCKS5 proxy server (Dante)...${NC}"
    apt install -y dante-server
    
    # Set proxy port
    read -p "Enter port for SOCKS5 proxy server [1080]: " PROXY_PORT
    PROXY_PORT=${PROXY_PORT:-1080}
    
    # Ask if authentication is needed
    read -p "Do you want to set up authentication? (y/n): " AUTH_NEEDED
    
    # Backup original configuration
    cp /etc/dante.conf /etc/dante.conf.bak
    
    if [[ "$AUTH_NEEDED" =~ ^[Yy]$ ]]; then
      # Create user for Dante
      echo -e "${GREEN}Setting up authentication...${NC}"
      read -p "Enter username for proxy: " PROXY_USER
      read -s -p "Enter password for proxy: " PROXY_PASS
      echo
      
      # Add user
      useradd -r -s /bin/false $PROXY_USER
      echo "$PROXY_USER:$PROXY_PASS" | chpasswd
      
      # Configure Dante with authentication
      cat > /etc/dante.conf << EOF
logoutput: stderr
internal: 0.0.0.0 port=$PROXY_PORT
external: $PUBLIC_IP
socksmethod: username
user.privileged: root
user.unprivileged: nobody
user.libwrap: nobody
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
    socksmethod: username
}
EOF
    else
      # Configure Dante without authentication
      cat > /etc/dante.conf << EOF
logoutput: stderr
internal: 0.0.0.0 port=$PROXY_PORT
external: $PUBLIC_IP
socksmethod: none
user.privileged: root
user.unprivileged: nobody
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
EOF
    fi
    
    # Restart Dante service
    echo -e "${GREEN}Restarting SOCKS5 proxy service...${NC}"
    systemctl restart danted
    systemctl enable danted
    
    # Configure firewall
    echo -e "${GREEN}Configuring firewall...${NC}"
    apt install -y ufw
    ufw allow ssh
    ufw allow $PROXY_PORT/tcp
    ufw --force enable
    
    # Verify service is running
    if systemctl is-active --quiet danted; then
      echo -e "${GREEN}SOCKS5 proxy server is now running!${NC}"
    else
      echo -e "${RED}Failed to start SOCKS5 proxy server. Check logs with: journalctl -u danted${NC}"
      exit 1
    fi
    
    # Display proxy information
    echo -e "${YELLOW}SOCKS5 Proxy Server Information:${NC}"
    echo "Public IP: $PUBLIC_IP"
    echo "Port: $PROXY_PORT"
    if [[ "$AUTH_NEEDED" =~ ^[Yy]$ ]]; then
      echo "Username: $PROXY_USER"
      echo "Authentication: Enabled"
    else
      echo "Authentication: Disabled"
    fi
    
    echo -e "${YELLOW}To use this proxy:${NC}"
    echo "SOCKS5 Proxy: $PUBLIC_IP:$PROXY_PORT"
    if [[ "$AUTH_NEEDED" =~ ^[Yy]$ ]]; then
      echo "Credentials required: Yes (username and password)"
    fi
    ;;
    
  *)
    # Default to HTTP proxy (Squid)
    echo -e "${GREEN}Installing HTTP proxy server (Squid)...${NC}"
    apt install -y squid apache2-utils
    
    # Backup original configuration
    echo -e "${GREEN}Backing up original Squid configuration...${NC}"
    cp /etc/squid/squid.conf /etc/squid/squid.conf.bak
    
    # Set proxy port (default: 3128)
    read -p "Enter port for HTTP proxy server [3128]: " PROXY_PORT
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
acl to_localhost dst 127.0.0.0/8 0.0.0.0/32 ::1

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
    
    # Restart Squid service
    echo -e "${GREEN}Restarting Squid service...${NC}"
    systemctl restart squid
    systemctl enable squid
    
    # Verify service is running
    if systemctl is-active --quiet squid; then
      echo -e "${GREEN}HTTP proxy server is now running!${NC}"
    else
      echo -e "${RED}Failed to start HTTP proxy server. Check logs with: journalctl -u squid${NC}"
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
