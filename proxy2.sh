#!/bin/bash

# Proxy Server Manager Script
# Script này cho phép cài đặt hoặc gỡ cài đặt proxy server

# Màu sắc cho output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Vui lòng chạy với quyền root${NC}"
  exit 1
fi

# Hàm kiểm tra xem cổng có đang được sử dụng không
check_port() {
  local port=$1
  if netstat -tuln | grep -q ":$port "; then
    echo -e "${RED}Cổng $port đã được sử dụng. Vui lòng chọn cổng khác.${NC}"
    return 1
  fi
  return 0
}

# Hàm lấy địa chỉ IP công cộng
get_public_ip() {
  echo -e "${GREEN}Đang xác định địa chỉ IP công cộng...${NC}"
  PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || curl -s https://icanhazip.com)

  if [ -z "$PUBLIC_IP" ]; then
    echo -e "${RED}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
    PUBLIC_IP=$(hostname -I | awk '{print $1}')
    echo -e "${YELLOW}Sử dụng IP local: $PUBLIC_IP${NC}"
  else
    echo -e "${GREEN}Đã xác định IP công cộng: $PUBLIC_IP${NC}"
  fi
}

# Hàm cài đặt HTTP Proxy (Squid)
install_http_proxy() {
  echo -e "${GREEN}Đang cài đặt HTTP proxy server (Squid)...${NC}"
  apt update -y
  apt install -y squid apache2-utils
  
  # Xác định thư mục cấu hình Squid
  if [ -d /etc/squid ]; then
    SQUID_CONFIG_DIR="/etc/squid"
  else
    SQUID_CONFIG_DIR="/etc/squid3"
    # Nếu cả hai đều không tồn tại, cài đặt squid và kiểm tra lại
    if [ ! -d "$SQUID_CONFIG_DIR" ]; then
      apt install -y squid
      SQUID_CONFIG_DIR="/etc/squid"
    fi
  fi
  
  # Sao lưu cấu hình gốc
  echo -e "${GREEN}Đang sao lưu cấu hình Squid gốc...${NC}"
  if [ -f "$SQUID_CONFIG_DIR/squid.conf" ]; then
    cp "$SQUID_CONFIG_DIR/squid.conf" "$SQUID_CONFIG_DIR/squid.conf.bak"
  fi
  
  # Thiết lập cổng proxy (mặc định: 3128)
  while true; do
    read -p "Nhập cổng cho HTTP proxy server [3128]: " PROXY_PORT
    PROXY_PORT=${PROXY_PORT:-3128}
    if check_port $PROXY_PORT; then
      break
    fi
  done
  
  # Hỏi xem có cần xác thực không
  read -p "Bạn có muốn thiết lập xác thực không? (y/n): " AUTH_NEEDED
  
  if [[ "$AUTH_NEEDED" =~ ^[Yy]$ ]]; then
    # Tạo file xác thực
    echo -e "${GREEN}Đang thiết lập xác thực...${NC}"
    read -p "Nhập tên người dùng cho proxy: " PROXY_USER
    
    # Tạo file mật khẩu
    touch "$SQUID_CONFIG_DIR/passwd"
    htpasswd -bc "$SQUID_CONFIG_DIR/passwd" "$PROXY_USER" $(read -s -p "Nhập mật khẩu: " PASS && echo $PASS)
    chown proxy:proxy "$SQUID_CONFIG_DIR/passwd" 2>/dev/null || true
    
    # Xác định đường dẫn đến basic_ncsa_auth
    BASIC_AUTH_PATH=""
    for path in "/usr/lib/squid/basic_ncsa_auth" "/usr/lib/squid3/basic_ncsa_auth" "/usr/libexec/squid/basic_ncsa_auth"; do
      if [ -f "$path" ]; then
        BASIC_AUTH_PATH="$path"
        break
      fi
    done
    
    if [ -z "$BASIC_AUTH_PATH" ]; then
      echo -e "${RED}Không tìm thấy basic_ncsa_auth. Xác thực có thể không hoạt động đúng.${NC}"
      # Tìm đường dẫn động
      BASIC_AUTH_PATH=$(find /usr -name basic_ncsa_auth 2>/dev/null | head -n 1)
      if [ -z "$BASIC_AUTH_PATH" ]; then
        echo -e "${RED}Vẫn không tìm thấy basic_ncsa_auth. Sử dụng đường dẫn mặc định.${NC}"
        BASIC_AUTH_PATH="/usr/lib/squid/basic_ncsa_auth"
      else
        echo -e "${GREEN}Đã tìm thấy basic_ncsa_auth tại $BASIC_AUTH_PATH${NC}"
      fi
    fi
    
    # Tạo cấu hình Squid mới với xác thực
    cat > "$SQUID_CONFIG_DIR/squid.conf" << EOF
# Cấu hình Squid với xác thực cơ bản

# Định nghĩa ACL cho localhost
acl localhost src 127.0.0.1/32 ::1
acl to_localhost dst 127.0.0.0/8 0.0.0.0/32 ::1

# Cấu hình cổng
http_port $PROXY_PORT

# Cài đặt xác thực
auth_param basic program $BASIC_AUTH_PATH $SQUID_CONFIG_DIR/passwd
auth_param basic realm Proxy Authentication Required
auth_param basic credentialsttl 2 hours
acl authenticated_users proxy_auth REQUIRED

# Kiểm soát truy cập
http_access allow authenticated_users
http_access allow localhost
http_access deny all

# Cài đặt DNS cho quyền riêng tư tốt hơn
dns_nameservers 8.8.8.8 8.8.4.4

# Cài đặt hiệu suất cơ bản
cache_mem 256 MB
maximum_object_size 100 MB
EOF
  
  else
    # Tạo cấu hình Squid mới không có xác thực
    cat > "$SQUID_CONFIG_DIR/squid.conf" << EOF
# Cấu hình Squid không có xác thực

# Định nghĩa ACL cho localhost
acl localhost src 127.0.0.1/32 ::1
acl to_localhost dst 127.0.0.0/8 0.0.0.0/32 ::1

# Cấu hình cổng
http_port $PROXY_PORT

# Kiểm soát truy cập
http_access allow all

# Cài đặt DNS cho quyền riêng tư tốt hơn
dns_nameservers 8.8.8.8 8.8.4.4

# Cài đặt hiệu suất cơ bản
cache_mem 256 MB
maximum_object_size 100 MB
EOF
  
  fi
  
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
    # Cố gắng cài đặt squid nếu không tìm thấy dịch vụ
    apt install -y squid
    SQUID_SERVICE="squid"
  fi
  
  # Khởi động lại dịch vụ Squid
  echo -e "${GREEN}Đang khởi động lại dịch vụ Squid...${NC}"
  if ! systemctl restart $SQUID_SERVICE; then
    echo -e "${RED}Không thể khởi động lại dịch vụ Squid. Kiểm tra cấu hình...${NC}"
    if [ -x /usr/sbin/squid ]; then
      /usr/sbin/squid -k parse
    elif [ -x /usr/sbin/squid3 ]; then
      /usr/sbin/squid3 -k parse
    fi
    echo -e "${RED}Vui lòng sửa lỗi cấu hình và khởi động lại Squid thủ công.${NC}"
    exit 1
  fi
  
  systemctl enable $SQUID_SERVICE
  
  # Kiểm tra xem dịch vụ có đang chạy không
  if systemctl is-active --quiet $SQUID_SERVICE; then
    echo -e "${GREEN}HTTP proxy server đang chạy!${NC}"
  else
    echo -e "${RED}Không thể khởi động HTTP proxy server. Kiểm tra logs với: journalctl -u $SQUID_SERVICE${NC}"
    exit 1
  fi
  
  # Hiển thị thông tin proxy
  get_public_ip
  echo -e "${YELLOW}Thông tin HTTP Proxy Server:${NC}"
  echo "IP công cộng: $PUBLIC_IP"
  echo "Cổng: $PROXY_PORT"
  if [[ "$AUTH_NEEDED" =~ ^[Yy]$ ]]; then
    echo "Tên người dùng: $PROXY_USER"
    echo "Xác thực: Bật"
  else
    echo "Xác thực: Tắt"
  fi
  
  echo -e "${YELLOW}Để sử dụng proxy này:${NC}"
  echo "HTTP Proxy: $PUBLIC_IP:$PROXY_PORT"
  if [[ "$AUTH_NEEDED" =~ ^[Yy]$ ]]; then
    echo "Yêu cầu thông tin đăng nhập: Có (tên người dùng và mật khẩu)"
  fi
}

