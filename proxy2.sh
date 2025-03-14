#!/bin/bash

# Ubuntu Proxy Server Setup Script
# This script installs and configures either an HTTP proxy (Squid) or SOCKS5 proxy (Dante/3proxy) on Ubuntu

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
echo "2) SOCKS5 proxy (3proxy)"
read -p "Enter your choice [1-2]: " PROXY_TYPE

case $PROXY_TYPE in
  2)
    # Install and configure SOCKS5 proxy using 3proxy (more reliable than Dante)
    echo -e "${GREEN}Installing SOCKS5 proxy server (3proxy)...${NC}"
    
    # Install build tools
    apt install -y gcc make wget

    # Create temp directory and navigate to it
    mkdir -p /tmp/3proxy
    cd /tmp/3proxy
    
    # Download and extract 3proxy
    echo -e "${GREEN}Downloading 3proxy...${NC}"
    wget -q https://github.com/3proxy/3proxy/archive/0.9.4.tar.gz
    tar -xf 0.9.4.tar.gz
    cd 3proxy-0.9.4
    
    # Compile and install
    echo -e "${GREEN}Compiling 3proxy...${NC}"
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy
    mkdir -p /usr/local/bin
    mkdir -p /usr/local/man/man3
    make -f Makefile.Linux install
    
    # Set proxy port
    read -p "Enter port for SOCKS5 proxy server [1080]: " PROXY_PORT
    PROXY_PORT=${PROXY_PORT:-1080}
    
    # Ask if authentication is needed
    read -p "Do you want to set up authentication? (y/n): " AUTH_NEEDED
    
    # Create configuration directory if it doesn't exist
    mkdir -p /usr/local/etc/3proxy
    
    # Create config file
    if [[ "$AUTH_NEEDED" =~ ^[Yy]$ ]]; then
      # Create user for 3proxy
      echo -e "${GREEN}Setting up authentication...${NC}"
      read -p "Enter username for proxy: " PROXY_USER
      read -s -p "Enter password for proxy: " PROXY_PASS
      echo
      
      # Create password file
      echo "$PROXY_USER:CL:$PROXY_PASS" > /usr/local/etc/3proxy/passwd
      
      # Configure 3proxy with authentication
      cat > /usr/local/etc/3proxy/3proxy.cfg << EOF
#!/usr/local/bin/3proxy
# 3proxy configuration with authentication

daemon
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /var/log/3proxy.log
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
rotate 30

users $(cat /usr/local/etc/3proxy/passwd)

auth strong

# SOCKS5 proxy server
socks -p$PROXY_PORT -a
EOF
    else
      # Configure 3proxy without authentication
      cat > /usr/local/etc/3proxy/3proxy.cfg << EOF
#!/usr/local/bin/3proxy
# 3proxy configuration without authentication

daemon
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /var/log/3proxy.log
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
rotate 30

# SOCKS5 proxy server
socks -p$PROXY_PORT
EOF
    fi
    
    # Create systemd service file
    cat > /etc/systemd/system/3proxy.service << EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd, enable and start service
    systemctl daemon-reload
    systemctl enable 3proxy
    systemctl start 3proxy
    
    # Configure firewall
    echo -e "${GREEN}Configuring firewall...${NC}"
    apt install -y ufw
    ufw allow ssh
    ufw allow $PROXY_PORT/tcp
    ufw --force enable
    
    # Verify service is running
    if systemctl is-active --quiet 3proxy; then
      echo -e "${GREEN}SOCKS5 proxy server is now running!${NC}"
    else
      echo -e "${RED}Failed to start SOCKS5 proxy server. Check logs with: journalctl -u 3proxy${NC}"
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
    
    # Clean up temporary files
    cd /
    rm -rf /tmp/3proxy
    ;;
    
  *)
    # Default to HTTP proxy (Squid)
    echo -e "${GREEN}Installing HTTP proxy server (Squid)...${NC}"
    apt install -y squid apache2-utils
    
    # Backup original configuration
    echo -e "${GREEN}Backing up original Squid configuration...${NC}"
    if [ -f /etc/squid/squid.conf ]; then
      cp /etc/squid/squid.conf /etc/squid/squid.conf.bak
    elif [ -f /etc/squid3/squid.conf ]; then
      cp /etc/squid3/squid.conf /etc/squid3/squid.conf.bak
      SQUID_CONFIG_DIR="/etc/squid3"
    else
      SQUID_CONFIG_DIR="/etc/squid"
    fi
    
    # Set squid configuration directory based on what exists
    if [ -z "$SQUID_CONFIG_DIR" ]; then
      if [ -d /etc/squid ]; then
        SQUID_CONFIG_DIR="/etc/squid"
      else
        SQUID_CONFIG_DIR="/etc/squid3"
      fi
    fi
    
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
      touch $SQUID_CONFIG_DIR/passwd
      htpasswd -c $SQUID_CONFIG_DIR/passwd $PROXY_USER
      chown proxy:proxy $SQUID_CONFIG_DIR/passwd 2>/dev/null || true
      
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
        BASIC_AUTH_PATH="/usr/lib/squid/basic_ncsa_auth"
      fi
      
      # Create new Squid configuration with authentication
      cat > $SQUID_CONFIG_DIR/squid.conf << EOF
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
      cat > $SQUID_CONFIG_DIR/squid.conf << EOF
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
    systemctl restart $SQUID_SERVICE
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
