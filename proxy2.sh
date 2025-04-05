#!/bin/bash

# PAC Bridge Setup Script cho Ubuntu
# Script này thiết lập một hệ thống hoàn chỉnh PAC file bridge tới Shadowsocks

# Hiển thị văn bản có màu
print_msg() {
    echo -e "\e[1;34m$1\e[0m"
}

print_success() {
    echo -e "\e[1;32m$1\e[0m"
}

print_error() {
    echo -e "\e[1;31m$1\e[0m"
}

# Kiểm tra quyền root
if [[ $EUID -ne 0 ]]; then
   print_error "Script này cần được chạy với quyền root. Vui lòng sử dụng sudo."
   exit 1
fi

# Thông báo chào mừng
clear
print_msg "======================================================"
print_msg "   Thiết lập Shadowsocks PAC Bridge cho Ubuntu"
print_msg "======================================================"
echo ""
print_msg "Script này sẽ thiết lập:"
echo "- Máy chủ Shadowsocks-libev"
echo "- SS-local client"
echo "- Privoxy làm HTTP-to-SOCKS bridge"
echo "- Nginx web server để phục vụ tệp PAC"
echo "- Cấu hình tệp PAC"
echo "- Thiết lập tường lửa"
echo "- Tự động khởi động tất cả các dịch vụ"
echo ""
print_msg "Bắt đầu thiết lập..."
echo ""

# Lấy địa chỉ IP công khai của máy chủ
print_msg "Đang phát hiện địa chỉ IP công khai của máy chủ..."
SERVER_IP=$(curl -s https://api.ipify.org)
if [[ -z "$SERVER_IP" ]]; then
    print_error "Không thể tự động phát hiện IP máy chủ."
    read -p "Vui lòng nhập địa chỉ IP công khai của máy chủ: " SERVER_IP
else
    print_success "Đã phát hiện IP máy chủ: $SERVER_IP"
fi

# Lấy cấu hình từ người dùng
echo ""
print_msg "Thiết lập cấu hình Shadowsocks:"
echo ""

# Tạo cổng ngẫu nhiên từ 10000 đến 60000
DEFAULT_PORT=$((RANDOM % 50000 + 10000))
read -p "Nhập cổng cho máy chủ Shadowsocks [mặc định: $DEFAULT_PORT]: " SS_PORT
SS_PORT=${SS_PORT:-$DEFAULT_PORT}

# Tạo mật khẩu ngẫu nhiên an toàn
DEFAULT_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
read -p "Nhập mật khẩu cho Shadowsocks [mặc định: $DEFAULT_PASSWORD]: " SS_PASSWORD
SS_PASSWORD=${SS_PASSWORD:-$DEFAULT_PASSWORD}

# Liệt kê phương thức mã hóa
echo ""
echo "Phương thức mã hóa khả dụng:"
echo "1) chacha20-ietf-poly1305 (khuyến nghị)"
echo "2) aes-256-gcm"
echo "3) aes-128-gcm"
echo "4) aes-256-cfb"
echo "5) aes-128-cfb"
read -p "Chọn phương thức mã hóa [mặc định: 1]: " encryption_choice
echo ""

case $encryption_choice in
    2) SS_METHOD="aes-256-gcm" ;;
    3) SS_METHOD="aes-128-gcm" ;;
    4) SS_METHOD="aes-256-cfb" ;;
    5) SS_METHOD="aes-128-cfb" ;;
    *) SS_METHOD="chacha20-ietf-poly1305" ;;
esac

# Cổng cho ss-local và Privoxy
SS_LOCAL_PORT=1080
PRIVOXY_PORT=8118
NGINX_PORT=8080

# Cập nhật danh sách gói
print_msg "Đang cập nhật danh sách gói phần mềm..."
apt update || { print_error "Không thể cập nhật danh sách gói phần mềm."; exit 1; }

# Cài đặt các gói phụ thuộc
print_msg "Đang cài đặt các gói phần mềm cần thiết..."
apt install -y curl wget gnupg2 ca-certificates lsb-release apt-transport-https || {
    print_error "Không thể cài đặt các gói phụ thuộc."; 
    exit 1; 
}

# Cài đặt Shadowsocks-libev
print_msg "Đang cài đặt Shadowsocks-libev..."
apt install -y shadowsocks-libev || { 
    print_error "Không thể cài đặt Shadowsocks-libev.";
    exit 1; 
}

# Cấu hình Shadowsocks server
print_msg "Đang cấu hình máy chủ Shadowsocks..."
cat > /etc/shadowsocks-libev/config.json <<EOF
{
    "server":"0.0.0.0",
    "server_port":$SS_PORT,
    "password":"$SS_PASSWORD",
    "timeout":300,
    "method":"$SS_METHOD",
    "fast_open":true,
    "nameserver":"8.8.8.8",
    "mode":"tcp_and_udp"
}
EOF

# Cấu hình ss-local
print_msg "Đang cấu hình ss-local client..."
cat > /etc/shadowsocks-libev/local.json <<EOF
{
    "server":"127.0.0.1",
    "server_port":$SS_PORT,
    "local_address":"127.0.0.1",
    "local_port":$SS_LOCAL_PORT,
    "password":"$SS_PASSWORD",
    "timeout":300,
    "method":"$SS_METHOD",
    "fast_open":true,
    "nameserver":"8.8.8.8",
    "mode":"tcp_and_udp"
}
EOF

