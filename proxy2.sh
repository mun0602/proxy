#!/bin/bash

# Script cài đặt Shadowsocks với HTTP Bridge cho iPhone
# Cho phép dùng Shadowsocks thông qua HTTP proxy

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

# Tạo mật khẩu ngẫu nhiên cho Shadowsocks
SS_PASSWORD=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-16)
SS_METHOD="aes-256-gcm"  # Mã hóa mạnh nhưng tốc độ tốt

# Chọn cổng
SS_PORT=$(shuf -i 10000-20000 -n 1)
HTTP_BRIDGE_PORT=8118
HTTP_PORT=80
echo -e "${GREEN}Sử dụng cổng Shadowsocks: $SS_PORT${NC}"
echo -e "${GREEN}Sử dụng cổng HTTP Bridge: $HTTP_BRIDGE_PORT${NC}"
echo -e "${GREEN}Sử dụng cổng web server: $HTTP_PORT${NC}"

# Cài đặt các gói cần thiết
echo -e "${GREEN}Đang cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y nginx curl ufw wget privoxy python3-pip

# Dừng các dịch vụ hiện có
systemctl stop nginx 2>/dev/null
systemctl stop privoxy 2>/dev/null

# Cài đặt Shadowsocks
echo -e "${GREEN}Đang cài đặt Shadowsocks...${NC}"
pip3 install shadowsocks

# Tạo cấu hình Shadowsocks
mkdir -p /etc/shadowsocks
cat > /etc/shadowsocks/config.json << EOF
{
    "server":"0.0.0.0",
    "server_port":$SS_PORT,
    "password":"$SS_PASSWORD",
    "timeout":300,
    "method":"$SS_METHOD",
    "fast_open":true
}
EOF

# Sửa lỗi libcrypto trên một số hệ thống
sed -i 's/EVP_CIPHER_CTX_cleanup/EVP_CIPHER_CTX_reset/g' $(find /usr -name "openssl.py")

# Tạo service file cho Shadowsocks
cat > /etc/systemd/system/shadowsocks.service << EOF
[Unit]
Description=Shadowsocks Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Cấu hình Privoxy làm HTTP-Shadowsocks Bridge
echo -e "${GREEN}Đang cấu hình Privoxy làm HTTP-Shadowsocks Bridge...${NC}"
cat > /etc/privoxy/config << EOF
listen-address  0.0.0.0:$HTTP_BRIDGE_PORT
toggle  1
enable-remote-toggle  0
enable-remote-http-toggle  0
enable-edit-actions 0
enforce-blocks 0
buffer-limit 4096
forward-socks5 / 127.0.0.1:1080 .
debug 0
EOF

# Tạo script khởi động Shadowsocks client local (cầu nối giữa Privoxy và Shadowsocks)
cat > /usr/local/bin/start-ss-local.sh << EOF
#!/bin/bash
/usr/local/bin/sslocal -s 127.0.0.1 -p $SS_PORT -b 127.0.0.1 -l 1080 -k "$SS_PASSWORD" -m $SS_METHOD
EOF
chmod +x /usr/local/bin/start-ss-local.sh

# Tạo service cho Shadowsocks local
cat > /etc/systemd/system/shadowsocks-local.service << EOF
[Unit]
Description=Shadowsocks Local Client
After=network.target shadowsocks.service

[Service]
Type=simple
ExecStart=/usr/local/bin/start-ss-local.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Tạo thư mục cho PAC file
mkdir -p /var/www/html

# Lấy địa chỉ IP công cộng
get_public_ip

# Tạo PAC file cho HTTP-Shadowsocks Bridge
cat > /var/www/html/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Sử dụng HTTP-Shadowsocks Bridge cho mọi kết nối
    return "PROXY $PUBLIC_IP:$HTTP_BRIDGE_PORT; DIRECT";
}
EOF

# Tạo PAC file được tối ưu hóa cho các ứng dụng Trung Quốc
cat > /var/www/html/china.pac << EOF
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

