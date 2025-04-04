#!/bin/bash

# Màu sắc cho output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Vui lòng chạy script với quyền root (sudo)${NC}"
  exit 1
fi

echo -e "${BLUE}=== SCRIPT PROXY ỔN ĐỊNH V2RAY ====${NC}"

# Lấy địa chỉ IP công cộng
PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || curl -s https://api.ipify.org || curl -s https://ifconfig.me)
if [ -z "$PUBLIC_IP" ]; then
  echo -e "${YELLOW}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
  PUBLIC_IP=$(hostname -I | awk '{print $1}')
fi

# Thông số cấu hình
HTTP_BRIDGE_PORT=8118
V2RAY_PORT=10086
INTERNAL_V2RAY_PORT=10087
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/$(head /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)"

#############################################
# PHẦN 1: CẢI THIỆN ĐỘ ỔN ĐỊNH HỆ THỐNG
#############################################

echo -e "${GREEN}[1/5] Cải thiện độ ổn định hệ thống...${NC}"

# Tạo 2GB swap nếu chưa có
if [ "$(free | grep -c Swap)" -eq 0 ] || [ "$(free | grep Swap | awk '{print $2}')" -lt 1000000 ]; then
    echo -e "${YELLOW}Tạo 2GB RAM ảo (swap)...${NC}"
    # Xóa swap cũ nếu có
    swapoff -a
    rm -f /swapfile

    # Tạo swap mới
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab

    # Cấu hình swap
    echo 10 > /proc/sys/vm/swappiness
    echo "vm.swappiness = 10" > /etc/sysctl.d/99-swap.conf
    sysctl -p /etc/sysctl.d/99-swap.conf
fi

# Tối ưu hóa limits.conf 
cat > /etc/security/limits.d/proxy-limits.conf << EOF
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

# Tối ưu hóa kernel parameters
cat > /etc/sysctl.d/99-network-tuning.conf << EOF
# Tăng kích thước buffer để tránh hiện tượng packet drop
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 26214400
net.ipv4.tcp_wmem = 4096 1048576 26214400

# Tăng ngưỡng backlog để xử lý nhiều kết nối đồng thời
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384

# Tối ưu hóa thời gian kết nối TCP 
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_tw_reuse = 1

# Tăng tốc độ kết nối
net.ipv4.tcp_fastopen = 3
EOF

sysctl -p /etc/sysctl.d/99-network-tuning.conf

#############################################
# PHẦN 2: CÀI ĐẶT PHẦN MỀM
#############################################

echo -e "${GREEN}[2/5] Cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y nginx curl wget unzip jq htop iptables-persistent

#############################################
# PHẦN 3: CÀI ĐẶT GOST VÀ V2RAY
#############################################

echo -e "${GREEN}[3/5] Cài đặt GOST và V2Ray...${NC}"

# Cài đặt GOST (HTTP Bridge)
mkdir -p /tmp/gost
cd /tmp/gost
wget -q https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
gunzip gost-linux-amd64-2.11.5.gz
mv gost-linux-amd64-2.11.5 /usr/local/bin/gost
chmod +x /usr/local/bin/gost

# Tạo service cho GOST
cat > /etc/systemd/system/gost-bridge.service << EOF
[Unit]
Description=GOST HTTP-VMess Bridge
After=network.target v2ray.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -L http://:$HTTP_BRIDGE_PORT -F tcp://127.0.0.1:$INTERNAL_V2RAY_PORT
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# Cài đặt V2Ray
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