# Tạo dịch vụ ss-local systemd
print_msg "Đang thiết lập dịch vụ ss-local..."
cat > /etc/systemd/system/ss-local.service <<EOF
[Unit]
Description=Shadowsocks Local Client Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/ss-local -c /etc/shadowsocks-libev/local.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Cài đặt Privoxy
print_msg "Đang cài đặt và cấu hình Privoxy..."
apt install -y privoxy || {
    print_error "Không thể cài đặt Privoxy.";
    exit 1;
}

# Cấu hình Privoxy
cat > /etc/privoxy/config <<EOF
listen-address  127.0.0.1:$PRIVOXY_PORT
toggle  1
enable-remote-toggle  0
enable-remote-http-toggle  0
enable-edit-actions 0
enforce-blocks 0
buffer-limit 4096
forwarded-connect-retries  0
accept-intercepted-requests 0
allow-cgi-request-crunching 0
split-large-forms 0
keep-alive-timeout 5
socket-timeout 60
forward-socks5 / 127.0.0.1:$SS_LOCAL_PORT .
EOF

# Cài đặt Nginx
print_msg "Đang cài đặt và cấu hình Nginx..."
apt install -y nginx || {
    print_error "Không thể cài đặt Nginx.";
    exit 1;
}

# Tạo thư mục cho tệp PAC
mkdir -p /var/www/pac

# Tạo tệp PAC
print_msg "Đang tạo tệp PAC..."
cat > /var/www/pac/proxy.pac <<EOF
function FindProxyForURL(url, host) {
    // Các domain cần đi qua proxy
    var domains = [
        "kuaishou.com",
        "wechat",
        "douyin",
        "ipleak.net",
        "speedtest.net"
    ];
    
    // Kiểm tra xem host có phù hợp với bất kỳ domain nào
    for (var i = 0; i < domains.length; i++) {
        var pattern = domains[i];
        if (shExpMatch(host, "*." + pattern + "*") || 
            shExpMatch(host, pattern)) {
            return "PROXY $SERVER_IP:$PRIVOXY_PORT";
        }
    }
    
    // Mặc định: kết nối trực tiếp
    return "DIRECT";
}
EOF

# Cấu hình Nginx để phục vụ tệp PAC
cat > /etc/nginx/sites-available/pac <<EOF
server {
    listen $NGINX_PORT default_server;
    server_name _;
    
    location / {
        root /var/www/pac;
        add_header Content-Type "application/x-ns-proxy-autoconfig";
    }
}
EOF

# Kích hoạt site Nginx
ln -sf /etc/nginx/sites-available/pac /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Cấu hình tường lửa UFW
print_msg "Đang cấu hình tường lửa..."
apt install -y ufw || {
    print_error "Không thể cài đặt UFW.";
    exit 1;
}

ufw allow $SS_PORT/tcp
ufw allow $SS_PORT/udp
ufw allow $NGINX_PORT/tcp
ufw allow ssh

# Hỏi trước khi kích hoạt UFW
echo ""
read -p "Bạn có muốn kích hoạt tường lửa? Điều này có thể ngắt kết nối SSH nếu không dùng cổng 22. (y/n): " enable_ufw
if [[ "$enable_ufw" =~ ^[Yy]$ ]]; then
    ufw --force enable
    print_success "Tường lửa đã được kích hoạt và cấu hình."
else
    print_msg "Cấu hình tường lửa đã được lưu nhưng chưa kích hoạt."
fi

# Kích hoạt và khởi động tất cả dịch vụ
print_msg "Đang khởi động và kích hoạt tất cả dịch vụ..."
systemctl daemon-reload
systemctl enable --now shadowsocks-libev.service
systemctl enable --now ss-local.service
systemctl enable --now privoxy.service
systemctl enable --now nginx.service

# Khởi động lại dịch vụ để áp dụng thay đổi
systemctl restart shadowsocks-libev.service
systemctl restart privoxy.service
systemctl restart nginx.service

# Kiểm tra cuối cùng
SS_STATUS=$(systemctl is-active shadowsocks-libev.service)
SS_LOCAL_STATUS=$(systemctl is-active ss-local.service)
PRIVOXY_STATUS=$(systemctl is-active privoxy.service)
NGINX_STATUS=$(systemctl is-active nginx.service)

echo ""
print_msg "======================================================"
print_msg "         Thiết lập Hoàn Tất! Trạng thái Dịch vụ:     "
print_msg "======================================================"
echo ""
echo "Máy chủ Shadowsocks: $SS_STATUS"
echo "SS-Local Client: $SS_LOCAL_STATUS"
echo "Privoxy: $PRIVOXY_STATUS"
echo "Nginx: $NGINX_STATUS"
echo ""
print_msg "Máy chủ Shadowsocks của bạn đã được cấu hình với:"
echo "IP: $SERVER_IP"
echo "Cổng: $SS_PORT"
echo "Mật khẩu: $SS_PASSWORD"
echo "Phương thức mã hóa: $SS_METHOD"
echo ""
print_msg "Tệp PAC có thể truy cập tại:"
echo "http://$SERVER_IP:$NGINX_PORT/proxy.pac"
echo ""
print_msg "Để cấu hình PAC trên iPhone:"
echo "1. Vào Cài đặt > Wi-Fi"
echo "2. Nhấn vào biểu tượng (i) bên cạnh mạng đang kết nối"
echo "3. Cuộn xuống đến 'Cấu hình Proxy'"
echo "4. Chọn 'Tự động'"
echo "5. Nhập URL tệp PAC: http://$SERVER_IP:$NGINX_PORT/proxy.pac"
echo "6. Nhấn 'Lưu'"
echo ""
print_success "Thiết lập hoàn tất thành công!"
