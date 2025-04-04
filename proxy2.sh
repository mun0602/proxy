#!/bin/bash

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

# Lấy địa chỉ IP công cộng
PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || curl -s https://api.ipify.org || curl -s https://ifconfig.me)
if [ -z "$PUBLIC_IP" ]; then
  echo -e "${YELLOW}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
  PUBLIC_IP=$(hostname -I | awk '{print $1}')
fi

# Cấu hình các cổng
HTTP_BRIDGE_PORT=8118
V2RAY_PORT=10086
INTERNAL_V2RAY_PORT=10087
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/$(head /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)"

# Cài đặt các gói cần thiết
echo -e "${GREEN}Đang cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y nginx curl wget unzip jq

# Cài đặt GOST (HTTP Bridge)
echo -e "${GREEN}Đang cài đặt GOST cho HTTP Bridge...${NC}"
mkdir -p /tmp/gost
cd /tmp/gost
wget https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
gunzip gost-linux-amd64-2.11.5.gz
mv gost-linux-amd64-2.11.5 /usr/local/bin/gost
chmod +x /usr/local/bin/gost

# Cài đặt V2Ray
echo -e "${GREEN}Đang cài đặt V2Ray...${NC}"
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

# Cấu hình V2Ray - Nhận kết nối từ GOST và từ client VMess
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
      "port": $INTERNAL_V2RAY_PORT,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "",
        "port": 0,
        "network": "tcp,udp",
        "followRedirect": true
      },
      "tag": "http-bridge-in"
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
        }
      },
      "tag": "vmess-in"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    }
  ],
  "routing": {
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

# Cấu hình GOST HTTP Bridge chuyển tiếp đến V2Ray
cat > /etc/systemd/system/gost-bridge.service << EOF
[Unit]
Description=GOST HTTP-VMess Bridge
After=network.target v2ray.service

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -L http://:$HTTP_BRIDGE_PORT -F tcp://127.0.0.1:$INTERNAL_V2RAY_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Cấu hình Nginx cho WebSocket
echo -e "${GREEN}Cấu hình Nginx...${NC}"
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
    }
    
    # PAC file cho iPhone
    location /proxy/ {
        root /var/www/html;
        types { } 
        default_type application/x-ns-proxy-autoconfig;
    }
}
EOF

# Tạo PAC file cho iPhone
echo -e "${GREEN}Tạo PAC file cho iPhone...${NC}"
mkdir -p /var/www/html/proxy
cat > /var/www/html/proxy/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Các domain cần dùng proxy
    var domains = [
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
        ".fast.com",
        
        // Thêm các domain khác ở đây
        ".facebook.com",
        ".google.com",
        ".youtube.com",
        ".twitter.com",
        ".instagram.com"
    ];
    
    // Kiểm tra domain trong danh sách
    for (var i = 0; i < domains.length; i++) {
        if (dnsDomainIs(host, domains[i]) || 
            shExpMatch(host, "*" + domains[i] + "*")) {
            return "PROXY $PUBLIC_IP:$HTTP_BRIDGE_PORT";
        }
    }
    
    // Kiểm tra dải IP Trung Quốc (làm ví dụ)
    if (isInNet(dnsResolve(host), "58.14.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "58.16.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "58.24.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.128.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.132.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.136.0.0", "255.255.0.0")) {
        return "PROXY $PUBLIC_IP:$HTTP_BRIDGE_PORT";
    }
    
    // Mặc định truy cập trực tiếp
    return "DIRECT";
}
EOF

