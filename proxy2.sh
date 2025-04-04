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

echo -e "${BLUE}=== KHẮC PHỤC HTTP BRIDGE QUA VMESS ====${NC}"

# Lấy địa chỉ IP công cộng
PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || curl -s https://api.ipify.org || curl -s https://ifconfig.me)
if [ -z "$PUBLIC_IP" ]; then
  echo -e "${YELLOW}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
  PUBLIC_IP=$(hostname -I | awk '{print $1}')
fi

# Thông số cấu hình
HTTP_PROXY_PORT=8118
SOCKS_PROXY_PORT=1080
V2RAY_PORT=10086
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/$(head /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)"
TAG=$(date +%s)

#############################################
# PHẦN 1: DỪNG DỊCH VỤ CŨ VÀ LÀM SẠCH
#############################################

echo -e "${GREEN}[1/5] Dừng dịch vụ cũ và làm sạch...${NC}"

# Dừng và vô hiệu hóa dịch vụ GOST nếu tồn tại
if systemctl list-unit-files | grep -q gost; then
  systemctl stop gost-bridge
  systemctl disable gost-bridge
  rm -f /etc/systemd/system/gost-bridge.service
fi

# Dừng V2Ray để cấu hình lại
systemctl stop v2ray

# Lưu bản sao lưu các file cấu hình hiện tại
mkdir -p /etc/v2ray-setup/backup
if [ -f /usr/local/etc/v2ray/config.json ]; then
  cp /usr/local/etc/v2ray/config.json /etc/v2ray-setup/backup/config.json.bak.$(date +%Y%m%d%H%M%S)
fi

#############################################
# PHẦN 2: CÀI ĐẶT CÁC GÓI CẦN THIẾT
#############################################

echo -e "${GREEN}[2/5] Cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y nginx curl wget unzip jq htop net-tools dnsutils

# Tạo 2GB swap nếu chưa có
if [ "$(free | grep -c Swap)" -eq 0 ] || [ "$(free | grep Swap | awk '{print $2}')" -lt 1000000 ]; then
    echo -e "${YELLOW}Tạo 2GB RAM ảo (swap)...${NC}"
    swapoff -a
    rm -f /swapfile
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    echo 10 > /proc/sys/vm/swappiness
fi

#############################################
# PHẦN 3: CẤU HÌNH V2RAY CHO HTTP PROXY
#############################################

echo -e "${GREEN}[3/5] Cấu hình V2Ray cho HTTP proxy...${NC}"

# Cài đặt/Cập nhật V2Ray
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

# Tạo cấu hình V2Ray với HTTP proxy và VMess
cat > /usr/local/etc/v2ray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log"
  },
  "inbounds": [
    {
      "port": $HTTP_PROXY_PORT,
      "listen": "0.0.0.0",
      "protocol": "http",
      "settings": {
        "timeout": 300,
        "allowTransparent": false,
        "userLevel": 0
      },
      "tag": "http-in",
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "port": $SOCKS_PROXY_PORT,
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      },
      "tag": "socks-in",
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
            "alterId": 0,
            "security": "auto"
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
        "domainStrategy": "UseIPv4",
        "userLevel": 0
      },
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "inboundTag": ["http-in", "socks-in", "vmess-in"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

# Tối ưu V2Ray service
cat > /etc/systemd/system/v2ray.service << EOF
[Unit]
Description=V2Ray Service
Documentation=https://www.v2fly.org/
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/v2ray -config /usr/local/etc/v2ray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

#############################################
# PHẦN 4: CẤU HÌNH NGINX VÀ PAC FILE
#############################################

echo -e "${GREEN}[4/5] Cấu hình Nginx và PAC file...${NC}"

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

    # Công cụ kiểm tra IP
    location /ip {
        proxy_pass https://ipinfo.io/ip;
        proxy_set_header Host ipinfo.io;
        proxy_set_header X-Real-IP \$remote_addr;
        add_header Content-Type text/plain;
    }
}
EOF

# Tạo thư mục và PAC file đơn giản (chuyển hướng tất cả lưu lượng qua proxy)
mkdir -p /var/www/html/proxy
cat > /var/www/html/proxy/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Bỏ qua các dải IP cục bộ
    if (isPlainHostName(host) || 
        shExpMatch(host, "*.local") || 
        isInNet(host, "10.0.0.0", "255.0.0.0") ||
        isInNet(host, "172.16.0.0", "255.240.0.0") ||
        isInNet(host, "192.168.0.0", "255.255.0.0") ||
        isInNet(host, "127.0.0.0", "255.0.0.0")) {
        return "DIRECT";
    }
    
    // TẤT CẢ lưu lượng khác đi qua HTTP proxy
    return "PROXY $PUBLIC_IP:$HTTP_PROXY_PORT";
}
EOF

