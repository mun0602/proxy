#!/bin/bash

# Script cài đặt GOST HTTP proxy đơn giản không mật khẩu
# Dành cho troubleshooting kết nối

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

# Chọn cổng 
HTTP_PROXY_PORT=8080
HTTP_PORT=80
echo -e "${GREEN}Sử dụng cổng HTTP proxy: $HTTP_PROXY_PORT${NC}"
echo -e "${GREEN}Sử dụng cổng web server: $HTTP_PORT${NC}"

# Cài đặt các gói cần thiết
echo -e "${GREEN}Đang cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y nginx curl ufw wget

# Dừng các dịch vụ hiện có
systemctl stop nginx 2>/dev/null
pkill gost 2>/dev/null

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

# Tạo service file cho GOST
cat > /etc/systemd/system/gost.service << EOF
[Unit]
Description=GO Simple Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -L http://:$HTTP_PROXY_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Tạo thư mục cho PAC file
mkdir -p /var/www/html

# Lấy địa chỉ IP công cộng
get_public_ip

# Tạo PAC file đơn giản không có tối ưu hóa đặc biệt
cat > /var/www/html/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Mọi kết nối đều qua proxy
    return "PROXY $PUBLIC_IP:$HTTP_PROXY_PORT";
}
EOF

# Tạo trang index siêu đơn giản
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Simple Proxy</title>
</head>
<body>
    <h3>HTTP Proxy: $PUBLIC_IP:$HTTP_PROXY_PORT</h3>
    <p><a href="/proxy.pac">Download PAC</a></p>
</body>
</html>
EOF

# Cấu hình Nginx đơn giản để phục vụ PAC file
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
    }
}
EOF

# Cấu hình tường lửa
echo -e "${GREEN}Đang cấu hình tường lửa...${NC}"
# Sao lưu các quy tắc tường lửa hiện tại
iptables-save > /tmp/iptables-rules.bak

# Mở các cổng trên ufw
ufw allow ssh
ufw allow $HTTP_PORT/tcp
ufw allow $HTTP_PROXY_PORT/tcp

# Nếu ufw bị tắt, mở các cổng bằng iptables trực tiếp
iptables -I INPUT -p tcp --dport 22 -j ACCEPT
iptables -I INPUT -p tcp --dport $HTTP_PORT -j ACCEPT
iptables -I INPUT -p tcp --dport $HTTP_PROXY_PORT -j ACCEPT

# Kích hoạt và khởi động các dịch vụ
systemctl daemon-reload
systemctl enable gost
systemctl enable nginx
systemctl start gost
systemctl start nginx

# Tạo script kiểm tra
cat > /usr/local/bin/check-gost.sh << EOF
#!/bin/bash
# Script kiểm tra GOST HTTP proxy

# Kiểm tra GOST
if pgrep gost > /dev/null; then
  echo "GOST đang chạy"
else
  echo "GOST không chạy - khởi động lại"
  systemctl restart gost
fi

# Kiểm tra Nginx
if systemctl is-active --quiet nginx; then
  echo "Nginx đang chạy"
else
  echo "Nginx không chạy - khởi động lại"
  systemctl restart nginx
fi

# Kiểm tra kết nối proxy
echo "Kiểm tra kết nối proxy..."
curl -x http://localhost:$HTTP_PROXY_PORT -s https://httpbin.org/ip
EOF
chmod +x /usr/local/bin/check-gost.sh

# Kiểm tra GOST
echo -e "${YELLOW}Đang kiểm tra GOST...${NC}"
sleep 2
if pgrep gost > /dev/null; then
  echo -e "${GREEN}GOST đang chạy!${NC}"
else
  echo -e "${RED}GOST không chạy. Khởi động thủ công...${NC}"
  /usr/local/bin/gost -L http://:$HTTP_PROXY_PORT &
fi

# Kiểm tra Nginx
echo -e "${YELLOW}Đang kiểm tra Nginx...${NC}"
if systemctl is-active --quiet nginx; then
  echo -e "${GREEN}Nginx đang chạy!${NC}"
else
  echo -e "${RED}Nginx không khởi động được. Kiểm tra log: journalctl -u nginx${NC}"
  nginx
fi

# Hiển thị thông tin cấu hình
echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}HTTP PROXY ĐƠN GIẢN ĐÃ CÀI ĐẶT XONG!${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "HTTP Proxy: ${GREEN}$PUBLIC_IP:$HTTP_PROXY_PORT${NC}"
echo -e "URL PAC file: ${GREEN}http://$PUBLIC_IP/proxy.pac${NC}"
echo -e "${GREEN}============================================${NC}"

# Kiểm tra kết nối proxy ngay lập tức
echo -e "\n${YELLOW}Kiểm tra kết nối proxy...${NC}"
PROXY_TEST=$(curl -x http://localhost:$HTTP_PROXY_PORT -s https://httpbin.org/ip)
echo -e "Kết quả: ${GREEN}$PROXY_TEST${NC}"

# Hướng dẫn kiểm tra và khắc phục sự cố
echo -e "\n${YELLOW}Hướng dẫn kiểm tra:${NC}"
echo -e "1. ${GREEN}Kiểm tra proxy đang chạy:${NC}"
echo -e "   sudo lsof -i :$HTTP_PROXY_PORT"
echo -e "2. ${GREEN}Kiểm tra log GOST:${NC}"
echo -e "   journalctl -u gost"
echo -e "3. ${GREEN}Thử kết nối thủ công từ server:${NC}"
echo -e "   curl -x http://localhost:$HTTP_PROXY_PORT https://httpbin.org/ip"
echo -e "4. ${GREEN}Khởi động lại dịch vụ nếu cần:${NC}"
echo -e "   sudo systemctl restart gost"
echo -e "5. ${GREEN}Chạy script kiểm tra:${NC}"
echo -e "   sudo /usr/local/bin/check-gost.sh"