# Hàm cài đặt SOCKS5 Proxy (Shadowsocks)
install_socks5_proxy() {
  echo -e "${GREEN}Đang cài đặt SOCKS5 proxy server (Shadowsocks)...${NC}"
  
  # Cài đặt các gói phụ thuộc
  apt update -y
  apt install -y python3-pip python3-setuptools
  
  # Cài đặt Shadowsocks
  echo -e "${GREEN}Đang cài đặt Shadowsocks...${NC}"
  pip3 install shadowsocks
  
  # Thiết lập cổng proxy
  while true; do
    read -p "Nhập cổng cho SOCKS5 proxy server [8388]: " PROXY_PORT
    PROXY_PORT=${PROXY_PORT:-8388}
    if check_port $PROXY_PORT; then
      break
    fi
  done
  
  # Thiết lập mật khẩu
  read -s -p "Nhập mật khẩu cho Shadowsocks (bắt buộc): " SS_PASS
  echo
  
  # Xác minh mật khẩu không trống
  while [ -z "$SS_PASS" ]; do
    echo -e "${RED}Mật khẩu không thể trống.${NC}"
    read -s -p "Nhập mật khẩu cho Shadowsocks (bắt buộc): " SS_PASS
    echo
  done
  
  # Tạo thư mục cấu hình
  mkdir -p /etc/shadowsocks
  
  # Tạo file cấu hình
  cat > /etc/shadowsocks/config.json << EOF
{
  "server": "0.0.0.0",
  "server_port": $PROXY_PORT,
  "password": "$SS_PASS",
  "timeout": 300,
  "method": "aes-256-cfb",
  "fast_open": false
}
EOF
  
  # Sửa lỗi với thư viện Crypto (phổ biến trong các phiên bản Python mới hơn)
  if ! pip3 show pycryptodome > /dev/null 2>&1; then
    echo -e "${GREEN}Đang cài đặt PyCryptodome...${NC}"
    pip3 install pycryptodome
  fi
  
  # Sửa lỗi với module openssl nếu cần
  if grep -q "from OpenSSL import rand" /usr/local/lib/python*/dist-packages/shadowsocks/crypto/openssl.py 2>/dev/null; then
    echo -e "${GREEN}Đang vá Shadowsocks để tương thích...${NC}"
    sed -i 's/from OpenSSL import rand/from os import urandom as rand/g' /usr/local/lib/python*/dist-packages/shadowsocks/crypto/openssl.py
  fi
  
  # Tạo file dịch vụ systemd
  cat > /etc/systemd/system/shadowsocks.service << EOF
[Unit]
Description=Shadowsocks Proxy Server
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  
  # Nạp lại systemd, kích hoạt và khởi động dịch vụ
  systemctl daemon-reload
  systemctl enable shadowsocks
  
  # Khởi động dịch vụ với xử lý lỗi
  if ! systemctl start shadowsocks; then
    echo -e "${RED}Không thể khởi động dịch vụ Shadowsocks. Thử phương pháp thay thế...${NC}"
    # Thử chạy ssserver trực tiếp để xem output lỗi
    echo -e "${YELLOW}Chạy Shadowsocks server trực tiếp để kiểm tra lỗi:${NC}"
    echo "--------------------------------"
    ssserver -c /etc/shadowsocks/config.json -d start
    echo "--------------------------------"
    
    # Kiểm tra xem nó có đang chạy không
    sleep 2
    if pgrep -f ssserver > /dev/null; then
      echo -e "${GREEN}Shadowsocks đang chạy bằng phương pháp trực tiếp.${NC}"
    else
      echo -e "${RED}Không thể khởi động Shadowsocks. Vui lòng kiểm tra output lỗi ở trên.${NC}"
      exit 1
    fi
  fi
  
  # Cấu hình tường lửa
  echo -e "${GREEN}Đang cấu hình tường lửa...${NC}"
  apt install -y ufw
  ufw allow ssh
  ufw allow $PROXY_PORT/tcp
  ufw allow $PROXY_PORT/udp
  ufw --force enable
  
  # Hiển thị thông tin proxy
  get_public_ip
  echo -e "${YELLOW}Thông tin SOCKS5 Proxy Server:${NC}"
  echo "IP công cộng: $PUBLIC_IP"
  echo "Cổng: $PROXY_PORT"
  echo "Mật khẩu: $SS_PASS"
  echo "Mã hóa: aes-256-cfb"
  
  echo -e "${YELLOW}Để sử dụng Shadowsocks proxy này:${NC}"
  echo "Server: $PUBLIC_IP"
  echo "Cổng: $PROXY_PORT"
  echo "Mật khẩu: $SS_PASS"
  echo "Mã hóa: aes-256-cfb"
  
  echo -e "${YELLOW}Bạn có thể kết nối bằng bất kỳ client Shadowsocks nào:${NC}"
  echo "- Windows/macOS/Linux: Shadowsocks client"
  echo "- Android: Shadowsocks for Android"
  echo "- iOS: Shadowrocket"
}

