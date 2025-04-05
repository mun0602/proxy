#!/bin/bash

# Script thiết lập PAC Bridge với Shadowsocks (Phiên bản tối ưu)
# Script này thiết lập hệ thống hoàn chỉnh để chuyển TẤT CẢ lưu lượng qua Shadowsocks proxy

# =================== FUNCTIONS ===================
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

print_warning() {
    echo -e "\e[1;33m$1\e[0m"
}

print_section() {
    echo ""
    print_msg "======================================================"
    print_msg "   $1"
    print_msg "======================================================"
    echo ""
}

# Kiểm tra lỗi và thoát nếu lệnh thất bại
check_error() {
    if [ $? -ne 0 ]; then
        print_error "$1"
        exit 1
    fi
}

# Kiểm tra trạng thái dịch vụ
check_service() {
    if systemctl is-active --quiet $1; then
        print_success "$2: Đang chạy"
        return 0
    else
        print_error "$2: Không chạy"
        return 1
    fi
}

# Kiểm tra cài đặt gói
check_package() {
    if dpkg -s $1 &> /dev/null; then
        print_success "Gói $1: Đã cài đặt"
        return 0
    else
        print_error "Gói $1: Chưa cài đặt"
        return 1
    fi
}

# Kiểm tra kết nối internet
check_internet() {
    print_msg "Kiểm tra kết nối Internet..."
    if ping -c 1 8.8.8.8 &> /dev/null || ping -c 1 1.1.1.1 &> /dev/null; then
        print_success "Kết nối Internet: OK"
        return 0
    else
        print_error "Kết nối Internet: Không thể kết nối"
        return 1
    fi
}

# Kiểm tra cổng đang lắng nghe
check_port() {
    if netstat -tuln | grep -q ":$1 "; then
        print_success "Cổng $1: Đang lắng nghe"
        return 0
    else
        print_error "Cổng $1: Không lắng nghe"
        return 1
    fi
}

# Kiểm tra quyền root
if [[ $EUID -ne 0 ]]; then
   print_error "Script này cần được chạy với quyền root. Vui lòng sử dụng sudo."
   exit 1
fi

# =================== MAIN SCRIPT ===================
# Thông báo chào mừng
clear
print_section "Thiết lập Shadowsocks PAC Bridge cho Ubuntu (Phiên bản tối ưu)"

echo "Script này sẽ thiết lập hệ thống hoàn chỉnh để chuyển TẤT CẢ lưu lượng truy cập qua Shadowsocks:"
echo "✓ Máy chủ Shadowsocks-libev"
echo "✓ SS-local client để kết nối tới máy chủ Shadowsocks"
echo "✓ Privoxy làm HTTP-to-SOCKS bridge"
echo "✓ Nginx web server để phục vụ tệp PAC"
echo "✓ Cấu hình tệp PAC chuyển TẤT CẢ lưu lượng qua proxy"
echo "✓ Thiết lập tường lửa và tự động khởi động dịch vụ"
echo ""

# Kiểm tra kết nối internet
check_internet
check_error "Cần có kết nối Internet để tiếp tục."

# =================== INSTALLATION ===================
print_section "Đang chuẩn bị hệ thống"

