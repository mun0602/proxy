#!/bin/bash

# Script tự động cài đặt Squid với PAC file chứa thông tin xác thực
# Phiên bản tối giản - chỉ tạo proxy và PAC file với thông tin xác thực

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

# Hàm để tạo cổng ngẫu nhiên
get_random_port() {
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
  PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || curl -s https://icanhazip.com || curl -s https://ipinfo.io/ip)

  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(hostname -I | awk '{print $1}')
  fi
}

# Tạo username và password ngẫu nhiên hoặc sử dụng tùy chọn dòng lệnh
generate_credentials() {
  if [ -z "$PROXY_USER" ]; then
    PROXY_USER="user$(openssl rand -hex 3)"
  fi
  
  if [ -z "$PROXY_PASS" ]; then
    PROXY_PASS="pass$(openssl rand -hex 6)"
  fi
}

# Phân tích tham số dòng lệnh
while getopts "u:p:" opt; do
  case $opt in
    u) PROXY_USER="$OPTARG" ;;
    p) PROXY_PASS="$OPTARG" ;;
    \?) echo "Tùy chọn không hợp lệ: -$OPTARG" >&2; exit 1 ;;
  esac
done

# Lấy cổng ngẫu nhiên cho Squid
PROXY_PORT=$(get_random_port)

# Sử dụng cổng 80 cho web server PAC
HTTP_PORT=80

# Tạo thông tin xác thực
generate_credentials

# Cài đặt các gói cần thiết
apt update -y
apt install -y squid apache2-utils nginx curl

# Dừng các dịch vụ để cấu hình
systemctl stop nginx 2>/dev/null
systemctl stop squid 2>/dev/null
systemctl stop squid3 2>/dev/null

# Xác định thư mục cấu hình Squid
if [ -d /etc/squid ]; then
  SQUID_CONFIG_DIR="/etc/squid"
else
  SQUID_CONFIG_DIR="/etc/squid3"
  if [ ! -d "$SQUID_CONFIG_DIR" ]; then
    SQUID_CONFIG_DIR="/etc/squid"
  fi
fi

# Tạo file mật khẩu cho Squid
touch "$SQUID_CONFIG_DIR/passwd"
htpasswd -b -c "$SQUID_CONFIG_DIR/passwd" "$PROXY_USER" "$PROXY_PASS"
chmod 644 "$SQUID_CONFIG_DIR/passwd"

# Xác định đường dẫn đến basic_ncsa_auth
BASIC_AUTH_PATH=""
for path in "/usr/lib/squid/basic_ncsa_auth" "/usr/lib/squid3/basic_ncsa_auth" "/usr/libexec/squid/basic_ncsa_auth"; do
  if [ -f "$path" ]; then
    BASIC_AUTH_PATH="$path"
    break
  fi
done

if [ -z "$BASIC_AUTH_PATH" ]; then
  BASIC_AUTH_PATH=$(find /usr -name basic_ncsa_auth 2>/dev/null | head -n 1)
  if [ -z "$BASIC_AUTH_PATH" ]; then
    BASIC_AUTH_PATH="/usr/lib/squid/basic_ncsa_auth" # Đường dẫn mặc định
  fi
fi

# Tạo cấu hình Squid mới với xác thực và Cloudflare DNS
cat > "$SQUID_CONFIG_DIR/squid.conf" << EOF
# Cấu hình Squid
http_port $PROXY_PORT

# Cấu hình xác thực
auth_param basic program $BASIC_AUTH_PATH $SQUID_CONFIG_DIR/passwd
auth_param basic realm Proxy Authentication Required
auth_param basic credentialsttl 12 hours
acl authenticated_users proxy_auth REQUIRED

# Quyền truy cập
http_access allow authenticated_users
http_access deny all

# Sử dụng DNS của Cloudflare
dns_nameservers 1.1.1.1 1.0.0.1

# Tối ưu hiệu suất
cache_mem 256 MB
maximum_object_size 10 MB

# Cấu hình ẩn danh
forwarded_for off
via off

coredump_dir /var/spool/squid
EOF

# Tạo thư mục cho PAC file
mkdir -p /var/www/html

# Lấy địa chỉ IP công cộng
get_public_ip

# Tạo PAC file với thông tin xác thực được nhúng sẵn
cat > /var/www/html/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Các tên miền truy cập trực tiếp, không qua proxy
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
    
    // Sử dụng proxy với thông tin xác thực được nhúng sẵn
    return "PROXY $PROXY_USER:$PROXY_PASS@$PUBLIC_IP:$PROXY_PORT";
}
EOF

# Cấu hình Nginx để chỉ phục vụ PAC file
cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    root /var/www/html;
    
    location / {
        return 404;
    }
    
    location = /proxy.pac {
        types { }
        default_type application/x-ns-proxy-autoconfig;
        add_header Content-Disposition 'inline; filename="proxy.pac"';
    }
}
EOF

# Cấu hình tường lửa
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

# Khởi động lại các dịch vụ
systemctl enable nginx
systemctl enable $SQUID_SERVICE
systemctl restart $SQUID_SERVICE
sleep 2
systemctl restart nginx
sleep 2

# Đảm bảo quyền truy cập cho PAC file
chmod 644 /var/www/html/proxy.pac
chown www-data:www-data /var/www/html/proxy.pac

# In ra thông tin kết nối
echo -e "\n${GREEN}$PUBLIC_IP:$PROXY_PORT $PROXY_USER:$PROXY_PASS${NC}"
echo -e "${GREEN}http://$PUBLIC_IP/proxy.pac${NC}"
