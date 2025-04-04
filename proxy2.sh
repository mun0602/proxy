#!/bin/bash

# Giải pháp tối ưu: V2Ray WebSocket + TLS
# Kết hợp HTTP Bridge để sử dụng trên iPhone không cần cài app

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

# Hàm lấy địa chỉ IP công cộng
get_public_ip() {
  PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || 
              curl -s https://api.ipify.org || 
              curl -s https://ifconfig.me)

  if [ -z "$PUBLIC_IP" ]; then
    echo -e "${YELLOW}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
    PUBLIC_IP=$(hostname -I | awk '{print $1}')
  fi
}

# Tạo tên miền giả dựa trên IP để cải thiện ngụy trang
generate_fake_domain() {
  # Sử dụng IP với định dạng xxx-xxx-xxx-xxx.ip.feisu.best
  IP_PARTS=$(echo $PUBLIC_IP | tr '.' '-')
  FAKE_DOMAIN="${IP_PARTS}.ip.feisu.best"
  echo $FAKE_DOMAIN
}

# Tạo UUID ngẫu nhiên
UUID=$(cat /proc/sys/kernel/random/uuid)
DOMAIN=""
FAKE_DOMAIN=""
WS_PATH="/$(head /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)"
HTTP_BRIDGE_PORT=8118
GOST_PORT=1080

# Cài đặt các gói cần thiết
echo -e "${GREEN}Đang cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y nginx curl wget unzip socat cron certbot python3-certbot-nginx ufw jq

# Dừng các dịch vụ hiện có
systemctl stop nginx 2>/dev/null

# Tải và cài đặt GOST (HTTP->SOCKS Bridge ổn định hơn Privoxy)
echo -e "${GREEN}Đang cài đặt GOST cho HTTP Bridge...${NC}"
mkdir -p /tmp/gost
cd /tmp/gost
wget https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
gunzip gost-linux-amd64-2.11.5.gz
mv gost-linux-amd64-2.11.5 /usr/local/bin/gost
chmod +x /usr/local/bin/gost

# Hỏi người dùng có tên miền không
echo -e "${YELLOW}Bạn có tên miền không? Nếu có, V2Ray sẽ an toàn hơn với chứng chỉ SSL chính thức.${NC}"
read -p "Nhập tên miền của bạn (hoặc để trống để sử dụng IP): " DOMAIN_INPUT

if [ -z "$DOMAIN_INPUT" ]; then
    echo -e "${YELLOW}Sử dụng IP với tên miền giả để ngụy trang.${NC}"
    get_public_ip
    FAKE_DOMAIN=$(generate_fake_domain)
    DOMAIN=$PUBLIC_IP
    USE_IP=true
else
    DOMAIN=$DOMAIN_INPUT
    USE_IP=false
    
    # Kiểm tra DNS của tên miền trỏ đến IP của máy chủ
    get_public_ip
    DOMAIN_IP=$(dig +short $DOMAIN)
    
    if [ "$DOMAIN_IP" != "$PUBLIC_IP" ]; then
        echo -e "${RED}Cảnh báo: Tên miền $DOMAIN không trỏ đến IP máy chủ này ($PUBLIC_IP).${NC}"
        echo -e "${YELLOW}Đảm bảo bạn đã cấu hình DNS đúng trước khi tiếp tục.${NC}"
        read -p "Bạn có muốn tiếp tục không? (y/n): " CONTINUE
        if [[ $CONTINUE != "y" && $CONTINUE != "Y" ]]; then
            echo -e "${RED}Đã hủy cài đặt.${NC}"
            exit 1
        fi
    fi
fi

# Cài đặt V2Ray
echo -e "${GREEN}Đang cài đặt V2Ray...${NC}"
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

# Cấu hình tường lửa
echo -e "${GREEN}Cấu hình tường lửa...${NC}"
ufw allow ssh
ufw allow http
ufw allow https
ufw allow $HTTP_BRIDGE_PORT/tcp
ufw --force enable

