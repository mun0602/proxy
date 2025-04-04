#!/bin/bash

# Script cài đặt GOST với PAC cho Kuaishou, Douyin, WeChat
# GOST là proxy đa giao thức có khả năng ngụy trang lưu lượng

# Màu sắc cho output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Vui lòng chạy script với quyền root (sudo)${NC}"
  exit 1
fi

# Hàm để chọn cổng thường dùng bởi dịch vụ hợp pháp (ngụy trang)
get_common_port() {
  # Sử dụng các cổng phổ biến để tránh bị lọc
  COMMON_PORTS=(443 8443 8080 2087 2083)
  SELECTED_PORT=${COMMON_PORTS[$RANDOM % ${#COMMON_PORTS[@]}]}
  
  # Kiểm tra xem cổng đã được sử dụng chưa
  if netstat -tuln | grep -q ":$SELECTED_PORT "; then
    # Nếu cổng đã được sử dụng, tạo một cổng ngẫu nhiên
    while true; do
      RANDOM_PORT=$(shuf -i 10000-65000 -n 1)
      if ! netstat -tuln | grep -q ":$RANDOM_PORT "; then
        echo $RANDOM_PORT
        return 0
      fi
    done
  else
    echo $SELECTED_PORT
  fi
}

# Hàm lấy địa chỉ IP công cộng
get_public_ip() {
  # Sử dụng nhiều dịch vụ để đảm bảo lấy được IP
  PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || 
              curl -s https://api.ipify.org || 
              curl -s https://ifconfig.me || 
              curl -s https://icanhazip.com || 
              curl -s https://ipinfo.io/ip)

  if [ -z "$PUBLIC_IP" ]; then
    echo -e "${YELLOW}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
    PUBLIC_IP=$(hostname -I | awk '{print $1}')
  fi
}

# Lấy cổng phổ biến
HTTP_PROXY_PORT=$(get_common_port)
SOCKS_PROXY_PORT=$(get_common_port)
TLS_PROXY_PORT=$(get_common_port)
echo -e "${GREEN}Đã chọn cổng HTTP proxy: $HTTP_PROXY_PORT${NC}"
echo -e "${GREEN}Đã chọn cổng SOCKS proxy: $SOCKS_PROXY_PORT${NC}"
echo -e "${GREEN}Đã chọn cổng TLS proxy: $TLS_PROXY_PORT${NC}"

# Sử dụng cổng 80 cho web server (cổng HTTP tiêu chuẩn) 
HTTP_PORT=80
echo -e "${GREEN}Sử dụng cổng HTTP tiêu chuẩn: $HTTP_PORT${NC}"

# Tạo người dùng và mật khẩu ngẫu nhiên cho xác thực
PROXY_USER="user$(openssl rand -hex 3)"
PROXY_PASS="pass$(openssl rand -hex 6)"
echo -e "${GREEN}Tạo thông tin đăng nhập proxy:${NC}"
echo -e "Username: ${YELLOW}$PROXY_USER${NC}"
echo -e "Password: ${YELLOW}$PROXY_PASS${NC}"

# Cài đặt các gói cần thiết
echo -e "${GREEN}Đang cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y nginx curl ufw openssl wget unzip

# Dừng các dịch vụ để cấu hình
systemctl stop nginx 2>/dev/null

# Tạo thư mục SSL
mkdir -p /etc/gost/ssl
chmod 700 /etc/gost/ssl

# Tạo SSL certificate cho TLS proxy
echo -e "${GREEN}Đang tạo SSL certificate cho proxy HTTPS...${NC}"
openssl req -new -newkey rsa:2048 -sha256 -days 365 -nodes -x509 \
  -keyout /etc/gost/ssl/gost.key \
  -out /etc/gost/ssl/gost.crt \
  -subj "/C=US/ST=State/L=City/O=Organization/CN=cdn.example.com"

# Tải về và cài đặt GOST
echo -e "${GREEN}Đang tải và cài đặt GOST...${NC}"
mkdir -p /tmp/gost
cd /tmp/gost
wget https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
gunzip gost-linux-amd64-2.11.5.gz
mv gost-linux-amd64-2.11.5 /usr/local/bin/gost
chmod +x /usr/local/bin/gost

# Tạo thư mục cấu hình GOST
mkdir -p /etc/gost

# Tạo file cấu hình GOST
cat > /etc/gost/config.json << EOF
{
    "Debug": true,
    "Retries": 0,
    "Routes": [
        {
            "Retries": 0,
            "ServeNodes": [
                "http://$PROXY_USER:$PROXY_PASS@:$HTTP_PROXY_PORT",
                "socks5://$PROXY_USER:$PROXY_PASS@:$SOCKS_PROXY_PORT",
                "tls://:$TLS_PROXY_PORT?cert=/etc/gost/ssl/gost.crt&key=/etc/gost/ssl/gost.key"
            ],
            "ChainNodes": [
                "relay+tls://:$TLS_PROXY_PORT"
            ]
        }
    ]
}
EOF

# Tạo service file cho GOST
cat > /etc/systemd/system/gost.service << EOF
[Unit]
Description=GO Simple Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C /etc/gost/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Tạo thư mục cho PAC file
mkdir -p /var/www/html

# Lấy địa chỉ IP công cộng
get_public_ip

# Tạo PAC file tối ưu cho các ứng dụng Trung Quốc và trang kiểm tra
cat > /var/www/html/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Các domain cần dùng proxy
    var proxy_domains = [
        // Kuaishou domains
        ".kuaishou.com",
        ".gifshow.com",
        ".yxixy.com",
        
        // Douyin domains
        ".douyin.com",
        ".tiktokv.com",
        ".bytedance.com",
        ".iesdouyin.com",
        ".amemv.com",
        
        // WeChat domains
        ".wechat.com",
        ".weixin.qq.com",
        ".wx.qq.com",
        ".weixinbridge.com",
        
        // IP/Speed testing services
        ".ipleak.net",
        ".speedtest.net",
        ".fast.com",
        ".netflix.com",        // Needed for fast.com
        ".nflxvideo.net",      // Needed for fast.com
        ".nflximg.net",        // Needed for fast.com
        ".ooklaserver.net",    // Needed for speedtest.net
        ".cloudfront.net"      // Needed for various services
    ];
    
    // Kiểm tra IP trong dải Trung Quốc (thêm các dải IP phổ biến)
    if (isInNet(dnsResolve(host), "58.14.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "58.16.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "58.24.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.128.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.132.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.136.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.139.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "101.227.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "101.226.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "101.224.0.0", "255.255.0.0")) {
        
        // Sử dụng proxy HTTP cho dải IP Trung Quốc
        return "PROXY $PUBLIC_IP:$HTTP_PROXY_PORT; SOCKS5 $PUBLIC_IP:$SOCKS_PROXY_PORT";
    }
    
    // Kiểm tra domain trong danh sách
    for (var i = 0; i < proxy_domains.length; i++) {
        if (dnsDomainIs(host, proxy_domains[i]) || 
            shExpMatch(host, "*" + proxy_domains[i] + "*")) {
            
            // Sử dụng proxy HTTP cho các domain được liệt kê
            return "PROXY $PUBLIC_IP:$HTTP_PROXY_PORT; SOCKS5 $PUBLIC_IP:$SOCKS_PROXY_PORT";
        }
    }
    
    // Mặc định truy cập trực tiếp
    return "DIRECT";
}
EOF

# Tạo trang index đơn giản chỉ hiển thị thông tin cơ bản
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>GOST Proxy Info</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
</head>
<body>
    <h3>Proxy Settings</h3>
    <p>HTTP Proxy: $PUBLIC_IP:$HTTP_PROXY_PORT</p>
    <p>SOCKS5 Proxy: $PUBLIC_IP:$SOCKS_PROXY_PORT</p>
    <p>TLS Proxy: $PUBLIC_IP:$TLS_PROXY_PORT</p>
    <p>User: $PROXY_USER</p>
    <p>Pass: $PROXY_PASS</p>
    <p><a href="/proxy.pac">PAC File</a></p>
</body>
</html>
EOF

# Tạo file JavaScript để truy cập proxy trực tiếp (cho ứng dụng mobile)
cat > /var/www/html/config.js << EOF
var proxyConfig = {
    "http": {
        "server": "$PUBLIC_IP",
        "port": $HTTP_PROXY_PORT,
        "username": "$PROXY_USER",
        "password": "$PROXY_PASS"
    },
    "socks": {
        "server": "$PUBLIC_IP",
        "port": $SOCKS_PROXY_PORT,
        "username": "$PROXY_USER",
        "password": "$PROXY_PASS"
    },
    "tls": {
        "server": "$PUBLIC_IP",
        "port": $TLS_PROXY_PORT
    }
};
EOF

# Cấu hình Nginx để phục vụ PAC file với bảo mật
cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    root /var/www/html;
    index index.html;
    
    server_name _;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    location /proxy.pac {
        types { }
        default_type application/x-ns-proxy-autoconfig;
        add_header Content-Disposition 'inline; filename="proxy.pac"';
        
        # Thêm các header bảo mật
        add_header X-Content-Type-Options "nosniff";
        add_header X-Frame-Options "DENY";
        add_header X-XSS-Protection "1; mode=block";
    }
    
    location /config.js {
        types { }
        default_type application/javascript;
        
        # Thêm các header bảo mật
        add_header X-Content-Type-Options "nosniff";
        add_header X-Frame-Options "DENY";
        add_header X-XSS-Protection "1; mode=block";
    }
    
    # Chặn truy cập các file hệ thống
    location ~ /\.ht {
        deny all;
    }
}
EOF

# Cấu hình tường lửa
echo -e "${GREEN}Đang cấu hình tường lửa...${NC}"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow $HTTP_PORT/tcp
ufw allow $HTTP_PROXY_PORT/tcp
ufw allow $SOCKS_PROXY_PORT/tcp
ufw allow $TLS_PROXY_PORT/tcp
ufw --force enable

# Tạo script xoay vòng IP (cho tương lai)
cat > /usr/local/bin/rotate-gost-ip.sh << EOF
#!/bin/bash
# Script xoay vòng IP cho GOST
# Để sử dụng, chạy lệnh: sudo /usr/local/bin/rotate-gost-ip.sh

# Lấy IP công cộng mới
NEW_IP=\$(curl -s https://checkip.amazonaws.com || curl -s https://api.ipify.org)

# Cập nhật PAC file
sed -i "s/PROXY [^:]*:/PROXY \$NEW_IP:/g" /var/www/html/proxy.pac
sed -i "s/SOCKS5 [^:]*:/SOCKS5 \$NEW_IP:/g" /var/www/html/proxy.pac

# Cập nhật config.js
sed -i "s/\"server\": \"[^\"]*\"/\"server\": \"\$NEW_IP\"/g" /var/www/html/config.js

# Cập nhật trang index.html
sed -i "s/HTTP Proxy: [^:]*:/HTTP Proxy: \$NEW_IP:/g" /var/www/html/index.html
sed -i "s/SOCKS5 Proxy: [^:]*:/SOCKS5 Proxy: \$NEW_IP:/g" /var/www/html/index.html
sed -i "s/TLS Proxy: [^:]*:/TLS Proxy: \$NEW_IP:/g" /var/www/html/index.html

echo "Đã cập nhật IP thành \$NEW_IP"
EOF
chmod +x /usr/local/bin/rotate-gost-ip.sh

# Kích hoạt và khởi động các dịch vụ
systemctl daemon-reload
systemctl enable gost
systemctl enable nginx
systemctl start gost
systemctl start nginx

# Kiểm tra GOST
echo -e "${YELLOW}Đang kiểm tra GOST...${NC}"
sleep 2
if systemctl is-active --quiet gost; then
  echo -e "${GREEN}GOST đang chạy!${NC}"
else
  echo -e "${RED}GOST không thể khởi động. Kiểm tra log: journalctl -u gost${NC}"
fi

# Kiểm tra Nginx
echo -e "${YELLOW}Đang kiểm tra Nginx...${NC}"
if systemctl is-active --quiet nginx; then
  echo -e "${GREEN}Nginx đang chạy!${NC}"
else
  echo -e "${RED}Nginx không khởi động được. Kiểm tra log: journalctl -u nginx${NC}"
fi

# Kiểm tra các cổng
echo -e "${YELLOW}Kiểm tra các cổng đã mở...${NC}"
echo -e "Cổng HTTP Proxy ($HTTP_PROXY_PORT): \c"
if netstat -tuln | grep -q ":$HTTP_PROXY_PORT "; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}KHÔNG HOẠT ĐỘNG${NC}"
fi

echo -e "Cổng SOCKS Proxy ($SOCKS_PROXY_PORT): \c"
if netstat -tuln | grep -q ":$SOCKS_PROXY_PORT "; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}KHÔNG HOẠT ĐỘNG${NC}"
fi

# Hiển thị thông tin cấu hình
echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}CẤU HÌNH GOST PROXY HOÀN TẤT!${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "HTTP Proxy: ${GREEN}$PUBLIC_IP:$HTTP_PROXY_PORT${NC}"
echo -e "SOCKS5 Proxy: ${GREEN}$PUBLIC_IP:$SOCKS_PROXY_PORT${NC}"
echo -e "TLS Proxy: ${GREEN}$PUBLIC_IP:$TLS_PROXY_PORT${NC}"
echo -e "Username: ${GREEN}$PROXY_USER${NC}"
echo -e "Password: ${GREEN}$PROXY_PASS${NC}"
echo -e "URL PAC file: ${GREEN}http://$PUBLIC_IP/proxy.pac${NC}"
echo -e "${GREEN}============================================${NC}"

# Hiển thị ví dụ cách sử dụng GOST với các ứng dụng
echo -e "\n${YELLOW}Cách sử dụng:${NC}"
echo -e "1. ${GREEN}Tự động với PAC file:${NC}"
echo -e "   Cấu hình proxy tự động: ${GREEN}http://$PUBLIC_IP/proxy.pac${NC}"
echo
echo -e "2. ${GREEN}Cấu hình thủ công:${NC}"
echo -e "   HTTP Proxy: ${GREEN}$PUBLIC_IP:$HTTP_PROXY_PORT${NC}"
echo -e "   SOCKS5 Proxy: ${GREEN}$PUBLIC_IP:$SOCKS_PROXY_PORT${NC}"
echo -e "   Username: ${GREEN}$PROXY_USER${NC}"
echo -e "   Password: ${GREEN}$PROXY_PASS${NC}"
echo
echo -e "3. ${GREEN}Xoay vòng IP (nếu cần):${NC}"
echo -e "   Chạy: ${GREEN}sudo /usr/local/bin/rotate-gost-ip.sh${NC}"
echo -e "   Hoặc tự động với crontab: ${GREEN}0 */6 * * * /usr/local/bin/rotate-gost-ip.sh${NC}"
