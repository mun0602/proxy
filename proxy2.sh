#!/bin/bash

# Script tự động cài đặt Squid với PAC file - Phiên bản nâng cao
# Tối ưu cho Kuaishou, Douyin, WeChat

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

# Hàm để chọn cổng thường dùng bởi dịch vụ hợp pháp (ngụy trang)
get_common_port() {
  # Sử dụng các cổng phổ biến để tránh bị lọc
  COMMON_PORTS=(443 8443 8080 2096 2087 2083)
  SELECTED_PORT=${COMMON_PORTS[$RANDOM % ${#COMMON_PORTS[@]}]}
  
  # Kiểm tra xem cổng đã được sử dụng chưa
  if netstat -tuln | grep -q ":$SELECTED_PORT "; then
    # Nếu cổng đã được sử dụng, tạo một cổng ngẫu nhiên
    while true; do
      RANDOM_PORT=$(shuf -i 10000-65000 -n 1)
      if ! netstat -tuln | grep -q ":$RANDOM_PORT "; then
        echo $RANDOM_PORT
        return 0
      fi
    done
  else
    echo $SELECTED_PORT
  fi
}

# Hàm lấy địa chỉ IP công cộng
get_public_ip() {
  # Sử dụng nhiều dịch vụ để đảm bảo lấy được IP
  # Tránh sử dụng các dịch vụ phổ biến như ipify có thể bị chặn
  PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || 
              curl -s https://api.ipify.org || 
              curl -s https://ifconfig.me || 
              curl -s https://icanhazip.com || 
              curl -s https://ipinfo.io/ip)

  if [ -z "$PUBLIC_IP" ]; then
    echo -e "${YELLOW}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
    PUBLIC_IP=$(hostname -I | awk '{print $1}')
  fi
}

# Lấy cổng phổ biến cho Squid để ngụy trang
PROXY_PORT=$(get_common_port)
echo -e "${GREEN}Đã chọn cổng cho Squid: $PROXY_PORT${NC}"

# Sử dụng cổng 80 cho web server (cổng HTTP tiêu chuẩn)
HTTP_PORT=80
echo -e "${GREEN}Sử dụng cổng HTTP tiêu chuẩn: $HTTP_PORT${NC}"

# Cài đặt các gói cần thiết
echo -e "${GREEN}Đang cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y squid nginx curl ufw netcat apache2-utils openssl

# Tạo người dùng và mật khẩu ngẫu nhiên cho xác thực
PROXY_USER="user$(openssl rand -hex 3)"
PROXY_PASS="pass$(openssl rand -hex 6)"
echo -e "${GREEN}Tạo thông tin đăng nhập proxy:${NC}"
echo -e "Username: ${YELLOW}$PROXY_USER${NC}"
echo -e "Password: ${YELLOW}$PROXY_PASS${NC}"

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

# Tạo thư mục SSL cho Squid
mkdir -p $SQUID_CONFIG_DIR/ssl
chmod 700 $SQUID_CONFIG_DIR/ssl

# Tạo SSL certificate cho HTTPS proxy
echo -e "${GREEN}Đang tạo SSL certificate cho proxy HTTPS...${NC}"
openssl req -new -newkey rsa:2048 -sha256 -days 365 -nodes -x509 \
  -keyout $SQUID_CONFIG_DIR/ssl/squid.pem \
  -out $SQUID_CONFIG_DIR/ssl/squid.pem \
  -subj "/C=US/ST=State/L=City/O=Organization/CN=proxy.example.com"
chmod 400 $SQUID_CONFIG_DIR/ssl/squid.pem

# Tạo file mật khẩu cho xác thực
touch "$SQUID_CONFIG_DIR/passwd"
htpasswd -b -c "$SQUID_CONFIG_DIR/passwd" $PROXY_USER $PROXY_PASS

# Sao lưu cấu hình Squid gốc nếu tồn tại
if [ -f "$SQUID_CONFIG_DIR/squid.conf" ]; then
  cp "$SQUID_CONFIG_DIR/squid.conf" "$SQUID_CONFIG_DIR/squid.conf.bak"
fi

# Tạo cấu hình Squid nâng cao - HTTPS và xác thực
cat > "$SQUID_CONFIG_DIR/squid.conf" << EOF
# Cấu hình Squid nâng cao cho Kuaishou, Douyin, WeChat

# Cổng kết nối
http_port $PROXY_PORT
https_port $PROXY_PORT cert=$SQUID_CONFIG_DIR/ssl/squid.pem ssl-bump connection-auth=on

# SSL Bump
ssl_bump server-first all
sslcrtd_program /usr/lib/squid/security_file_certgen -s $SQUID_CONFIG_DIR/ssl_db -M 4MB
sslcrtd_children 8 startup=1 idle=1

# Xác thực
auth_param basic program /usr/lib/squid/basic_ncsa_auth $SQUID_CONFIG_DIR/passwd
auth_param basic realm Secure Proxy
auth_param basic credentialsttl 8 hours
acl authenticated proxy_auth REQUIRED

# Ngụy trang header
request_header_access Via deny all
request_header_access X-Forwarded-For deny all
request_header_access Cache-Control deny all
request_header_access Proxy-Connection deny all

# Ngụy trang User-Agent để giống browser thông thường
request_header_replace User-Agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# Tối ưu cho ứng dụng di động Trung Quốc
acl kuaishou dstdomain .kuaishou.com .gifshow.com .yxixy.com
acl douyin dstdomain .douyin.com .tiktokv.com .bytedance.com .iesdouyin.com .amemv.com
acl wechat dstdomain .wechat.com .weixin.qq.com .wx.qq.com .weixinbridge.com .wechat.com

# Trang kiểm tra IP và tốc độ
acl ipcheck dstdomain .ipleak.net .speedtest.net .fast.com .netflix.com .nflxvideo.net .nflximg.net .ooklaserver.net .cloudfront.net

# Ưu tiên băng thông cho các dịch vụ
delay_pools 1
delay_class 1 1
delay_parameters 1 -1/-1
delay_access 1 allow kuaishou douyin wechat ipcheck
delay_access 1 deny all

# Quyền truy cập
http_access allow authenticated 
http_access deny all

# Cài đặt DNS
dns_nameservers 8.8.8.8 8.8.4.4

# Tối ưu hiệu suất
cache_mem 512 MB
maximum_object_size 20 MB
cache_replacement_policy heap LFUDA
memory_replacement_policy heap LFUDA

# Tăng tốc độ kết nối
connect_timeout 30 seconds
request_timeout 60 seconds
read_timeout 60 seconds

# Cấu hình ẩn danh
forwarded_for off
via off

coredump_dir /var/spool/squid
EOF

# Tạo thư mục cho PAC file
mkdir -p /var/www/html

# Lấy địa chỉ IP công cộng
get_public_ip

# Tạo PAC file tối ưu cho các ứng dụng Trung Quốc và trang kiểm tra IP/tốc độ
cat > /var/www/html/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Các domain cần dùng proxy
    var proxy_domains = [
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
        
        // IP/Speed testing services
        ".ipleak.net",
        ".speedtest.net",
        ".fast.com",
        ".netflix.com",        // Needed for fast.com
        ".nflxvideo.net",      // Needed for fast.com
        ".nflximg.net",        // Needed for fast.com
        ".ooklaserver.net",    // Needed for speedtest.net
        ".cloudfront.net"      // Needed for various services
    ];
    
    // Kiểm tra IP trong dải Trung Quốc
    if (isInNet(dnsResolve(host), "58.14.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "58.16.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "58.24.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.128.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.132.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.136.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.139.0.0", "255.255.0.0")) {
        return "PROXY $PROXY_USER:$PROXY_PASS@$PUBLIC_IP:$PROXY_PORT";
    }
    
    // Kiểm tra domain trong danh sách
    for (var i = 0; i < proxy_domains.length; i++) {
        if (dnsDomainIs(host, proxy_domains[i]) || 
            shExpMatch(host, "*" + proxy_domains[i] + "*")) {
            return "PROXY $PROXY_USER:$PROXY_PASS@$PUBLIC_IP:$PROXY_PORT";
        }
    }
    
    // Mặc định truy cập trực tiếp
    return "DIRECT";
}
EOF

# Tạo một file JavaScript để truy cập proxy trực tiếp (cho ứng dụng mobile)
cat > /var/www/html/config.js << EOF
var proxyConfig = {
    "server": "$PUBLIC_IP",
    "port": $PROXY_PORT,
    "username": "$PROXY_USER",
    "password": "$PROXY_PASS",
    "type": "https"
};
EOF

# Cấu hình Nginx để phục vụ PAC file với bảo mật
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
        
        # Thêm các header bảo mật
        add_header X-Content-Type-Options "nosniff";
        add_header X-Frame-Options "DENY";
        add_header X-XSS-Protection "1; mode=block";
    }
    
    location /config.js {
        types { }
        default_type application/javascript;
        
        # Thêm các header bảo mật
        add_header X-Content-Type-Options "nosniff";
        add_header X-Frame-Options "DENY";
        add_header X-XSS-Protection "1; mode=block";
    }
    
    # Chặn truy cập các file hệ thống
    location ~ /\.ht {
        deny all;
    }
}
EOF