# Hàm gỡ cài đặt HTTP Proxy (Squid)
uninstall_http_proxy() {
  echo -e "${GREEN}Đang gỡ cài đặt HTTP proxy (Squid)...${NC}"
  
  # Dừng và vô hiệu hóa dịch vụ Squid
  echo "Dừng dịch vụ Squid..."
  systemctl stop squid 2>/dev/null || systemctl stop squid3 2>/dev/null || true
  systemctl disable squid 2>/dev/null || systemctl disable squid3 2>/dev/null || true
  
  # Gỡ cài đặt gói Squid
  echo "Gỡ cài đặt Squid..."
  apt purge -y squid squid3 apache2-utils
  apt autoremove -y
  
  # Xóa thư mục cấu hình nếu còn tồn tại
  echo "Xóa các file cấu hình..."
  rm -rf /etc/squid /etc/squid3
  
  echo -e "${GREEN}Đã gỡ cài đặt HTTP proxy (Squid) thành công!${NC}"
}

# Hàm gỡ cài đặt SOCKS5 Proxy (Shadowsocks)
uninstall_socks5_proxy() {
  echo -e "${GREEN}Đang gỡ cài đặt SOCKS5 proxy (Shadowsocks)...${NC}"
  
  # Dừng và vô hiệu hóa dịch vụ Shadowsocks
  echo "Dừng dịch vụ Shadowsocks..."
  systemctl stop shadowsocks 2>/dev/null || true
  systemctl disable shadowsocks 2>/dev/null || true
  
  # Nếu chạy trực tiếp thì dừng
  if pgrep -f ssserver > /dev/null; then
    echo "Dừng quy trình Shadowsocks..."
    ssserver -c /etc/shadowsocks/config.json -d stop 2>/dev/null || pkill -f ssserver
  fi
  
  # Gỡ cài đặt Shadowsocks
  echo "Gỡ cài đặt Shadowsocks..."
  pip3 uninstall -y shadowsocks shadowsocks-libev
  
  # Xóa các file cấu hình
  echo "Xóa các file cấu hình..."
  rm -rf /etc/shadowsocks
  rm -f /etc/systemd/system/shadowsocks.service
  systemctl daemon-reload
  
  echo -e "${GREEN}Đã gỡ cài đặt SOCKS5 proxy (Shadowsocks) thành công!${NC}"
}

