#!/bin/bash

# Script tự động cài đặt Squid trên cổng 33 và xuất IP:PORT

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

# Cổng cố định là 33
PROXY_PORT=33

# Hàm lấy địa chỉ IP công cộng
get_public_ip() {
  echo -e "${GREEN}Đang xác định địa chỉ IP công cộng...${NC}"
  PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || curl -s https://icanhazip.com)

  if [ -z "$PUBLIC_IP" ]; then
    echo -e "${YELLOW}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
    PUBLIC_IP=$(hostname -I | awk '{print $1}')
  fi
}

# Kiểm tra xem cổng có đang được sử dụng không
if netstat -tuln | grep -q ":$PROXY_PORT "; then
  echo -e "${YELLOW}Cổng $PROXY_PORT đã được sử dụng. Đang cố gắng ngừng dịch vụ...${NC}"
  fuser -k $PROXY_PORT/tcp >/dev/null 2>&1
  sleep 2
fi

# Cài đặt Squid
echo -e "${GREEN}Đang cài đặt Squid HTTP Proxy...${NC}"
apt update -y
apt install -y squid

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

# Tạo cấu hình Squid mới
cat > "$SQUID_CONFIG_DIR/squid.conf" << EOF
# Cấu hình Squid đơn giản
acl localhost src 127.0.0.1/32 ::1
acl to_localhost dst 127.0.0.0/8 0.0.0.0/32 ::1

# Cấu hình cổng
http_port $PROXY_PORT

# Kiểm soát truy cập
http_access allow all

# Cài đặt DNS
dns_nameservers 8.8.8.8 8.8.4.4

# Cài đặt hiệu suất cơ bản
cache_mem 256 MB
maximum_object_size 100 MB
EOF

# Cấu hình tường lửa
echo -e "${GREEN}Đang cấu hình tường lửa...${NC}"
apt install -y ufw
ufw allow ssh
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

# Khởi động lại dịch vụ Squid
echo -e "${GREEN}Đang khởi động lại dịch vụ Squid...${NC}"
systemctl restart $SQUID_SERVICE
systemctl enable $SQUID_SERVICE

# Kiểm tra xem dịch vụ có đang chạy không
if systemctl is-active --quiet $SQUID_SERVICE; then
  echo -e "${GREEN}HTTP proxy server đang chạy!${NC}"
else
  echo -e "${RED}Không thể khởi động HTTP proxy server. Đang thử phương pháp khác...${NC}"
  # Thử cách khác để khởi động dịch vụ
  if which squid > /dev/null; then
    squid -f "$SQUID_CONFIG_DIR/squid.conf"
    sleep 2
    if pgrep -x "squid" > /dev/null; then
      echo -e "${GREEN}HTTP proxy server đang chạy!${NC}"
    else
      echo -e "${RED}Không thể khởi động Squid. Vui lòng kiểm tra lại.${NC}"
      exit 1
    fi
  fi
fi

# Hiển thị thông tin proxy
get_public_ip

# In ra thông tin kết nối theo định dạng ip:33
echo -e "\n${GREEN}$PUBLIC_IP:$PROXY_PORT${NC}"

# Không hiển thị thông tin khác, chỉ hiển thị IP:PORT