# Cấu hình V2Ray
cat > /usr/local/etc/v2ray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log"
  },
  "inbounds": [
    {
      "port": $INTERNAL_V2RAY_PORT,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "",
        "port": 0,
        "network": "tcp,udp",
        "followRedirect": true
      },
      "tag": "http-bridge-in",
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "port": $V2RAY_PORT,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WS_PATH"
        },
        "sockopt": {
          "tcpFastOpen": true,
          "tcpKeepAliveInterval": 30
        }
      },
      "tag": "vmess-in",
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "tag": "direct"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["http-bridge-in", "vmess-in"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

#############################################
# PHẦN 4: THIẾT LẬP PAC FILE VÀ NGINX
#############################################

echo -e "${GREEN}[4/5] Thiết lập PAC file và Nginx...${NC}"

# Cấu hình Nginx
cat > /etc/nginx/nginx.conf << EOF
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Cấu hình máy chủ Nginx
cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $PUBLIC_IP;
    
    # Ngụy trang là một trang web bình thường
    location / {
        root /var/www/html;
        index index.html;
        add_header X-Content-Type-Options "nosniff" always;
    }
    
    # Định tuyến WebSocket đến V2Ray
    location $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$V2RAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 120s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 120s;
    }
    
    # PAC file cho iPhone
    location /proxy/ {
        root /var/www/html;
        types { } 
        default_type application/x-ns-proxy-autoconfig;
        add_header Cache-Control "no-cache";
    }
}
EOF

# Tạo thư mục và PAC file toàn cầu (proxy mọi kết nối)
mkdir -p /var/www/html/proxy
cat > /var/www/html/proxy/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Chỉ truy cập trực tiếp các tài nguyên cục bộ
    if (isPlainHostName(host) || 
        shExpMatch(host, "*.local") || 
        isInNet(host, "10.0.0.0", "255.0.0.0") ||
        isInNet(host, "172.16.0.0", "255.240.0.0") ||
        isInNet(host, "192.168.0.0", "255.255.0.0") ||
        isInNet(host, "127.0.0.0", "255.0.0.0")) {
        return "DIRECT";
    }
    
    // Tất cả kết nối khác đều đi qua proxy
    return "PROXY $PUBLIC_IP:$HTTP_BRIDGE_PORT";
}
EOF

# Tạo trang web ngụy trang đơn giản
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { font-family: Arial; text-align: center; margin-top: 50px; }
    </style>
</head>
<body>
    <h1>Hello World!</h1>
    <p>Server is running</p>
</body>
</html>
EOF

#############################################
# PHẦN 5: KHỞI ĐỘNG DỊCH VỤ VÀ THIẾT LẬP TỰ ĐỘNG KHÔI PHỤC
#############################################

echo -e "${GREEN}[5/5] Thiết lập khởi động dịch vụ và cơ chế tự động khôi phục...${NC}"