# Tạo trang web ngụy trang
echo -e "${GREEN}Tạo trang web ngụy trang...${NC}"
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>My Personal Blog</title>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 0; line-height: 1.6; color: #333; }
        .header { background: #4a89dc; color: white; text-align: center; padding: 40px 0; }
        .container { max-width: 1000px; margin: 0 auto; padding: 20px; }
        .footer { background: #333; color: white; text-align: center; padding: 20px 0; margin-top: 40px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Welcome to My Tech Blog</h1>
        <p>Exploring technology and programming</p>
    </div>
    
    <div class="container">
        <h2>Recent Articles</h2>
        <div class="article">
            <h3>The Future of Cloud Computing</h3>
            <p>Posted on April 2, 2025</p>
            <p>Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nulla facilisi. Sed euismod, nisl vel ultricies lacinia, nisl nisl aliquam nisl, nec ultricies nisl nisl nec nisl.</p>
            <a href="#">Read more</a>
        </div>
        
        <div class="article">
            <h3>Getting Started with Machine Learning</h3>
            <p>Posted on March 28, 2025</p>
            <p>Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nulla facilisi. Sed euismod, nisl vel ultricies lacinia, nisl nisl aliquam nisl, nec ultricies nisl nisl nec nisl.</p>
            <a href="#">Read more</a>
        </div>
    </div>
    
    <div class="footer">
        <p>&copy; 2025 My Tech Blog. All rights reserved.</p>
    </div>
</body>
</html>
EOF

# Khởi động dịch vụ
echo -e "${GREEN}Khởi động dịch vụ...${NC}"
systemctl daemon-reload
systemctl enable v2ray
systemctl enable gost-bridge
systemctl enable nginx
systemctl restart v2ray
systemctl restart gost-bridge
systemctl restart nginx

# Tạo cấu hình V2Ray client
V2RAY_CONFIG=$(cat <<EOF
{
  "v": "2",
  "ps": "V2Ray-WebSocket-HTTP-Bridge",
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

# Tạo URL chia sẻ V2Ray
V2RAY_LINK="vmess://$(echo $V2RAY_CONFIG | jq -c . | base64 -w 0)"

# Tạo script kiểm tra
cat > /usr/local/bin/check-v2ray-bridge.sh << EOF
#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "\${YELLOW}Kiểm tra dịch vụ...${NC}"
for service in v2ray gost-bridge nginx; do
  if systemctl is-active --quiet \$service; then
    echo -e "\${GREEN}\$service đang chạy.${NC}"
  else
    echo -e "\${RED}\$service không chạy. Khởi động lại...${NC}"
    systemctl restart \$service
  fi
done

echo -e "\${YELLOW}Kiểm tra kết nối HTTP bridge...${NC}"
curl -x http://localhost:$HTTP_BRIDGE_PORT -s https://httpbin.org/ip || echo -e "\${RED}Kết nối thất bại!${NC}"
EOF
chmod +x /usr/local/bin/check-v2ray-bridge.sh

# Hiển thị thông tin kết nối
echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}CÀI ĐẶT THÀNH CÔNG!${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "HTTP Bridge → V2Ray VMess đã được cài đặt và cấu hình!"
echo -e ""
echo -e "Thông tin kết nối cho iPhone (không cần cài app):"
echo -e "  PAC URL: ${GREEN}http://$PUBLIC_IP/proxy/proxy.pac${NC}"
echo -e "  HTTP Proxy thủ công: ${GREEN}$PUBLIC_IP:$HTTP_BRIDGE_PORT${NC}"
echo -e ""
echo -e "Thông tin kết nối cho ứng dụng V2Ray:"
echo -e "  Giao thức: ${GREEN}VMess + WebSocket${NC}"
echo -e "  Địa chỉ: ${GREEN}$PUBLIC_IP${NC}"
echo -e "  Cổng: ${GREEN}80${NC}"
echo -e "  UUID: ${GREEN}$UUID${NC}"
echo -e "  AlterID: ${GREEN}0${NC}"
echo -e "  WebSocket Path: ${GREEN}$WS_PATH${NC}"
echo -e "  TLS: ${GREEN}Tắt${NC}"
echo -e ""
echo -e "URL V2Ray (có thể import vào app):"
echo -e "${GREEN}$V2RAY_LINK${NC}"
echo -e "${GREEN}============================================${NC}"

echo -e "\n${YELLOW}HƯỚNG DẪN SỬ DỤNG:${NC}"
echo -e "1. ${GREEN}Trên iPhone (không cần cài app):${NC}"
echo -e "   - Vào Settings > Wi-Fi > [Mạng Wi-Fi] > Configure Proxy > Auto"
echo -e "   - URL: ${GREEN}http://$PUBLIC_IP/proxy/proxy.pac${NC}"
echo -e ""
echo -e "2. ${GREEN}Kiểm tra và khắc phục sự cố:${NC}"
echo -e "   - Chạy: ${GREEN}sudo /usr/local/bin/check-v2ray-bridge.sh${NC}"