# Tạo trang index đơn giản
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Shadowsocks Bridge</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .proxy-info { background: #f5f5f5; padding: 15px; margin-bottom: 20px; border-radius: 5px; }
        .proxy-option { margin-bottom: 10px; }
        .proxy-option a { text-decoration: none; color: #0066cc; }
        .iphone-note { background: #fffbea; padding: 10px; border-left: 4px solid #ffcc00; margin: 15px 0; }
    </style>
</head>
<body>
    <h2>Shadowsocks với HTTP Bridge</h2>
    
    <div class="proxy-info">
        <h3>Thông tin kết nối:</h3>
        <p><strong>IP server:</strong> $PUBLIC_IP</p>
        <p><strong>HTTP Bridge Port:</strong> $HTTP_BRIDGE_PORT</p>
        <p><strong>Shadowsocks Port:</strong> $SS_PORT</p>
        <p><strong>Shadowsocks Password:</strong> $SS_PASSWORD</p>
        <p><strong>Encryption Method:</strong> $SS_METHOD</p>
    </div>
    
    <div class="iphone-note">
        <strong>Cho iPhone:</strong> Sử dụng HTTP Bridge với port $HTTP_BRIDGE_PORT
    </div>
    
    <h3>PAC Files:</h3>
    <div class="proxy-option">
        <p><a href="/proxy.pac">Proxy PAC</a> - Định tuyến tất cả lưu lượng qua proxy</p>
    </div>
    <div class="proxy-option">
        <p><a href="/china.pac">China PAC</a> - Chỉ định tuyến các trang web/ứng dụng Trung Quốc qua proxy</p>
    </div>
</body>
</html>
EOF

# Cấu hình Nginx để phục vụ PAC file
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
    
    location ~ \.pac$ {
        types { }
        default_type application/x-ns-proxy-autoconfig;
    }
}
EOF

# Cấu hình tường lửa
echo -e "${GREEN}Đang cấu hình tường lửa...${NC}"
ufw allow ssh
ufw allow $HTTP_PORT/tcp
ufw allow $SS_PORT/tcp
ufw allow $HTTP_BRIDGE_PORT/tcp

# Kích hoạt và khởi động các dịch vụ
systemctl daemon-reload
systemctl enable shadowsocks
systemctl enable shadowsocks-local
systemctl enable nginx
systemctl enable privoxy
systemctl start shadowsocks
sleep 2
systemctl start shadowsocks-local
sleep 2
systemctl start privoxy
systemctl start nginx

# Tạo script kiểm tra
cat > /usr/local/bin/check-ss.sh << EOF
#!/bin/bash
# Script kiểm tra Shadowsocks và HTTP Bridge

# Kiểm tra Shadowsocks server
if pgrep ssserver > /dev/null; then
  echo "Shadowsocks server đang chạy"
else
  echo "Shadowsocks server không chạy - khởi động lại"
  systemctl restart shadowsocks
fi

# Kiểm tra Shadowsocks local client
if pgrep sslocal > /dev/null; then
  echo "Shadowsocks local client đang chạy"
else
  echo "Shadowsocks local client không chạy - khởi động lại"
  systemctl restart shadowsocks-local
fi

# Kiểm tra Privoxy
if systemctl is-active --quiet privoxy; then
  echo "Privoxy (HTTP Bridge) đang chạy"
else
  echo "Privoxy không chạy - khởi động lại"
  systemctl restart privoxy
fi

# Kiểm tra Nginx
if systemctl is-active --quiet nginx; then
  echo "Nginx đang chạy"
else
  echo "Nginx không chạy - khởi động lại"
  systemctl restart nginx
fi

# Kiểm tra kết nối
echo "Kiểm tra kết nối thông qua HTTP Bridge..."
curl -x http://localhost:$HTTP_BRIDGE_PORT -s https://httpbin.org/ip
EOF
chmod +x /usr/local/bin/check-ss.sh

# Kiểm tra các dịch vụ
echo -e "${YELLOW}Đang kiểm tra các dịch vụ...${NC}"
sleep 5

# Kiểm tra Shadowsocks server
if pgrep ssserver > /dev/null; then
  echo -e "${GREEN}Shadowsocks server đang chạy!${NC}"
else
  echo -e "${RED}Shadowsocks server không khởi động được. Kiểm tra log: journalctl -u shadowsocks${NC}"
fi

# Kiểm tra Shadowsocks local client
if pgrep sslocal > /dev/null; then
  echo -e "${GREEN}Shadowsocks local client đang chạy!${NC}"
else
  echo -e "${RED}Shadowsocks local client không khởi động được. Kiểm tra log: journalctl -u shadowsocks-local${NC}"
  echo -e "${YELLOW}Khởi động thủ công...${NC}"
  /usr/local/bin/start-ss-local.sh &
fi

# Kiểm tra Privoxy
if systemctl is-active --quiet privoxy; then
  echo -e "${GREEN}Privoxy (HTTP Bridge) đang chạy!${NC}"
else
  echo -e "${RED}Privoxy không khởi động được. Kiểm tra log: journalctl -u privoxy${NC}"
fi

# Kiểm tra Nginx
if systemctl is-active --quiet nginx; then
  echo -e "${GREEN}Nginx đang chạy!${NC}"
else
  echo -e "${RED}Nginx không khởi động được. Kiểm tra log: journalctl -u nginx${NC}"
fi

# Hiển thị thông tin cấu hình
echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}SHADOWSOCKS VỚI HTTP BRIDGE ĐÃ CÀI ĐẶT XONG!${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "Thông tin Shadowsocks:"
echo -e "  Server: ${GREEN}$PUBLIC_IP${NC}"
echo -e "  Port: ${GREEN}$SS_PORT${NC}"
echo -e "  Mật khẩu: ${GREEN}$SS_PASSWORD${NC}"
echo -e "  Phương thức mã hóa: ${GREEN}$SS_METHOD${NC}"
echo -e ""
echo -e "Thông tin HTTP Bridge:"
echo -e "  HTTP Proxy: ${GREEN}$PUBLIC_IP:$HTTP_BRIDGE_PORT${NC}"
echo -e ""
echo -e "PAC Files:"
echo -e "  PAC toàn bộ: ${GREEN}http://$PUBLIC_IP/proxy.pac${NC}"
echo -e "  PAC cho Trung Quốc: ${GREEN}http://$PUBLIC_IP/china.pac${NC}"
echo -e "${GREEN}============================================${NC}"

# Hướng dẫn iPhone
echo -e "\n${YELLOW}HƯỚNG DẪN CHO iPHONE:${NC}"
echo -e "1. ${GREEN}Cài đặt với PAC:${NC}"
echo -e "   - Vào Settings > Wi-Fi > [Mạng của bạn] > Configure Proxy > Auto"
echo -e "   - URL: ${GREEN}http://$PUBLIC_IP/china.pac${NC}"
echo -e "2. ${GREEN}Cài đặt thủ công:${NC}"
echo -e "   - Vào Settings > Wi-Fi > [Mạng của bạn] > Configure Proxy > Manual"
echo -e "   - Server: ${GREEN}$PUBLIC_IP${NC}"
echo -e "   - Port: ${GREEN}$HTTP_BRIDGE_PORT${NC}"
echo -e "   - Không cần xác thực"
echo -e ""
echo -e "Chạy script kiểm tra nếu có vấn đề: ${GREEN}sudo /usr/local/bin/check-ss.sh${NC}"

# Tạo QR code cho khách hàng Shadowsocks (nếu cài đặt trên thiết bị khác)
if command -v qrencode &> /dev/null; then
  SS_URI="ss://$SS_METHOD:$SS_PASSWORD@$PUBLIC_IP:$SS_PORT"
  SS_URI_BASE64=$(echo -n "$SS_URI" | base64)
  echo -e "\n${YELLOW}Shadowsocks URI (cho client):${NC}"
  echo -e "${GREEN}$SS_URI${NC}"
else
  echo -e "\n${YELLOW}Để tạo QR code Shadowsocks, hãy cài đặt qrencode:${NC}"
  echo -e "${GREEN}apt install qrencode${NC}"
fi

# Khuyến nghị bổ sung
echo -e "\n${YELLOW}KHUYẾN NGHỊ:${NC}"
echo -e "- Sử dụng china.pac để có hiệu suất tốt nhất, chỉ định tuyến các ứng dụng Trung Quốc qua proxy"
echo -e "- Nếu gặp vấn đề, chạy script kiểm tra: ${GREEN}sudo /usr/local/bin/check-ss.sh${NC}"
echo -e "- Shadowsocks hiệu quả hơn cho việc vượt tường lửa DPI so với proxy HTTP/SOCKS5 thông thường"