# Cấu hình V2Ray
echo -e "${GREEN}Cấu hình V2Ray...${NC}"
cat > /usr/local/etc/v2ray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log"
  },
  "inbounds": [
    {
      "port": 10086,
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
      }
    },
    {
      "port": $GOST_PORT,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "udp": true
      },
      "tag": "socksIn"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "socksIn"
        ],
        "outboundTag": "freedom"
      }
    ]
  }
}
EOF

# Cấu hình GOST service
echo -e "${GREEN}Cấu hình GOST HTTP bridge...${NC}"
cat > /etc/systemd/system/gost-bridge.service << EOF
[Unit]
Description=GOST HTTP-SOCKS5 Bridge
After=network.target v2ray.service

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -L http://:$HTTP_BRIDGE_PORT -F socks5://127.0.0.1:$GOST_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Cấu hình Nginx
if [ "$USE_IP" = true ]; then
    # Sử dụng IP với TLS tự ký
    echo -e "${GREEN}Cấu hình Nginx với TLS tự ký...${NC}"
    
    # Tạo thư mục cho chứng chỉ SSL
    mkdir -p /etc/nginx/ssl
    
    # Tạo chứng chỉ tự ký
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/nginx.key \
        -out /etc/nginx/ssl/nginx.crt \
        -subj "/CN=$FAKE_DOMAIN" \
        -addext "subjectAltName=DNS:$FAKE_DOMAIN,IP:$PUBLIC_IP"
    
    # Cấu hình Nginx với TLS tự ký
    cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $PUBLIC_IP;
    
    # Chuyển hướng tất cả lưu lượng HTTP sang HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $PUBLIC_IP;
    
    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384;
    
    # Ngụy trang là một trang web bình thường
    location / {
        root /var/www/html;
        index index.html;
    }
    
    # Định tuyến WebSocket đến V2Ray
    location $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10086;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

else
    # Sử dụng tên miền với Let's Encrypt
    echo -e "${GREEN}Cấu hình Nginx với tên miền...${NC}"
    
    # Cấu hình Nginx ban đầu cho xác thực Let's Encrypt
    cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
    root /var/www/html;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    # Khởi động Nginx
    systemctl restart nginx
    
    # Lấy chứng chỉ SSL từ Let's Encrypt
    echo -e "${GREEN}Lấy chứng chỉ SSL từ Let's Encrypt...${NC}"
    certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN
    
    # Cấu hình Nginx với SSL và WebSocket
    cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
    # Chuyển hướng tất cả lưu lượng HTTP sang HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;
    
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384;
    
    # Ngụy trang là một trang web bình thường
    location / {
        root /var/www/html;
        index index.html;
    }
    
    # Định tuyến WebSocket đến V2Ray
    location $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10086;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

fi

# Tạo trang web ngụy trang
echo -e "${GREEN}Tạo trang web ngụy trang...${NC}"
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to My Website</title>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; line-height: 1.6; }
        h1 { color: #333; }
        .container { max-width: 800px; margin: 0 auto; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to My Website</h1>
        <p>This is a personal website about technology and programming.</p>
        <p>Feel free to explore and learn more about my projects.</p>
        
        <h2>Recent Posts</h2>
        <ul>
            <li>How to optimize your website performance</li>
            <li>The future of cloud computing</li>
            <li>Best practices for secure coding</li>
        </ul>
        
        <h2>Contact</h2>
        <p>You can reach me at: admin@example.com</p>
    </div>
</body>
</html>
EOF

# Tạo PAC file cho iPhone
echo -e "${GREEN}Tạo PAC file cho iPhone...${NC}"
mkdir -p /var/www/html/proxy
cat > /var/www/html/proxy/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Các domain cần dùng proxy
    var cn_domains = [
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
        
        // IP/Speed checking
        ".ipleak.net",
        ".speedtest.net",
        ".fast.com"
    ];
    
    // Kiểm tra IP trong dải Trung Quốc
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
        return "PROXY $PUBLIC_IP:$HTTP_BRIDGE_PORT";
    }
    
    // Kiểm tra domain trong danh sách
    for (var i = 0; i < cn_domains.length; i++) {
        if (dnsDomainIs(host, cn_domains[i]) || 
            shExpMatch(host, "*" + cn_domains[i] + "*")) {
            return "PROXY $PUBLIC_IP:$HTTP_BRIDGE_PORT";
        }
    }
    
    // Mặc định truy cập trực tiếp
    return "DIRECT";
}
EOF