# Tạo script giám sát kết nối
cat > /usr/local/bin/monitor-proxy.sh << EOF
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Kiểm tra kết nối đến các dịch vụ phổ biến
check_connection() {
  echo -e "\${GREEN}Kiểm tra kết nối proxy...${NC}"
  
  # Kiểm tra kết nối qua proxy
  PROXY_CHECK=\$(curl -s -x http://127.0.0.1:$HTTP_BRIDGE_PORT -o /dev/null -w "%{http_code}" https://www.google.com)
  
  if [ "\$PROXY_CHECK" == "200" ] || [ "\$PROXY_CHECK" == "301" ] || [ "\$PROXY_CHECK" == "302" ]; then
    echo -e "\${GREEN}Kết nối proxy hoạt động tốt ✅${NC}"
  else
    echo -e "\${RED}Kết nối proxy không hoạt động! ❌${NC}"
    echo -e "\${GREEN}Khởi động lại các dịch vụ...${NC}"
    systemctl restart v2ray
    systemctl restart gost-bridge
    sleep 5
    
    # Kiểm tra lại
    RETRY_CHECK=\$(curl -s -x http://127.0.0.1:$HTTP_BRIDGE_PORT -o /dev/null -w "%{http_code}" https://www.google.com)
    if [ "\$RETRY_CHECK" == "200" ] || [ "\$RETRY_CHECK" == "301" ] || [ "\$RETRY_CHECK" == "302" ]; then
      echo -e "\${GREEN}Kết nối proxy đã được khôi phục ✅${NC}"
    else
      echo -e "\${RED}Kết nối proxy vẫn không hoạt động! Khôi phục toàn bộ hệ thống...${NC}"
      systemctl restart nginx
      systemctl restart v2ray
      systemctl restart gost-bridge
    fi
  fi
}

# Kiểm tra dịch vụ
check_services() {
  for service in v2ray gost-bridge nginx; do
    if systemctl is-active --quiet \$service; then
      echo -e "\${GREEN}\$service đang chạy ✅${NC}"
    else
      echo -e "\${RED}\$service không chạy! Khởi động lại...${NC}"
      systemctl restart \$service
    fi
  done
}

# Chạy kiểm tra
check_services
check_connection
EOF
chmod +x /usr/local/bin/monitor-proxy.sh

# Tạo script khởi động lại
cat > /usr/local/bin/restart-proxy.sh << EOF
#!/bin/bash
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "\${GREEN}Khởi động lại tất cả dịch vụ proxy...${NC}"
systemctl restart v2ray
systemctl restart gost-bridge
systemctl restart nginx
echo -e "\${GREEN}Tất cả dịch vụ đã được khởi động lại ✅${NC}"
EOF
chmod +x /usr/local/bin/restart-proxy.sh

# Thiết lập cron job để giám sát và tự động khởi động lại
(crontab -l 2>/dev/null || echo "") | {
    cat
    echo "*/15 * * * * /usr/local/bin/monitor-proxy.sh > /dev/null 2>&1" # Kiểm tra mỗi 15 phút
    echo "0 */3 * * * /usr/local/bin/restart-proxy.sh > /dev/null 2>&1"  # Khởi động lại mỗi 3 giờ
} | crontab -

# Khởi động dịch vụ
systemctl daemon-reload
systemctl enable v2ray
systemctl enable gost-bridge
systemctl enable nginx
systemctl restart v2ray
systemctl restart gost-bridge
systemctl restart nginx

# Tạo URL chia sẻ V2Ray
V2RAY_CONFIG=$(cat <<EOF
{
  "v": "2",
  "ps": "V2Ray-WebSocket",
  "add": "$PUBLIC_IP",
  "port": "80",
  "id": "$UUID",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "$PUBLIC_IP",
  "path": "$WS_PATH",
  "tls": ""
}
EOF
)

# Mã hóa cấu hình để tạo URL
V2RAY_LINK="vmess://$(echo $V2RAY_CONFIG | jq -c . | base64 -w 0)"

# Hiển thị thông tin kết nối
echo -e "\n${BLUE}========================================================${NC}"
echo -e "${GREEN}CÀI ĐẶT THÀNH CÔNG! TẤT CẢ KẾT NỐI SẼ ĐI QUA PROXY${NC}"
echo -e "${BLUE}========================================================${NC}"

echo -e "\n${YELLOW}THÔNG TIN KẾT NỐI:${NC}"
echo -e "HTTP Bridge (cho iPhone): ${GREEN}$PUBLIC_IP:$HTTP_BRIDGE_PORT${NC}"
echo -e "PAC URL (cho iPhone): ${GREEN}http://$PUBLIC_IP/proxy/proxy.pac${NC}"
echo -e "UUID V2Ray: ${GREEN}$UUID${NC}"
echo -e "WebSocket Path: ${GREEN}$WS_PATH${NC}"

echo -e "\n${YELLOW}URL V2RAY:${NC}"
echo -e "${GREEN}$V2RAY_LINK${NC}"

echo -e "\n${YELLOW}HƯỚNG DẪN CẤU HÌNH IPHONE:${NC}"
echo -e "1. Vào Settings > Wi-Fi > [Mạng Wi-Fi] > Configure Proxy > Auto"
echo -e "2. URL: ${GREEN}http://$PUBLIC_IP/proxy/proxy.pac${NC}"
echo -e "3. Nếu không ổn định, dùng cấu hình thủ công:"
echo -e "   Server: ${GREEN}$PUBLIC_IP${NC}"
echo -e "   Port: ${GREEN}$HTTP_BRIDGE_PORT${NC}"

echo -e "\n${YELLOW}QUẢN LÝ HỆ THỐNG:${NC}"
echo -e "Giám sát: ${GREEN}sudo /usr/local/bin/monitor-proxy.sh${NC}"
echo -e "Khởi động lại: ${GREEN}sudo /usr/local/bin/restart-proxy.sh${NC}"
echo -e "${BLUE}========================================================${NC}"
