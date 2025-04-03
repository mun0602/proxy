#!/bin/bash

# Script tự động cài đặt Squid với PAC file
# Phiên bản sửa lỗi - sử dụng cổng chuẩn và cấu hình tường lửa

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

# Hàm để tạo cổng ngẫu nhiên và kiểm tra xem nó có đang được sử dụng không
get_random_port() {
  # Tạo cổng ngẫu nhiên trong khoảng 10000-65000
  while true; do
    RANDOM_PORT=$(shuf -i 10000-65000 -n 1)
    if ! netstat -tuln | grep -q ":$RANDOM_PORT "; then
      echo $RANDOM_PORT
      return 0
    fi
  done
}

# Hàm lấy địa chỉ IP công cộng
get_public_ip() {
  # Sử dụng nhiều dịch vụ để đảm bảo lấy được IP
  PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || curl -s https://icanhazip.com || curl -s https://ipinfo.io/ip)

  if [ -z "$PUBLIC_IP" ]; then
    echo -e "${YELLOW}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
    PUBLIC_IP=$(hostname -I | awk '{print $1}')
  fi
}

# Lấy cổng ngẫu nhiên cho Squid
PROXY_PORT=$(get_random_port)
echo -e "${GREEN}Đã chọn cổng ngẫu nhiên cho Squid: $PROXY_PORT${NC}"

# Sử dụng cổng 80 cho web server (cổng HTTP tiêu chuẩn)
HTTP_PORT=80
echo -e "${GREEN}Sử dụng cổng HTTP tiêu chuẩn: $HTTP_PORT${NC}"

# Cài đặt các gói cần thiết
echo -e "${GREEN}Đang cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y squid nginx curl ufw netcat

# Dừng các dịch vụ để cấu hình
systemctl stop nginx 2>/dev/null
systemctl stop squid 2>/dev/null
systemctl stop squid3 2>/dev/null

# Xác định thư mục cấu hình Squid
if [ -d /etc/squid ]; then
  SQUID_CONFIG_DIR="/etc/squid"
else
  SQUID_CONFIG_DIR="/etc/squid3"
  # Nếu cả hai đều không tồn tại, kiểm tra lại
  if [ ! -d "$SQUID_CONFIG_DIR" ]; then
    SQUID_CONFIG_DIR="/etc/squid"
  fi
fi

# Sao lưu cấu hình Squid gốc nếu tồn tại
if [ -f "$SQUID_CONFIG_DIR/squid.conf" ]; then
  cp "$SQUID_CONFIG_DIR/squid.conf" "$SQUID_CONFIG_DIR/squid.conf.bak"
fi

# Tạo cấu hình Squid mới - đơn giản và cho phép mọi truy cập
cat > "$SQUID_CONFIG_DIR/squid.conf" << EOF
# Cấu hình Squid tối ưu
http_port $PROXY_PORT

# Quyền truy cập cơ bản
acl all src all
http_access allow all

# Cài đặt DNS
dns_nameservers 8.8.8.8 8.8.4.4

# Tối ưu hiệu suất
cache_mem 256 MB
maximum_object_size 10 MB

# Tăng tốc độ kết nối
connect_timeout 15 seconds
request_timeout 30 seconds

# Cấu hình ẩn danh
forwarded_for off
via off

coredump_dir /var/spool/squid
EOF

# Tạo thư mục cho PAC file
mkdir -p /var/www/html

# Lấy địa chỉ IP công cộng
get_public_ip

# Tạo PAC file
cat > /var/www/html/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Sử dụng proxy cho mọi kết nối
    return "PROXY $PUBLIC_IP:$PROXY_PORT";
}
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
    
    location /proxy.pac {
        types { }
        default_type application/x-ns-proxy-autoconfig;
        add_header Content-Disposition 'inline; filename="proxy.pac"';
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
ufw allow $PROXY_PORT/tcp
ufw --force enable

# Xác định tên dịch vụ squid
if systemctl list-units --type=service | grep -q "squid.service"; then
  SQUID_SERVICE="squid"
elif systemctl list-units --type=service | grep -q "squid3.service"; then
  SQUID_SERVICE="squid3"
else
  SQUID_SERVICE="squid"
fi

# Đảm bảo các dịch vụ được bật khi khởi động
systemctl enable nginx
systemctl enable $SQUID_SERVICE

# Khởi động lại các dịch vụ
echo -e "${GREEN}Đang khởi động các dịch vụ...${NC}"
systemctl restart $SQUID_SERVICE
sleep 2
systemctl restart nginx
sleep 2

# Kiểm tra Squid
if ! systemctl is-active --quiet $SQUID_SERVICE; then
  echo -e "${RED}Không thể khởi động Squid tự động. Đang thử phương pháp khác...${NC}"
  squid -f "$SQUID_CONFIG_DIR/squid.conf"
  sleep 2
fi

# Kiểm tra Nginx
if ! systemctl is-active --quiet nginx; then
  echo -e "${RED}Không thể khởi động Nginx tự động. Đang thử phương pháp khác...${NC}"
  nginx
  sleep 2
fi

# Kiểm tra lại các cổng
echo -e "${YELLOW}Đang kiểm tra các cổng...${NC}"
echo -e "Cổng Squid ($PROXY_PORT): \c"
if netstat -tuln | grep -q ":$PROXY_PORT "; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}KHÔNG HOẠT ĐỘNG${NC}"
fi

echo -e "Cổng HTTP ($HTTP_PORT): \c"
if netstat -tuln | grep -q ":$HTTP_PORT "; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}KHÔNG HOẠT ĐỘNG${NC}"
fi

# Thử truy cập vào trang PAC trực tiếp để kiểm tra
echo -e "${YELLOW}Đang kiểm tra PAC file...${NC}"
HTTP_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/proxy.pac)
if [ "$HTTP_RESPONSE" = "200" ]; then
  echo -e "${GREEN}PAC file có thể truy cập được từ localhost${NC}"
else
  echo -e "${RED}Không thể truy cập PAC file (HTTP code: $HTTP_RESPONSE)${NC}"
  echo -e "${YELLOW}Đang thử sửa quyền file...${NC}"
  chmod 755 /var/www/html -R
  chown www-data:www-data /var/www/html -R
  systemctl restart nginx
  sleep 2
fi

# Tạo một trang index đơn giản
echo "<html><body><h1>Proxy PAC Setup</h1><p>Your proxy PAC file is available at: <a href='/proxy.pac'>proxy.pac</a></p></body></html>" > /var/www/html/index.html

# In ra thông tin kết nối
echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}CẤU HÌNH PROXY HOÀN TẤT!${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "IP:Port proxy: ${GREEN}$PUBLIC_IP:$PROXY_PORT${NC}"
echo -e "URL PAC file: ${GREEN}http://$PUBLIC_IP/proxy.pac${NC}"
echo -e "${GREEN}============================================${NC}"

# Hiển thị nội dung PAC file
echo -e "\n${YELLOW}Nội dung PAC file:${NC}"
cat /var/www/html/proxy.pac