# Lấy địa chỉ IP công khai
print_msg "Đang phát hiện địa chỉ IP công khai của máy chủ..."
SERVER_IP=$(curl -s -4 https://api.ipify.org || curl -s -4 https://ifconfig.me || curl -s -4 https://icanhazip.com)

if [[ -z "$SERVER_IP" ]]; then
    print_error "Không thể tự động phát hiện IP máy chủ."
    read -p "Vui lòng nhập địa chỉ IP công khai của máy chủ: " SERVER_IP
    if [[ -z "$SERVER_IP" ]]; then
        print_error "Cần có địa chỉ IP để tiếp tục."
        exit 1
    fi
else
    print_success "Đã phát hiện IP máy chủ: $SERVER_IP"
fi

# Cập nhật danh sách gói
print_msg "Đang cập nhật danh sách gói phần mềm..."
apt update
check_error "Không thể cập nhật danh sách gói phần mềm."

# Cài đặt các gói phụ thuộc
print_msg "Đang cài đặt các công cụ cần thiết..."
apt install -y curl wget gnupg2 ca-certificates lsb-release apt-transport-https net-tools
check_error "Không thể cài đặt các công cụ cần thiết."

# =================== SHADOWSOCKS SETUP ===================
print_section "Thiết lập Shadowsocks"

# Cấu hình Shadowsocks
DEFAULT_PORT=$((RANDOM % 50000 + 10000))
read -p "Nhập cổng cho máy chủ Shadowsocks [mặc định: $DEFAULT_PORT]: " SS_PORT
SS_PORT=${SS_PORT:-$DEFAULT_PORT}

DEFAULT_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
read -p "Nhập mật khẩu cho Shadowsocks [mặc định: $DEFAULT_PASSWORD]: " SS_PASSWORD
SS_PASSWORD=${SS_PASSWORD:-$DEFAULT_PASSWORD}

echo ""
echo "Phương thức mã hóa khả dụng:"
echo "1) chacha20-ietf-poly1305 (khuyến nghị)"
echo "2) aes-256-gcm"
echo "3) aes-128-gcm"
read -p "Chọn phương thức mã hóa [mặc định: 1]: " encryption_choice

case $encryption_choice in
    2) SS_METHOD="aes-256-gcm" ;;
    3) SS_METHOD="aes-128-gcm" ;;
    *) SS_METHOD="chacha20-ietf-poly1305" ;;
esac

# Cổng cho dịch vụ
SS_LOCAL_PORT=1080
PRIVOXY_PORT=8118
NGINX_PORT=8080

# Cài đặt Shadowsocks-libev
print_msg "Đang cài đặt Shadowsocks-libev..."
apt install -y shadowsocks-libev
check_error "Không thể cài đặt Shadowsocks-libev."
check_package "shadowsocks-libev"

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
    "nameserver":"8.8.8.8,1.1.1.1",
    "mode":"tcp_and_udp"
}
EOF
check_error "Không thể tạo file cấu hình Shadowsocks server."

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
    "nameserver":"8.8.8.8,1.1.1.1",
    "mode":"tcp_and_udp"
}
EOF
check_error "Không thể tạo file cấu hình ss-local."

# Tạo dịch vụ ss-local systemd nếu chưa có
if [ ! -f /etc/systemd/system/ss-local.service ]; then
    print_msg "Đang thiết lập dịch vụ ss-local..."
    cat > /etc/systemd/system/ss-local.service <<EOF
[Unit]
Description=Shadowsocks Local Client Service
After=network.target shadowsocks-libev.service
Wants=shadowsocks-libev.service

[Service]
Type=simple
ExecStart=/usr/bin/ss-local -c /etc/shadowsocks-libev/local.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    check_error "Không thể tạo file dịch vụ ss-local."
fi

# =================== PRIVOXY SETUP ===================
print_section "Thiết lập Privoxy"

# Cài đặt Privoxy
print_msg "Đang cài đặt Privoxy..."
apt install -y privoxy
check_error "Không thể cài đặt Privoxy."
check_package "privoxy"

# Cấu hình Privoxy để nhận kết nối từ bên ngoài và chuyển qua SOCKS5
print_msg "Đang cấu hình Privoxy để chấp nhận kết nối từ mọi nguồn..."
cat > /etc/privoxy/config <<EOF
# Cấu hình Privoxy làm HTTP-to-SOCKS bridge

# Lắng nghe trên tất cả giao diện
listen-address 0.0.0.0:$PRIVOXY_PORT

# Tắt các tính năng không cần thiết để tối ưu hóa hiệu suất
toggle 0
enable-remote-toggle 0
enable-remote-http-toggle 0
enable-edit-actions 0
enforce-blocks 0

# Cải thiện hiệu suất
buffer-limit 8192
forwarded-connect-retries 1
accept-intercepted-requests 1
allow-cgi-request-crunching 0
split-large-forms 0
keep-alive-timeout 300
socket-timeout 300
max-client-connections 512

