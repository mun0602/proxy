#!/bin/bash

# Script tự động cài đặt Squid trên cổng 1305 và xuất IP:PORT

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

# Cổng cố định là 1305
PROXY_PORT=1305

# Hàm lấy địa chỉ IP công cộng
get_public_ip() {
  # Sử dụng nhiều dịch vụ để đảm bảo lấy được IP
  PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || curl -s https://icanhazip.com || curl -s https://ipinfo.io/ip)

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
apt update -y
apt install -y squid netcat

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
# Cấu hình Squid đơn giản
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

# Các cấu hình hiệu suất
forwarded_for off
via off
coredump_dir /var/spool/squid
EOF

# Xác định tên dịch vụ squid
if systemctl list-units --type=service | grep -q "squid.service"; then
  SQUID_SERVICE="squid"
elif systemctl list-units --type=service | grep -q "squid3.service"; then
  SQUID_SERVICE="squid3"
else
  SQUID_SERVICE="squid"
fi

# Khởi động lại dịch vụ Squid
systemctl stop $SQUID_SERVICE 2>/dev/null
sleep 1
systemctl start $SQUID_SERVICE
systemctl enable $SQUID_SERVICE

# Đợi dịch vụ khởi động hoàn tất
sleep 3

# Kiểm tra xem dịch vụ có đang chạy không
if ! systemctl is-active --quiet $SQUID_SERVICE; then
  echo -e "${RED}Không thể khởi động HTTP proxy server. Đang thử phương pháp khác...${NC}"
  # Thử cách khác để khởi động dịch vụ
  if which squid > /dev/null; then
    squid -f "$SQUID_CONFIG_DIR/squid.conf"
    sleep 2
  fi
fi

# Kiểm tra xem cổng có được mở không
if ! netstat -tuln | grep -q ":$PROXY_PORT "; then
  echo -e "${RED}Không thể mở cổng $PROXY_PORT. Kiểm tra lại cấu hình.${NC}"
  # Hiển thị thông tin gỡ lỗi
  echo -e "${YELLOW}Trạng thái dịch vụ:${NC}"
  systemctl status $SQUID_SERVICE --no-pager | head -n 20
  exit 1
fi

# Hiển thị thông tin proxy
get_public_ip

# In ra thông tin kết nối theo định dạng IP:1305
echo -e "$PUBLIC_IP:$PROXY_PORT"
