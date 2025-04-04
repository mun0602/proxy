#!/bin/bash

# Script tự động cài đặt Squid với PAC file, xác thực và Cloudflare DNS
# Phiên bản bảo mật - thêm xác thực và sử dụng DNS của Cloudflare

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

# Tạo username và password ngẫu nhiên hoặc sử dụng tùy chọn dòng lệnh
generate_credentials() {
  if [ -z "$PROXY_USER" ]; then
    PROXY_USER="user$(openssl rand -hex 3)"
  fi
  
  if [ -z "$PROXY_PASS" ]; then
    PROXY_PASS="pass$(openssl rand -hex 6)"
  fi
  
  echo -e "${GREEN}Đã tạo thông tin xác thực:${NC}"
  echo -e "Username: ${YELLOW}$PROXY_USER${NC}"
  echo -e "Password: ${YELLOW}$PROXY_PASS${NC}"
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
echo -e "${GREEN}Đã chọn cổng ngẫu nhiên cho Squid: $PROXY_PORT${NC}"

# Sử dụng cổng 80 cho web server
HTTP_PORT=80
echo -e "${GREEN}Sử dụng cổng HTTP tiêu chuẩn: $HTTP_PORT${NC}"

# Tạo thông tin xác thực
generate_credentials

# Cài đặt các gói cần thiết
echo -e "${GREEN}Đang cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y squid apache2-utils nginx curl ufw netcat

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

# Tạo file mật khẩu cho Squid
echo -e "${GREEN}Đang tạo file xác thực...${NC}"
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
    echo -e "${RED}Không thể tìm thấy basic_ncsa_auth.${NC}"
    BASIC_AUTH_PATH="/usr/lib/squid/basic_ncsa_auth" # Đường dẫn mặc định
  fi
fi

# Tạo cấu hình Squid mới với xác thực và Cloudflare DNS
cat > "$SQUID_CONFIG_DIR/squid.conf" << EOF
# Cấu hình Squid tối ưu với xác thực và Cloudflare DNS
http_port $PROXY_PORT

# Cấu hình xác thực
auth_param basic program $BASIC_AUTH_PATH $SQUID_CONFIG_DIR/passwd
auth_param basic realm Proxy Authentication Required
auth_param basic credentialsttl 2 hours
acl authenticated_users proxy_auth REQUIRED

# Quyền truy cập cơ bản
http_access allow authenticated_users
http_access deny all

# Sử dụng DNS của Cloudflare
dns_nameservers 1.1.1.1 1.0.0.1

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

# Tạo PAC file - lưu ý không thể nhúng thông tin xác thực trực tiếp vào PAC
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
    
    // Sử dụng proxy cho mọi kết nối khác
    return "PROXY $PUBLIC_IP:$PROXY_PORT";
}
EOF

# Tạo trang chỉ dẫn với thông tin xác thực
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Proxy Configuration</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            line-height: 1.6;
            margin: 0;
            padding: 20px;
            color: #333;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            background: #f9f9f9;
            padding: 20px;
            border-radius: 5px;
            box-shadow: 0 0 10px rgba(0,0,0,0.1);
        }
        h1 {
            color: #2c3e50;
            border-bottom: 2px solid #3498db;
            padding-bottom: 10px;
        }
        h2 {
            color: #2980b9;
        }
        .credentials {
            background: #e8f4f8;
            padding: 15px;
            border-radius: 5px;
            margin: 15px 0;
        }
        .code {
            background: #f1f1f1;
            padding: 10px;
            border-radius: 3px;
            font-family: monospace;
            overflow-x: auto;
        }
        .important {
            color: #e74c3c;
            font-weight: bold;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Proxy Configuration</h1>
        
        <h2>Proxy Information</h2>
        <div class="credentials">
            <p><strong>Proxy Server:</strong> $PUBLIC_IP</p>
            <p><strong>Port:</strong> $PROXY_PORT</p>
            <p><strong>Username:</strong> $PROXY_USER</p>
            <p><strong>Password:</strong> $PROXY_PASS</p>
            <p><strong>Full URL:</strong> <span class="code">http://$PROXY_USER:$PROXY_PASS@$PUBLIC_IP:$PROXY_PORT</span></p>
        </div>
        
        <h2>Automatic Configuration (PAC)</h2>
        <p>Use this URL in your browser's proxy settings for automatic configuration:</p>
        <p class="code">http://$PUBLIC_IP/proxy.pac</p>
        <p class="important">Note: When using PAC file, you'll still need to enter username and password when prompted.</p>
        
        <h2>Manual Configuration</h2>
        <p>Alternatively, you can configure your proxy settings manually:</p>
        <ul>
            <li>Proxy Type: HTTP</li>
            <li>Proxy Server: $PUBLIC_IP</li>
            <li>Port: $PROXY_PORT</li>
            <li>Username: $PROXY_USER</li>
            <li>Password: $PROXY_PASS</li>
        </ul>
        
        <h2>Download PAC File</h2>
        <p><a href="/proxy.pac">Download PAC File</a></p>
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

# In ra thông tin kết nối
echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}CẤU HÌNH PROXY BẢO MẬT HOÀN TẤT!${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "IP:Port proxy: ${GREEN}$PUBLIC_IP:$PROXY_PORT${NC}"
echo -e "Username: ${GREEN}$PROXY_USER${NC}"
echo -e "Password: ${GREEN}$PROXY_PASS${NC}"
echo -e "URL PAC file: ${GREEN}http://$PUBLIC_IP/proxy.pac${NC}"
echo -e "URL thông tin: ${GREEN}http://$PUBLIC_IP/${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "${YELLOW}Lưu ý: Mặc dù PAC file đã được cấu hình, bạn vẫn cần nhập tài khoản và mật khẩu khi trình duyệt yêu cầu. ${NC}"
echo -e "${YELLOW}Truy cập http://$PUBLIC_IP/ để xem hướng dẫn đầy đủ và thông tin xác thực.${NC}"
