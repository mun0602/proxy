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

echo -e "${BLUE}=== HTTP BRIDGE QUA GIAO THỨC PROXY HIỆN ĐẠI ====${NC}"

# Lấy địa chỉ IP công cộng
PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || curl -s https://api.ipify.org || curl -s https://ifconfig.me)
if [ -z "$PUBLIC_IP" ]; then
  echo -e "${YELLOW}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
  PUBLIC_IP=$(hostname -I | awk '{print $1}')
fi

# Thông số cấu hình
HTTP_PROXY_PORT=8118
VMESS_PORT=10086
TROJAN_PORT=443
VLESS_PORT=8443
UUID=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 36 | head -n 1)
TROJAN_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
WS_PATH="/$(head /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)"
TAG="ProxyV2-$(date +%s)"

# Yêu cầu người dùng chọn giao thức
echo -e "${YELLOW}Chọn giao thức proxy hiện đại để bridge:${NC}"
echo -e "1) VMess WebSocket (che giấu tốt, tương thích rộng rãi)"
echo -e "2) Trojan (ngụy trang là HTTPS, bảo mật cao)"
echo -e "3) VLESS + Reality (công nghệ ngụy trang mới nhất, không cần SSL)"
read -p "Lựa chọn của bạn (mặc định: 1): " PROTOCOL_CHOICE
PROTOCOL_CHOICE=${PROTOCOL_CHOICE:-1}

# Cấu hình thông số theo giao thức được chọn
case $PROTOCOL_CHOICE in
  1)
    PROTOCOL="VMess"
    PROTOCOL_PORT=$VMESS_PORT
    ;;
  2)
    PROTOCOL="Trojan"
    PROTOCOL_PORT=$TROJAN_PORT
    ;;
  3)
    PROTOCOL="VLESS"
    PROTOCOL_PORT=$VLESS_PORT
    ;;
  *)
    echo -e "${RED}Lựa chọn không hợp lệ, sử dụng VMess mặc định${NC}"
    PROTOCOL="VMess"
    PROTOCOL_PORT=$VMESS_PORT
    ;;
esac

echo -e "${GREEN}Đã chọn giao thức: $PROTOCOL trên cổng $PROTOCOL_PORT${NC}"

#############################################
# PHẦN 1: DỪNG DỊCH VỤ CŨ
#############################################

echo -e "${GREEN}[1/6] Dừng dịch vụ cũ...${NC}"

# Dừng các dịch vụ nếu tồn tại
for service in v2ray v2ray-client v2ray-server xray xray-server xray-client tinyproxy gost-bridge ss-local shadowsocks-libev; do
  if systemctl list-unit-files | grep -q $service; then
    systemctl stop $service 2>/dev/null
    systemctl disable $service 2>/dev/null
  fi
done

#############################################
# PHẦN 2: CÀI ĐẶT CÁC GÓI CẦN THIẾT
#############################################

echo -e "${GREEN}[2/6] Cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y nginx curl wget unzip tinyproxy net-tools dnsutils iptables-persistent mtr traceroute jq cron socat lsof tar

# Tạo 2GB swap nếu chưa có
if [ "$(free | grep -c Swap)" -eq 0 ] || [ "$(free | grep Swap | awk '{print $2}')" -lt 1000000 ]; then
    echo -e "${YELLOW}Tạo 2GB RAM ảo (swap)...${NC}"
    swapoff -a &>/dev/null
    rm -f /swapfile
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    fi
    echo 10 > /proc/sys/vm/swappiness
fi

#############################################
# PHẦN 3: CÀI ĐẶT XRAY/TINYPROXY
#############################################

echo -e "${GREEN}[3/6] Cài đặt Xray và Tinyproxy...${NC}"

# Cấu hình Tinyproxy
cat > /etc/tinyproxy/tinyproxy.conf << EOF
User nobody
Group nogroup
Port $HTTP_PROXY_PORT
Timeout 600
DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"
LogFile "/var/log/tinyproxy/tinyproxy.log"
LogLevel Info
PidFile "/run/tinyproxy/tinyproxy.pid"
MaxClients 1000
MinSpareServers 5
MaxSpareServers 20
StartServers 10
MaxRequestsPerChild 0
DisableViaHeader Yes