# Hàm đặt lại tường lửa
reset_firewall() {
  echo -e "${GREEN}Đặt lại cấu hình tường lửa...${NC}"
  
  # Chỉ đảm bảo SSH vẫn được cho phép
  ufw reset
  ufw allow ssh
  ufw --force enable
  
  echo -e "${GREEN}Đã đặt lại tường lửa!${NC}"
}

# Hiển thị menu chính
echo -e "${YELLOW}=== QUẢN LÝ PROXY SERVER ===${NC}"
echo "1) Cài đặt proxy server"
echo "2) Gỡ cài đặt proxy server"
echo "3) Thoát"
read -p "Vui lòng chọn một tùy chọn [1-3]: " MAIN_CHOICE

case $MAIN_CHOICE in
  1)
    # Menu cài đặt
    echo -e "${YELLOW}=== CÀI ĐẶT PROXY SERVER ===${NC}"
    echo "1) HTTP proxy (Squid)"
    echo "2) SOCKS5 proxy (Shadowsocks)"
    echo "3) Quay lại"
    read -p "Chọn loại proxy để cài đặt [1-3]: " INSTALL_CHOICE
    
    case $INSTALL_CHOICE in
      1)
        install_http_proxy
        ;;
      2)
        install_socks5_proxy
        ;;
      3)
        echo "Quay lại menu chính..."
        exit 0
        ;;
      *)
        echo -e "${RED}Lựa chọn không hợp lệ. Thoát.${NC}"
        exit 1
        ;;
    esac
    ;;
    
  2)
    # Menu gỡ cài đặt
    echo -e "${YELLOW}=== GỠ CÀI ĐẶT PROXY SERVER ===${NC}"
    echo "1) HTTP proxy (Squid)"
    echo "2) SOCKS5 proxy (Shadowsocks)"
    echo "3) Cả hai"
    echo "4) Quay lại"
    read -p "Chọn loại proxy để gỡ cài đặt [1-4]: " UNINSTALL_CHOICE
    
    case $UNINSTALL_CHOICE in
      1)
        uninstall_http_proxy
        ;;
      2)
        uninstall_socks5_proxy
        ;;
      3)
        uninstall_http_proxy
        uninstall_socks5_proxy
        ;;
      4)
        echo "Quay lại menu chính..."
        exit 0
        ;;
      *)
        echo -e "${RED}Lựa chọn không hợp lệ. Thoát.${NC}"
        exit 1
        ;;
    esac
    
    # Hỏi người dùng có muốn đặt lại tường lửa không
    read -p "Bạn có muốn đặt lại tường lửa không? (y/n): " RESET_FIREWALL
    if [[ "$RESET_FIREWALL" =~ ^[Yy]$ ]]; then
      reset_firewall
    fi
    ;;
    
  3)
    echo "Thoát..."
    exit 0
    ;;
    
  *)
    echo -e "${RED}Lựa chọn không hợp lệ. Thoát.${NC}"
    exit 1
    ;;
esac

echo -e "${GREEN}Quá trình hoàn tất!${NC}"
