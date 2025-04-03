#!/bin/bash

# Script tự động cài đặt Squid với PAC file
# Tạo proxy tự động với cổng ngẫu nhiên và cung cấp file PAC qua HTTP

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

# Lấy cổng ngẫu nhiên cho Web Server
HTTP_PORT=$(get_random_port)
echo -e "${GREEN}Đã chọn cổng ngẫu nhiên cho Web Server: $HTTP_PORT${NC}"

# Cài đặt các gói cần thiết
echo -e "${GREEN}Đang cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y squid nginx curl netcat

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
acl localnet src all
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 21
acl Safe_ports port 443
acl Safe_ports port 70
acl Safe_ports port 210
acl Safe_ports port 1025-65535
acl Safe_ports port 280
acl Safe_ports port 488
acl Safe_ports port 591
acl Safe_ports port 777

# Cho phép tất cả cổng
http_access allow all

# Cấu hình cổng
http_port $PROXY_PORT

# Cài đặt DNS
dns_nameservers 8.8.8.8 8.8.4.4

# Tối ưu hiệu suất
cache_mem 256 MB
maximum_object_size 10 MB
maximum_object_size_in_memory 10 MB
cache_replacement_policy heap LFUDA
memory_replacement_policy heap LFUDA

# Tăng tốc độ kết nối
pipeline_prefetch on
connect_timeout 15 seconds
request_timeout 30 seconds
persistent_request_timeout 1 minute
client_lifetime 1 hour

# Cấu hình ẩn danh
forwarded_for off
via off
forwarded_for delete
follow_x_forwarded_for deny all
request_header_access From deny all
request_header_access Server deny all
request_header_access WWW-Authenticate deny all
request_header_access Link deny all
request_header_access Cache-Control deny all
request_header_access Proxy-Connection deny all
request_header_access X-Cache deny all
request_header_access X-Cache-Lookup deny all
request_header_access Via deny all
request_header_access X-Forwarded-For deny all
request_header_access Pragma deny all
request_header_access Keep-Alive deny all

coredump_dir /var/spool/squid
EOF

# Tạo thư mục cho PAC file
mkdir -p /var/www/html

# Tạo PAC file
cat > /var/www/html/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Các tên miền sẽ truy cập trực tiếp, không qua proxy
    var directDomains = [
        "localhost",
        "127.0.0.1"
    ];
    
    // Kiểm tra xem tên miền có nằm trong danh sách truy cập trực tiếp không
    for (var i = 0; i < directDomains.length; i++) {
        if (dnsDomainIs(host, directDomains[i]) || 
            shExpMatch(host, directDomains[i])) {
            return "DIRECT";
        }
    }
    
    // Sử dụng proxy cho mọi kết nối khác
    return "PROXY $PUBLIC_IP:$PROXY_PORT";
}
EOF

# Cấu hình Nginx để phục vụ PAC file
cat > /etc/nginx/sites-available/proxy-pac << EOF
server {
    listen $HTTP_PORT default_server;
    listen [::]:$HTTP_PORT default_server;
    
    root /var/www/html;
    index index.html index.htm;
    
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

# Kích hoạt cấu hình Nginx
ln -sf /etc/nginx/sites-available/proxy-pac /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Lấy địa chỉ IP công cộng
get_public_ip

# Cập nhật PAC file với địa chỉ IP chính xác
sed -i "s/PROXY \$PUBLIC_IP:\$PROXY_PORT/PROXY $PUBLIC_IP:$PROXY_PORT/g" /var/www/html/proxy.pac

# Khởi động lại các dịch vụ
echo -e "${GREEN}Đang khởi động lại dịch vụ...${NC}"

# Xác định tên dịch vụ squid
if systemctl list-units --type=service | grep -q "squid.service"; then
  SQUID_SERVICE="squid"
elif systemctl list-units --type=service | grep -q "squid3.service"; then
  SQUID_SERVICE="squid3"
else
  SQUID_SERVICE="squid"
fi

systemctl restart nginx
systemctl restart $SQUID_SERVICE

# Đợi dịch vụ khởi động
sleep 3

# Kiểm tra Squid
if ! systemctl is-active --quiet $SQUID_SERVICE; then
  echo -e "${RED}Không thể khởi động Squid. Đang thử phương pháp khác...${NC}"
  if which squid > /dev/null; then
    squid -f "$SQUID_CONFIG_DIR/squid.conf"
    sleep 2
  fi
fi

# Kiểm tra Nginx
if ! systemctl is-active --quiet nginx; then
  echo -e "${RED}Không thể khởi động Nginx. Đang thử phương pháp khác...${NC}"
  nginx -t
  nginx
  sleep 2
fi

# Kiểm tra lại các cổng
if ! netstat -tuln | grep -q ":$PROXY_PORT "; then
  echo -e "${RED}Cổng Squid $PROXY_PORT không mở. Kiểm tra lại cấu hình!${NC}"
  echo -e "${YELLOW}Trạng thái Squid:${NC}"
  systemctl status $SQUID_SERVICE --no-pager | head -n 10
else
  echo -e "${GREEN}Squid proxy đang chạy trên cổng $PROXY_PORT${NC}"
fi

if ! netstat -tuln | grep -q ":$HTTP_PORT "; then
  echo -e "${RED}Cổng HTTP $HTTP_PORT không mở. Kiểm tra lại cấu hình!${NC}"
  echo -e "${YELLOW}Trạng thái Nginx:${NC}"
  systemctl status nginx --no-pager | head -n 10
else
  echo -e "${GREEN}Web server đang chạy trên cổng $HTTP_PORT${NC}"
fi

# In ra thông tin kết nối
echo -e "${GREEN}Cấu hình proxy hoàn tất!${NC}"
echo -e "IP:Port proxy: ${GREEN}$PUBLIC_IP:$PROXY_PORT${NC}"
echo -e "URL PAC file: ${GREEN}http://$PUBLIC_IP:$HTTP_PORT/proxy.pac${NC}"