# Thêm cấu hình Nginx cho PAC file
sed -i "/location \/ {/i \    location \/proxy\/ {\n        types { }\n        default_type application\/x-ns-proxy-autoconfig;\n    }" /etc/nginx/sites-available/default

# Khởi động tất cả dịch vụ
echo -e "${GREEN}Khởi động dịch vụ...${NC}"
systemctl daemon-reload
systemctl enable v2ray
systemctl enable gost-bridge
systemctl enable nginx
systemctl restart v2ray
systemctl restart gost-bridge
systemctl restart nginx

# Tạo thông tin kết nối cho client
if [ "$USE_IP" = true ]; then
    DOMAIN_OR_IP="$PUBLIC_IP"
    # Sử dụng FAKE_DOMAIN để có hiệu ứng ngụy trang tốt hơn trong client
    V2RAY_HOST=$FAKE_DOMAIN
else
    DOMAIN_OR_IP="$DOMAIN"
    V2RAY_HOST=$DOMAIN
fi

# Tạo cấu hình V2Ray client
V2RAY_CONFIG=$(cat <<EOF
{
  "v": "2",
  "ps": "V2Ray-WebSocket-TLS",
  "add": "$DOMAIN_OR_IP",
  "port": "443",
  "id": "$UUID",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "$V2RAY_HOST",
  "path": "$WS_PATH",
  "tls": "tls",
  "sni": "$V2RAY_HOST"
}
EOF
)

# Tạo URL chia sẻ V2Ray
V2RAY_LINK="vmess://$(echo $V2RAY_CONFIG | jq -c . | base64 -w 0)"

# Tạo QR code cho cấu hình nếu qrencode đã cài đặt
if command -v qrencode > /dev/null; then
    qrencode -t ANSIUTF8 -o - "$V2RAY_LINK"
elif command -v apt > /dev/null; then
    apt install -y qrencode > /dev/null 2>&1
    qrencode -t ANSIUTF8 -o - "$V2RAY_LINK"
fi

# Tạo script khởi động lại dịch vụ
cat > /usr/local/bin/restart-v2ray-services.sh << EOF
#!/bin/bash
systemctl restart v2ray
systemctl restart gost-bridge
systemctl restart nginx
echo "Tất cả dịch vụ đã được khởi động lại."
EOF
chmod +x /usr/local/bin/restart-v2ray-services.sh

# Tạo script kiểm tra
cat > /usr/local/bin/check-v2ray.sh << EOF
#!/bin/bash
echo "Kiểm tra V2Ray..."
if systemctl is-active --quiet v2ray; then
  echo "V2Ray đang chạy!"
else
  echo "V2Ray không chạy. Khởi động lại..."
  systemctl restart v2ray
fi

echo "Kiểm tra GOST bridge..."
if systemctl is-active --quiet gost-bridge; then
  echo "GOST bridge đang chạy!"
else
  echo "GOST bridge không chạy. Khởi động lại..."
  systemctl restart gost-bridge
fi

echo "Kiểm tra Nginx..."
if systemctl is-active --quiet nginx; then
  echo "Nginx đang chạy!"
else
  echo "Nginx không chạy. Khởi động lại..."
  systemctl restart nginx
fi

echo "Kiểm tra kết nối thông qua HTTP bridge..."
curl -x http://localhost:$HTTP_BRIDGE_PORT -s https://httpbin.org/ip
EOF
chmod +x /usr/local/bin/check-v2ray.sh