# Cho phép tất cả các kết nối
Allow 0.0.0.0/0

# Kết nối đến localhost qua SOCKS
Upstream socks5 127.0.0.1:1080
EOF

# Cài đặt Xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Tạo thư mục cấu hình
mkdir -p /usr/local/etc/xray
mkdir -p /usr/local/share/xray
mkdir -p /var/log/xray/

# Cấu hình Xray dựa trên giao thức được chọn
case $PROTOCOL_CHOICE in
  1)
    # VMess WebSocket
    cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 1080,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "udp": true,
        "auth": "noauth"
      },
      "tag": "socks-in"
    },
    {
      "port": $VMESS_PORT,
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
        }
      },
      "tag": "vmess-in"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
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
    "rules": [
      {
        "type": "field",
        "inboundTag": ["socks-in", "vmess-in"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF
    ;;
  2)
    # Trojan
    # Tạo SSL tự ký (sẽ yêu cầu người dùng cung cấp domain và cài đặt Let's Encrypt nếu cần)
    mkdir -p /etc/ssl/xray
    openssl req -x509 -nodes -days 365 -newkey rsa:3072 \
    -keyout /etc/ssl/xray/xray.key -out /etc/ssl/xray/xray.crt \
    -subj "/CN=$PUBLIC_IP" -addext "subjectAltName=IP:$PUBLIC_IP"
    
    cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 1080,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "udp": true,
        "auth": "noauth"
      },
      "tag": "socks-in"
    },
    {
      "port": $TROJAN_PORT,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "$TROJAN_PASSWORD"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "certificates": [
            {
              "certificateFile": "/etc/ssl/xray/xray.crt",
              "keyFile": "/etc/ssl/xray/xray.key"
            }
          ]
        }
      },
      "tag": "trojan-in"
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
    "rules": [
      {
        "type": "field",
        "inboundTag": ["socks-in", "trojan-in"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF
    ;;
  3)
    # VLESS + Reality (giao thức hiện đại nhất)
    # Tạo private key và public key cho Reality
    REALITY_PRIVATE_KEY=$(xray x25519)
    REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY#Private key: }
    REALITY_PUBLIC_KEY=${REALITY_PRIVATE_KEY#Public key: }
    
    # Chọn serverName ngẫu nhiên từ các trang web phổ biến
    SERVER_NAMES=("www.microsoft.com" "www.amazon.com" "www.cloudflare.com" "www.apple.com" "www.google.com")
    RANDOM_INDEX=$((RANDOM % ${#SERVER_NAMES[@]}))
    SERVER_NAME=${SERVER_NAMES[$RANDOM_INDEX]}
    
    # Tạo short ID ngẫu nhiên
    SHORT_ID=$(openssl rand -hex 8)
    
    cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 1080,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "udp": true,
        "auth": "noauth"
      },
      "tag": "socks-in"
    },
    {
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SERVER_NAME:443",
          "serverNames": [
            "$SERVER_NAME"
          ],
          "privateKey": "$REALITY_PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "tag": "vless-in"
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
    "rules": [
      {
        "type": "field",
        "inboundTag": ["socks-in", "vless-in"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF
    ;;
esac

#############################################
# PHẦN 4: CẤU HÌNH NGINX
#############################################

echo -e "${GREEN}[4/6] Cấu hình Nginx...${NC}"

# Cấu hình nginx
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
if [ "$PROTOCOL" = "VMess" ]; then
    # Cấu hình cho VMess Websocket
    cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $PUBLIC_IP;
    
    # Ngụy trang là một trang web bình thường
    location / {
        root /var/www/html;
        index index.html check-ip.html;
    }
    
    # Định tuyến WebSocket đến Xray
    location $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$VMESS_PORT;
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
else
    # Cấu hình đơn giản cho Trojan và VLESS (không cần websocket)
    cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $PUBLIC_IP;
    
    # Ngụy trang là một trang web bình thường
    location / {
        root /var/www/html;
        index index.html check-ip.html;
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
fi

# Tạo thư mục và PAC file
mkdir -p /var/www/html/proxy
cat > /var/www/html/proxy/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Bỏ qua các địa chỉ IP nội bộ
    if (isPlainHostName(host) || 
        isInNet(host, "10.0.0.0", "255.0.0.0") ||
        isInNet(host, "172.16.0.0", "255.240.0.0") ||
        isInNet(host, "192.168.0.0", "255.255.0.0") ||
        isInNet(host, "127.0.0.0", "255.0.0.0")) {
        return "DIRECT";
    }
    
    // TẤT CẢ kết nối khác đi qua proxy
    return "PROXY $PUBLIC_IP:$HTTP_PROXY_PORT";
}
EOF

# Tạo trang web kiểm tra IP
cat > /var/www/html/check-ip.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Kiểm tra Proxy</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { font-family: Arial, sans-serif; text-align: center; margin: 20px; line-height: 1.6; }
        .container { max-width: 800px; margin: 0 auto; }
        .result-box { background: #f5f5f5; border-radius: 5px; padding: 15px; margin: 20px 0; }
        .success { color: green; }
        .error { color: red; }
        button { background: #4CAF50; color: white; border: none; padding: 10px 20px; cursor: pointer; border-radius: 4px; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        table, th, td { border: 1px solid #ddd; }
        th, td { padding: 10px; text-align: left; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Kiểm tra HTTP Bridge qua $PROTOCOL</h1>
        <p>Công cụ này sẽ kiểm tra xem kết nối proxy của bạn có hoạt động đúng cách không</p>
        
        <button onclick="checkIP()">Kiểm tra IP</button>
        
        <div id="result" class="result-box">
            <p>Nhấn nút kiểm tra để xem IP của bạn</p>
        </div>
        
        <div id="info">
            <h2>Thông tin cấu hình</h2>
            <table>
                <tr>
                    <th>Giao thức Bridge</th>
                    <td>HTTP Bridge qua $PROTOCOL</td>
                </tr>
                <tr>
                    <th>HTTP Proxy</th>
                    <td>$PUBLIC_IP:$HTTP_PROXY_PORT</td>
                </tr>
                <tr>
                    <th>PAC URL</th>
                    <td>http://$PUBLIC_IP/proxy/proxy.pac</td>
                </tr>
            </table>
        </div>

        <div class="result-box">
            <h2>Kiểm tra DNS Leak</h2>
            <p>Nếu trang web dnsleaktest.com hiển thị IP của proxy thay vì IP thật, bạn đã cấu hình thành công!</p>
            <button onclick="window.open('https://dnsleaktest.com', '_blank')">Kiểm tra DNS Leak</button>
        </div>
    </div>
    
    <script>
        function checkIP() {
            document.getElementById('result').innerHTML = '<p>Đang kiểm tra IP...</p>';
            
            fetch('/ip')
                .then(response => response.text())
                .then(data => {
                    document.getElementById('result').innerHTML = 
                        '<p>IP hiện tại của bạn: <strong>' + data + '</strong></p>' +
                        '<p class="success">✅ Nếu IP này khác với IP thật của bạn, proxy đang hoạt động tốt!</p>';
                })
                .catch(error => {
                    document.getElementById('result').innerHTML = 
                        '<p class="error">Lỗi khi kiểm tra IP: ' + error + '</p>';
                });
        }
    </script>
</body>
</html>
EOF

# Tạo trang web ngụy trang
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Network Tools</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 0; line-height: 1.6; }
        .header { background: linear-gradient(135deg, #007bff, #6610f2); color: white; padding: 40px 0; text-align: center; }
        .container { max-width: 1000px; margin: 0 auto; padding: 20px; }
        .card { background: white; border-radius: 5px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); margin: 20px 0; padding: 20px; }
        .tool-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 20px; }
        .tool-item { background: #f8f9fa; padding: 20px; border-radius: 5px; text-align: center; }
        .tool-item h3 { margin-top: 0; }
        .button { background: #007bff; color: white; text-decoration: none; padding: 8px 16px; border-radius: 4px; display: inline-block; margin-top: 10px; }
        .footer { background: #333; color: white; text-align: center; padding: 20px 0; margin-top: 40px; }
    </style>
</head>
<body>
    <div class="header">
        <div class="container">
            <h1>Network Tools</h1>
            <p>Công cụ kiểm tra và phân tích mạng</p>
        </div>
    </div>
    
    <div class="container">
        <div class="card">
            <h2>Công cụ phổ biến</h2>
            <div class="tool-grid">
                <div class="tool-item">
                    <h3>Kiểm tra IP</h3>
                    <p>Xem địa chỉ IP công khai của bạn</p>
                    <a href="/check-ip.html" class="button">Sử dụng</a>
                </div>
                <div class="tool-item">
                    <h3>Speed Test</h3>
                    <p>Kiểm tra tốc độ kết nối</p>
                    <a href="https://www.speedtest.net/" class="button">Sử dụng</a>
                </div>
                <div class="tool-item">
                    <h3>DNS Leak Test</h3>
                    <p>Kiểm tra rò rỉ DNS</p>
                    <a href="https://dnsleaktest.com/" class="button">Sử dụng</a>
                </div>
                <div class="tool-item">
                    <h3>Traceroute</h3>
                    <p>Theo dõi đường dẫn mạng</p>
                    <a href="https://ping.eu/traceroute/" class="button">Sử dụng</a>
                </div>
            </div>
        </div>
    </div>
    
    <div class="footer">
        <div class="container">
            <p>&copy; 2025 Network Tools. All rights reserved.</p>
        </div>
    </div>
</body>
</html>
EOF

#############################################
# PHẦN 5: TẠO SCRIPT KIỂM TRA VÀ KHỞI ĐỘNG DỊCH VỤ
#############################################

echo -e "${GREEN}[5/6] Tạo script kiểm tra và khởi động dịch vụ...${NC}"

# Tạo script kiểm tra kết nối
cat > /usr/local/bin/check-proxy.sh << EOF
#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}====== KIỂM TRA HTTP BRIDGE QUA $PROTOCOL ======${NC}"

# Kiểm tra dịch vụ
echo -e "\n${YELLOW}Kiểm tra trạng thái dịch vụ:${NC}"
systemctl status tinyproxy --no-pager | grep Active || echo -e "${RED}Tinyproxy không chạy!${NC}"
systemctl status xray --no-pager | grep Active || echo -e "${RED}Xray không chạy!${NC}"
systemctl status nginx --no-pager | grep Active || echo -e "${RED}Nginx không chạy!${NC}"

# Kiểm tra các cổng đang lắng nghe
echo -e "\n${YELLOW}Cổng đang lắng nghe:${NC}"
netstat -tuln | grep -E "$HTTP_PROXY_PORT|1080|$PROTOCOL_PORT|80" || echo -e "${RED}Không tìm thấy cổng nào!${NC}"

# Kiểm tra kết nối HTTP proxy
echo -e "\n${YELLOW}Kiểm tra kết nối HTTP proxy:${NC}"
curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://ipinfo.io/ip || echo -e "${RED}HTTP proxy không hoạt động!${NC}"

# Kiểm tra kết nối SOCKS proxy
echo -e "\n${YELLOW}Kiểm tra kết nối SOCKS proxy:${NC}"
curl -s --socks5 127.0.0.1:1080 https://ipinfo.io/ip || echo -e "${RED}SOCKS proxy không hoạt động!${NC}"

# Kiểm tra kết nối trực tiếp để so sánh
echo -e "\n${YELLOW}Kiểm tra IP trực tiếp (không qua proxy):${NC}"
curl -s https://ipinfo.io/ip

echo -e "\n${YELLOW}Kết luận:${NC}"
IP_PROXY=\$(curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://ipinfo.io/ip)
IP_DIRECT=\$(curl -s https://ipinfo.io/ip)

if [ "\$IP_PROXY" = "\$IP_DIRECT" ]; then
  echo -e "${RED}CHÚ Ý: IP qua proxy và IP trực tiếp GIỐNG NHAU! Proxy không hoạt động đúng cách!${NC}"
else
  echo -e "${GREEN}IP qua proxy và IP trực tiếp KHÁC NHAU. HTTP Bridge qua $PROTOCOL đang hoạt động tốt!${NC}"
fi

# Kiểm tra DNS leak
echo -e "\n${YELLOW}Kiểm tra DNS:${NC}"
curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://dnsleaktest.com/ | grep -o "Your IP address is:.*" || echo "Không thể kiểm tra DNS"

# Kiểm tra tốc độ proxy
echo -e "\n${YELLOW}Kiểm tra tốc độ proxy:${NC}"
time curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://speed.hetzner.de/10MB.bin -o /dev/null || echo -e "${RED}Kiểm tra tốc độ thất bại!${NC}"
EOF
chmod +x /usr/local/bin/check-proxy.sh

# Tạo script khởi động lại
cat > /usr/local/bin/restart-proxy.sh << EOF
#!/bin/bash
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "\${GREEN}Khởi động lại tất cả dịch vụ proxy...${NC}"
systemctl restart tinyproxy
systemctl restart xray
systemctl restart nginx
echo -e "\${GREEN}Đã khởi động lại dịch vụ.${NC}"
EOF
chmod +x /usr/local/bin/restart-proxy.sh

# Tạo script sửa tự động
cat > /usr/local/bin/auto-fix-proxy.sh << EOF
#!/bin/bash
LOG="/var/log/proxy-check.log"
echo "Kiểm tra proxy tự động lúc \$(date)" >> \$LOG

# Kiểm tra HTTP proxy
if ! curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://www.google.com -o /dev/null; then
    echo "HTTP proxy không hoạt động, khởi động lại Tinyproxy" >> \$LOG
    systemctl restart tinyproxy
fi

# Kiểm tra SOCKS proxy (từ Xray)
if ! curl -s --socks5 127.0.0.1:1080 https://www.google.com -o /dev/null; then
    echo "SOCKS proxy không hoạt động, khởi động lại Xray" >> \$LOG
    systemctl restart xray
fi

# Kiểm tra Nginx
if ! curl -s http://127.0.0.1 -o /dev/null; then
    echo "Nginx không hoạt động, khởi động lại" >> \$LOG
    systemctl restart nginx
fi

# Kiểm tra kết nối sau khi sửa
if curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://www.google.com -o /dev/null; then
    echo "Kiểm tra OK: HTTP proxy hoạt động" >> \$LOG
else
    echo "QUAN TRỌNG: HTTP proxy vẫn không hoạt động sau khi khởi động lại" >> \$LOG
    /usr/local/bin/restart-proxy.sh >> \$LOG
fi
EOF
chmod +x /usr/local/bin/auto-fix-proxy.sh

# Thiết lập định kỳ kiểm tra và khởi động lại
(crontab -l 2>/dev/null || echo "") | {
    cat
    echo "*/5 * * * * /usr/local/bin/auto-fix-proxy.sh > /dev/null 2>&1"
    echo "0 */3 * * * /usr/local/bin/restart-proxy.sh > /dev/null 2>&1"
} | crontab -

#############################################
# PHẦN 6: KHỞI ĐỘNG DỊCH VỤ VÀ HIỂN THỊ THÔNG TIN
#############################################

echo -e "${GREEN}[6/6] Khởi động dịch vụ và hiển thị thông tin...${NC}"

# Khởi động dịch vụ
systemctl daemon-reload
systemctl enable tinyproxy
systemctl enable xray
systemctl enable nginx
systemctl restart tinyproxy
systemctl restart xray
systemctl restart nginx

# Chờ dịch vụ khởi động
sleep 5

# Kiểm tra kết nối proxy
IP_PROXY=$(curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://ipinfo.io/ip)
IP_DIRECT=$(curl -s https://ipinfo.io/ip)

# Tạo thông tin kết nối cho client dựa trên giao thức được chọn
case $PROTOCOL_CHOICE in
  1)
    # VMess WebSocket
    VMESS_CONFIG=$(cat <<EOF
{
  "v": "2",
  "ps": "HTTP-Bridge-VMess-$TAG",
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
    SHARE_LINK="vmess://$(echo $VMESS_CONFIG | jq -c . | base64 -w 0)"
    CLIENT_INFO="VMess:\n  - Address: ${PUBLIC_IP}\n  - Port: 80\n  - UUID: ${UUID}\n  - Network: WebSocket\n  - Path: ${WS_PATH}"
    ;;
  2)
    # Trojan
    SHARE_LINK="trojan://${TROJAN_PASSWORD}@${PUBLIC_IP}:${TROJAN_PORT}"
    CLIENT_INFO="Trojan:\n  - Address: ${PUBLIC_IP}\n  - Port: ${TROJAN_PORT}\n  - Password: ${TROJAN_PASSWORD}"
    ;;
  3)
    # VLESS + Reality
    SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${VLESS_PORT}?security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#HTTP-Bridge-VLESS-${TAG}"
    CLIENT_INFO="VLESS Reality:\n  - Address: ${PUBLIC_IP}\n  - Port: ${VLESS_PORT}\n  - UUID: ${UUID}\n  - SNI: ${SERVER_NAME}\n  - Public Key: ${REALITY_PUBLIC_KEY}\n  - Short ID: ${SHORT_ID}"
    ;;
esac

# Hiển thị thông tin kết nối
echo -e "\n${BLUE}========================================================${NC}"
echo -e "${GREEN}HTTP BRIDGE QUA $PROTOCOL ĐÃ ĐƯỢC THIẾT LẬP${NC}"
echo -e "${BLUE}========================================================${NC}"

echo -e "\n${YELLOW}THÔNG TIN KẾT NỐI HTTP PROXY:${NC}"
echo -e "HTTP Proxy: ${GREEN}$PUBLIC_IP:$HTTP_PROXY_PORT${NC}"
echo -e "PAC URL: ${GREEN}http://$PUBLIC_IP/proxy/proxy.pac${NC}"
echo -e "Trang kiểm tra IP: ${GREEN}http://$PUBLIC_IP/check-ip.html${NC}"

echo -e "\n${YELLOW}THÔNG TIN CLIENT $PROTOCOL:${NC}"
echo -e "${GREEN}$CLIENT_INFO${NC}"

echo -e "\n${YELLOW}URL CHIA SẺ:${NC}"
echo -e "${GREEN}$SHARE_LINK${NC}"

echo -e "\n${YELLOW}KIỂM TRA KẾT NỐI:${NC}"
if [ "$IP_PROXY" = "$IP_DIRECT" ]; then
  echo -e "${RED}CHÚ Ý: IP qua proxy và IP trực tiếp GIỐNG NHAU!${NC}"
  echo -e "${YELLOW}Vui lòng chạy:${NC} sudo /usr/local/bin/check-proxy.sh"
else
  echo -e "${GREEN}IP qua proxy: $IP_PROXY${NC}"
  echo -e "${GREEN}IP trực tiếp: $IP_DIRECT${NC}"
  echo -e "${GREEN}HTTP Bridge qua $PROTOCOL đang hoạt động tốt!${NC}"
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
echo -e "Truy cập: ${GREEN}http://$PUBLIC_IP/check-ip.html${NC} trên iPhone của bạn"
echo -e "${BLUE}========================================================${NC}"

# Lưu thông tin cấu hình
mkdir -p /etc/proxy-setup
cat > /etc/proxy-setup/config.json << EOF
{
  "protocol": "$PROTOCOL",
  "protocol_port": $PROTOCOL_PORT,
  "http_proxy_port": $HTTP_PROXY_PORT,
  "uuid": "$UUID",
  "share_link": "$SHARE_LINK",
  "public_ip": "$PUBLIC_IP",
  "installation_date": "$(date)",
  "version": "1.0.0"
}
EOF
chmod 600 /etc/proxy-setup/config.json

# Chạy kiểm tra chi tiết
echo -e "\n${YELLOW}Đang chạy kiểm tra chi tiết để xác minh cài đặt:${NC}"
/usr/local/bin/check-proxy.sh