# Tạo trang web ngụy trang
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Server Status</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; line-height: 1.6; }
        .container { max-width: 800px; margin: 0 auto; padding: 20px; }
        .status { padding: 20px; background: #f5f5f5; border-radius: 5px; }
        .online { color: green; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Server Status</h1>
        <div class="status">
            <p>Status: <span class="online">Online</span></p>
            <p>Server ID: $TAG</p>
            <p>Last updated: $(date)</p>
        </div>
    </div>
</body>
</html>
EOF

# Công cụ kiểm tra IP
cat > /var/www/html/check-ip.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>IP Checker</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; line-height: 1.6; text-align: center; }
        .container { max-width: 600px; margin: 0 auto; padding: 20px; }
        .result { padding: 15px; background: #f5f5f5; border-radius: 5px; margin-top: 20px; }
        button { padding: 10px 20px; background: #4CAF50; color: white; border: none; cursor: pointer; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Kiểm tra IP</h1>
        <p>Click vào nút bên dưới để kiểm tra IP công khai của bạn</p>
        <button onclick="checkIP()">Kiểm tra IP</button>
        <div id="result" class="result">Kết quả sẽ hiển thị ở đây</div>
    </div>
    <script>
        function checkIP() {
            document.getElementById('result').innerText = 'Đang kiểm tra...';
            fetch('/ip')
                .then(response => response.text())
                .then(data => {
                    document.getElementById('result').innerText = 'IP của bạn: ' + data;
                })
                .catch(error => {
                    document.getElementById('result').innerText = 'Lỗi khi kiểm tra IP: ' + error;
                });
        }
    </script>
</body>
</html>
EOF

#############################################
# PHẦN 5: CÔNG CỤ KIỂM TRA VÀ KHỞI ĐỘNG DỊCH VỤ
#############################################

echo -e "${GREEN}[5/5] Thiết lập công cụ kiểm tra và khởi động dịch vụ...${NC}"

# Tạo script kiểm tra kết nối
cat > /usr/local/bin/check-proxy.sh << EOF
#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}====== KIỂM TRA PROXY V2RAY ======${NC}"

# Kiểm tra dịch vụ
echo -e "\n${YELLOW}Kiểm tra trạng thái dịch vụ:${NC}"
systemctl status v2ray --no-pager | grep Active || echo -e "${RED}V2Ray không chạy!${NC}"
systemctl status nginx --no-pager | grep Active || echo -e "${RED}Nginx không chạy!${NC}"

# Kiểm tra các cổng đang lắng nghe
echo -e "\n${YELLOW}Cổng đang lắng nghe:${NC}"
netstat -tuln | grep -E "$HTTP_PROXY_PORT|$SOCKS_PROXY_PORT|$V2RAY_PORT|80" || echo -e "${RED}Không tìm thấy cổng nào!${NC}"

# Kiểm tra kết nối HTTP proxy
echo -e "\n${YELLOW}Kiểm tra kết nối HTTP proxy:${NC}"
curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://ipinfo.io/ip || echo -e "${RED}HTTP proxy không hoạt động!${NC}"

# Kiểm tra kết nối SOCKS proxy
echo -e "\n${YELLOW}Kiểm tra kết nối SOCKS proxy:${NC}"
curl -s --socks5 127.0.0.1:$SOCKS_PROXY_PORT https://ipinfo.io/ip || echo -e "${RED}SOCKS proxy không hoạt động!${NC}"

# Kiểm tra kết nối trực tiếp để so sánh
echo -e "\n${YELLOW}Kiểm tra IP trực tiếp (không qua proxy):${NC}"
curl -s https://ipinfo.io/ip

echo -e "\n${YELLOW}Kết luận:${NC}"
IP_PROXY=\$(curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://ipinfo.io/ip)
IP_DIRECT=\$(curl -s https://ipinfo.io/ip)

if [ "\$IP_PROXY" = "\$IP_DIRECT" ]; then
  echo -e "${RED}CHÚ Ý: IP qua proxy và IP trực tiếp GIỐNG NHAU! Proxy không hoạt động đúng cách!${NC}"
else
  echo -e "${GREEN}IP qua proxy và IP trực tiếp KHÁC NHAU. Proxy đang hoạt động tốt!${NC}"
fi

# Kiểm tra DNS leak
echo -e "\n${YELLOW}Kiểm tra DNS leak:${NC}"
echo -e "Trực tiếp:"
dig +short whoami.akamai.net || echo "Không thể thực hiện kiểm tra DNS"
echo -e "Qua proxy:"
curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://dnsleaktest.com/what-is-my-dns-server.html | grep -o 'Your DNS servers:[^<]*' || echo "Không thể kiểm tra DNS qua proxy"
EOF
chmod +x /usr/local/bin/check-proxy.sh

# Tạo script khởi động lại
cat > /usr/local/bin/restart-proxy.sh << EOF
#!/bin/bash
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "\${GREEN}Khởi động lại tất cả dịch vụ proxy...${NC}"
systemctl restart v2ray
systemctl restart nginx
echo -e "\${GREEN}Đã khởi động lại dịch vụ. Kiểm tra trạng thái...${NC}"
systemctl status v2ray --no-pager | grep Active
systemctl status nginx --no-pager | grep Active
EOF
chmod +x /usr/local/bin/restart-proxy.sh

# Thiết lập định kỳ kiểm tra và khởi động lại
(crontab -l 2>/dev/null || echo "") | {
    cat
    echo "*/10 * * * * /usr/local/bin/check-proxy.sh > /var/log/proxy-check.log 2>&1" # Kiểm tra 10 phút một lần
    echo "0 */2 * * * /usr/local/bin/restart-proxy.sh > /dev/null 2>&1"  # Khởi động lại mỗi 2 giờ
} | crontab -

# Khởi động dịch vụ
systemctl daemon-reload
systemctl enable v2ray
systemctl enable nginx
systemctl restart v2ray
systemctl restart nginx

# Tạo URL chia sẻ V2Ray
V2RAY_CONFIG=$(cat <<EOF
{
  "v": "2",
  "ps": "V2Ray-WebSocket-$TAG",
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

# Kiểm tra kết nối proxy
sleep 3
IP_PROXY=$(curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://ipinfo.io/ip)
IP_DIRECT=$(curl -s https://ipinfo.io/ip)

# Hiển thị thông tin kết nối
echo -e "\n${BLUE}========================================================${NC}"
echo -e "${GREEN}CẤU HÌNH HTTP PROXY QUA V2RAY HOÀN TẤT${NC}"
echo -e "${BLUE}========================================================${NC}"

echo -e "\n${YELLOW}THÔNG TIN KẾT NỐI:${NC}"
echo -e "HTTP Proxy: ${GREEN}$PUBLIC_IP:$HTTP_PROXY_PORT${NC}"
echo -e "SOCKS Proxy: ${GREEN}$PUBLIC_IP:$SOCKS_PROXY_PORT${NC}"
echo -e "PAC URL: ${GREEN}http://$PUBLIC_IP/proxy/proxy.pac${NC}"
echo -e "Trang kiểm tra IP: ${GREEN}http://$PUBLIC_IP/check-ip.html${NC}"

echo -e "\n${YELLOW}URL V2RAY (cho ứng dụng):${NC}"
echo -e "${GREEN}$V2RAY_LINK${NC}"

echo -e "\n${YELLOW}KIỂM TRA KẾT NỐI:${NC}"
if [ "$IP_PROXY" = "$IP_DIRECT" ]; then
  echo -e "${RED}CHÚ Ý: IP qua proxy và IP trực tiếp GIỐNG NHAU!${NC}"
  echo -e "${YELLOW}Proxy có thể chưa hoạt động đúng cách. Vui lòng chạy:${NC} sudo /usr/local/bin/check-proxy.sh"
else
  echo -e "${GREEN}IP qua proxy: $IP_PROXY${NC}"
  echo -e "${GREEN}IP trực tiếp: $IP_DIRECT${NC}"
  echo -e "${GREEN}HTTP Proxy đang hoạt động tốt!${NC}"
fi

echo -e "\n${YELLOW}HƯỚNG DẪN CẤU HÌNH IPHONE:${NC}"
echo -e "1. Vào Settings > Wi-Fi > [Mạng Wi-Fi] > Configure Proxy > Auto"
echo -e "2. URL: ${GREEN}http://$PUBLIC_IP/proxy/proxy.pac${NC}"
echo -e "3. Hoặc cấu hình thủ công:"
echo -e "   Server: ${GREEN}$PUBLIC_IP${NC}"
echo -e "   Port: ${GREEN}$HTTP_PROXY_PORT${NC}"

echo -e "\n${YELLOW}QUẢN LÝ HỆ THỐNG:${NC}"
echo -e "Kiểm tra: ${GREEN}sudo /usr/local/bin/check-proxy.sh${NC}"
echo -e "Khởi động lại: ${GREEN}sudo /usr/local/bin/restart-proxy.sh${NC}"

echo -e "\n${YELLOW}KIỂM TRA IP SAU KHI CẤU HÌNH:${NC}"
echo -e "Truy cập: ${GREEN}http://$PUBLIC_IP/check-ip.html${NC} trên thiết bị của bạn"
echo -e "${BLUE}========================================================${NC}"

# Chạy kiểm tra chi tiết
echo -e "\n${YELLOW}Chạy kiểm tra chi tiết để xác minh cài đặt:${NC}"
/usr/local/bin/check-proxy.sh