# Tạo tác vụ cron để tự động khởi động lại dịch vụ mỗi ngày
(crontab -l 2>/dev/null || echo "") | grep -v "restart-v2ray-services.sh" | { cat; echo "0 4 * * * /usr/local/bin/restart-v2ray-services.sh > /dev/null 2>&1"; } | crontab -

# Hiển thị thông tin kết nối
echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}CÀI ĐẶT THÀNH CÔNG!${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "V2Ray WebSocket + TLS đã được cài đặt và cấu hình!"
echo -e ""
echo -e "Thông tin kết nối cho ứng dụng V2Ray (Shadowrocket/Quantumult X):"
echo -e "  Giao thức: ${GREEN}VMess + WebSocket + TLS${NC}"
if [ "$USE_IP" = true ]; then
    echo -e "  Địa chỉ: ${GREEN}$PUBLIC_IP${NC} (ngụy trang: $FAKE_DOMAIN)"
else
    echo -e "  Địa chỉ: ${GREEN}$DOMAIN${NC}"
fi
echo -e "  Cổng: ${GREEN}443${NC}"
echo -e "  UUID: ${GREEN}$UUID${NC}"
echo -e "  AlterID: ${GREEN}0${NC}"
echo -e "  WebSocket Path: ${GREEN}$WS_PATH${NC}"
echo -e "  TLS: ${GREEN}Bật${NC}"
echo -e ""
echo -e "URL V2Ray (có thể import vào app):"
echo -e "${GREEN}$V2RAY_LINK${NC}"
echo -e ""
echo -e "Thông tin HTTP Bridge cho iPhone (không cần cài app):"
echo -e "  HTTP Proxy: ${GREEN}$PUBLIC_IP:$HTTP_BRIDGE_PORT${NC}"
echo -e "  PAC URL: ${GREEN}http://$PUBLIC_IP/proxy/proxy.pac${NC} hoặc ${GREEN}https://$DOMAIN_OR_IP/proxy/proxy.pac${NC}"
echo -e "${GREEN}============================================${NC}"

echo -e "\n${YELLOW}HƯỚNG DẪN SỬ DỤNG:${NC}"
echo -e "1. ${GREEN}Dùng trên iPhone không cần cài app:${NC}"
echo -e "   - Vào Settings > Wi-Fi > [Mạng Wi-Fi] > Configure Proxy > Auto"
echo -e "   - URL: ${GREEN}http://$PUBLIC_IP/proxy/proxy.pac${NC}"
echo -e "   - Hoặc configure thủ công với IP: ${GREEN}$PUBLIC_IP${NC} và Port: ${GREEN}$HTTP_BRIDGE_PORT${NC}"
echo -e ""
echo -e "2. ${GREEN}Dùng với ứng dụng (hiệu quả nhất):${NC}"
echo -e "   a) Shadowrocket (iPhone): Scan QR code hoặc import URL V2Ray ở trên"
echo -e "   b) V2rayNG (Android): Scan QR code hoặc import URL V2Ray ở trên"
echo -e "   c) Qv2ray (Windows/Mac/Linux): Thêm cấu hình mới với thông tin ở trên"
echo -e ""
echo -e "3. ${GREEN}Bảo trì:${NC}"
echo -e "   - Kiểm tra trạng thái: ${GREEN}sudo /usr/local/bin/check-v2ray.sh${NC}"
echo -e "   - Khởi động lại dịch vụ: ${GREEN}sudo /usr/local/bin/restart-v2ray-services.sh${NC}"

echo -e "\n${YELLOW}LƯU Ý:${NC}"
echo -e "- V2Ray WebSocket+TLS là một trong những phương thức tốt nhất để vượt qua tường lửa DPI"
echo -e "- Máy chủ đã được cấu hình để tự động khởi động lại dịch vụ hàng ngày vào 04:00 để đảm bảo ổn định"
echo -e "- HTTP Bridge chỉ là giải pháp thay thế khi không thể cài đặt ứng dụng, hiệu suất thấp hơn kết nối trực tiếp"