# Chuyển tiếp tất cả kết nối qua SOCKS5 (Shadowsocks)
forward-socks5 / 127.0.0.1:$SS_LOCAL_PORT .

# Log minimal
debug 0
logfile /var/log/privoxy/privoxy.log
EOF
check_error "Không thể tạo file cấu hình Privoxy."

# =================== NGINX SETUP ===================
print_section "Thiết lập Nginx và PAC file"

# Cài đặt Nginx
print_msg "Đang cài đặt Nginx..."
apt install -y nginx
check_error "Không thể cài đặt Nginx."
check_package "nginx"

# Tạo thư mục cho tệp PAC
mkdir -p /var/www/pac
check_error "Không thể tạo thư mục cho tệp PAC."

# Tạo tệp PAC được tối ưu để chuyển TẤT CẢ lưu lượng qua proxy
print_msg "Đang tạo tệp PAC được tối ưu..."
cat > /var/www/pac/proxy.pac <<EOF
function FindProxyForURL(url, host) {
    // Loại trừ các địa chỉ nội bộ và localhost
    if (isPlainHostName(host) ||
        shExpMatch(host, "localhost") ||
        shExpMatch(host, "*.local") ||
        isInNet(dnsResolve(host), "10.0.0.0", "255.0.0.0") ||
        isInNet(dnsResolve(host), "172.16.0.0", "255.240.0.0") ||
        isInNet(dnsResolve(host), "192.168.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "127.0.0.0", "255.0.0.0")) {
        return "DIRECT";
    }
    
    // Chuyển TẤT CẢ lưu lượng khác qua proxy
    return "PROXY $SERVER_IP:$PRIVOXY_PORT";
}
EOF
check_error "Không thể tạo tệp PAC."

# Cấu hình Nginx để phục vụ tệp PAC với mime type chính xác
print_msg "Đang cấu hình Nginx để phục vụ tệp PAC..."
cat > /etc/nginx/sites-available/pac <<EOF
server {
    listen $NGINX_PORT default_server;
    listen [::]:$NGINX_PORT default_server;
    
    root /var/www/pac;
    index proxy.pac;
    
    server_name _;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    location /proxy.pac {
        default_type application/x-ns-proxy-autoconfig;
        add_header Cache-Control "no-cache";
    }
}
EOF
check_error "Không thể tạo cấu hình Nginx."

# Kích hoạt site Nginx và tắt cấu hình mặc định
ln -sf /etc/nginx/sites-available/pac /etc/nginx/sites-enabled/
check_error "Không thể kích hoạt cấu hình Nginx."

if [ -f /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
fi

# =================== FIREWALL SETUP ===================
print_section "Thiết lập Tường lửa"

# Cài đặt UFW nếu chưa có
print_msg "Đang thiết lập tường lửa..."
apt install -y ufw
check_error "Không thể cài đặt UFW."

# Cấu hình tường lửa
ufw allow ssh
ufw allow $SS_PORT/tcp
ufw allow $SS_PORT/udp
ufw allow $PRIVOXY_PORT/tcp
ufw allow $NGINX_PORT/tcp

print_warning "CẢNH BÁO: Kích hoạt tường lửa có thể ngắt kết nối SSH của bạn nếu SSH không chạy trên cổng mặc định."
read -p "Bạn có muốn kích hoạt tường lửa? (y/n): " enable_ufw

if [[ "$enable_ufw" =~ ^[Yy]$ ]]; then
    print_msg "Đang kích hoạt tường lửa..."
    ufw --force enable
    check_error "Kích hoạt tường lửa thất bại!"
    print_success "Tường lửa đã được kích hoạt thành công."
else
    print_warning "Tường lửa chưa được kích hoạt. Hãy kích hoạt thủ công sau khi kiểm tra cấu hình."
fi

# =================== SERVICE ACTIVATION ===================
print_section "Khởi động và kích hoạt dịch vụ"

# Kích hoạt và khởi động tất cả dịch vụ
print_msg "Đang khởi động lại và kích hoạt tất cả dịch vụ..."
systemctl daemon-reload

# Restart và enable các dịch vụ
services=("shadowsocks-libev" "ss-local" "privoxy" "nginx")
for service in "${services[@]}"; do
    print_msg "Đang khởi động lại và kích hoạt dịch vụ $service..."
    systemctl restart $service
    systemctl enable $service
    if [ $? -ne 0 ]; then
        print_error "Không thể khởi động dịch vụ $service. Vui lòng kiểm tra logs: journalctl -u $service"
    fi
done

# =================== VERIFICATION ===================
print_section "Kiểm tra hệ thống"

# Kiểm tra trạng thái dịch vụ
check_service "shadowsocks-libev" "Máy chủ Shadowsocks"
check_service "ss-local" "SS-Local Client"
check_service "privoxy" "Privoxy"
check_service "nginx" "Nginx"

# Kiểm tra các cổng đang lắng nghe
print_msg "Kiểm tra các cổng đang lắng nghe..."
check_port "$SS_PORT"
check_port "$SS_LOCAL_PORT"
check_port "$PRIVOXY_PORT"
check_port "$NGINX_PORT"

# Thử kết nối đến tệp PAC
print_msg "Kiểm tra khả năng truy cập tệp PAC..."
pac_response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$NGINX_PORT/proxy.pac)
if [ "$pac_response" == "200" ]; then
    print_success "Tệp PAC có thể truy cập: http://$SERVER_IP:$NGINX_PORT/proxy.pac"
else
    print_error "Không thể truy cập tệp PAC. HTTP code: $pac_response"
    print_warning "Vui lòng kiểm tra cấu hình Nginx và thử lại."
fi

# =================== COMPLETION ===================
print_section "Thiết lập hoàn tất!"

echo "Hệ thống PAC Bridge đã được cấu hình thành công với các thông số sau:"
echo ""
echo "✓ IP máy chủ Shadowsocks: $SERVER_IP"
echo "✓ Cổng Shadowsocks: $SS_PORT"
echo "✓ Mật khẩu Shadowsocks: $SS_PASSWORD"
echo "✓ Phương thức mã hóa: $SS_METHOD"
echo "✓ Cổng Privoxy HTTP Proxy: $PRIVOXY_PORT"
echo "✓ URL tệp PAC: http://$SERVER_IP:$NGINX_PORT/proxy.pac"
echo ""

print_msg "HƯỚNG DẪN CẤU HÌNH:"
echo ""
echo "1. Trên iPhone/iPad:"
echo "   - Vào Cài đặt > Wi-Fi"
echo "   - Nhấn vào biểu tượng (i) bên cạnh mạng Wi-Fi đang kết nối"
echo "   - Cuộn xuống và chọn 'Cấu hình Proxy'"
echo "   - Chọn 'Tự động'"
echo "   - Nhập URL tệp PAC: http://$SERVER_IP:$NGINX_PORT/proxy.pac"
echo "   - Nhấn 'Lưu'"
echo ""
echo "2. Trên Android:"
echo "   - Vào Cài đặt > Wi-Fi"
echo "   - Nhấn giữ mạng Wi-Fi đang kết nối"
echo "   - Chọn 'Sửa mạng'"
echo "   - Mở rộng 'Tùy chọn nâng cao'"
echo "   - Chọn 'Proxy' > 'Tự động'"
echo "   - Nhập URL tệp PAC: http://$SERVER_IP:$NGINX_PORT/proxy.pac"
echo "   - Nhấn 'Lưu'"
echo ""
echo "3. Trên Windows/Mac/Linux:"
echo "   - Vào cài đặt mạng/proxy của hệ thống"
echo "   - Chọn chế độ 'Tự động phát hiện cài đặt' hoặc 'Sử dụng script cấu hình tự động'"
echo "   - Nhập URL tệp PAC: http://$SERVER_IP:$NGINX_PORT/proxy.pac"
echo ""

print_msg "Để kiểm tra xem proxy có hoạt động không:"
echo "1. Truy cập trang web: https://ipleak.net"
echo "2. IP hiển thị phải là IP của máy chủ proxy ($SERVER_IP), không phải IP thực của bạn"
echo ""

print_msg "Lưu thông tin quan trọng này để tham khảo trong tương lai!"
echo "Kết thúc thiết lập."