# Tạo trang index đơn giản chỉ hiển thị thông tin cơ bản
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Proxy Info</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
</head>
<body>
    <h3>Proxy: $PUBLIC_IP:$PROXY_PORT</h3>
    <p>User: $PROXY_USER</p>
    <p>Pass: $PROXY_PASS</p>
    <p><a href="/proxy.pac">PAC File</a></p>
</body>
</html>
EOF

# Tạo thư mục SSL DB cho Squid
mkdir -p $SQUID_CONFIG_DIR/ssl_db
chown -R proxy:proxy $SQUID_CONFIG_DIR/ssl_db

# Cấu hình tường lửa
echo -e "${GREEN}Đang cấu hình tường lửa...${NC}"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow $HTTP_PORT/tcp
ufw allow $PROXY_PORT/tcp
ufw --force enable

# Tạo script rotator IP (cho tương lai)
cat > /usr/local/bin/rotate-proxy-ip.sh << EOF
#!/bin/bash
# Script xoay vòng IP hoặc cập nhật cấu hình
# Để sử dụng, chạy lệnh: sudo /usr/local/bin/rotate-proxy-ip.sh

# Lấy IP công cộng mới
NEW_IP=\$(curl -s https://checkip.amazonaws.com || curl -s https://api.ipify.org)

# Cập nhật PAC file
sed -i "s/return \"PROXY .* /return \"PROXY $PROXY_USER:$PROXY_PASS@\$NEW_IP:$PROXY_PORT\";/" /var/www/html/proxy.pac
sed -i "s/\"server\": \".*\"/\"server\": \"\$NEW_IP\"/" /var/www/html/config.js

echo "Đã cập nhật IP thành \$NEW_IP"
EOF
chmod +x /usr/local/bin/rotate-proxy-ip.sh

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
echo -e "${GREEN}CẤU HÌNH PROXY NÂNG CAO HOÀN TẤT!${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "IP:Port proxy: ${GREEN}$PUBLIC_IP:$PROXY_PORT${NC}"
echo -e "Username: ${GREEN}$PROXY_USER${NC}"
echo -e "Password: ${GREEN}$PROXY_PASS${NC}"
echo -e "URL PAC file: ${GREEN}http://$PUBLIC_IP/proxy.pac${NC}"
echo -e "Tối ưu cho: ${GREEN}Kuaishou, Douyin, WeChat${NC}"
echo -e "${GREEN}============================================${NC}"

# Đề xuất lên lịch xoay vòng IP
echo -e "\n${YELLOW}Đề xuất: Để tránh bị chặn, bạn nên sử dụng crontab để xoay vòng IP định kỳ:${NC}"
echo -e "  ${GREEN}crontab -e${NC}"
echo -e "Sau đó thêm dòng sau để chạy mỗi 6 giờ:"
echo -e "  ${GREEN}0 */6 * * * /usr/local/bin/rotate-proxy-ip.sh${NC}"
