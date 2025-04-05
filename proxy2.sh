#!/bin/bash

# Script cài đặt HTTP to VMess Bridge
# Sử dụng trên Ubuntu server, không có xác thực HTTP

# Kiểm tra quyền root
if [[ $EUID -ne 0 ]]; then
   echo "Script này cần chạy với quyền root" 
   exit 1
fi

# Cài đặt các công cụ cần thiết
echo "Đang cài đặt các công cụ cần thiết..."
apt install -y curl wget unzip nginx

# Tạo thư mục cho V2Ray và PAC
echo "Đang tạo thư mục cấu hình..."
mkdir -p /usr/local/etc/v2ray
mkdir -p /var/www/html/pac

# Tải và cài đặt V2Ray
echo "Đang cài đặt V2Ray..."
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

# Tạo UUID cho VMess
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "UUID cho VMess của bạn là: $UUID"
echo "Vui lòng lưu lại UUID này để cấu hình client: $UUID"

# Lấy IP của máy chủ
SERVER_IP=$(curl -s https://api.ipify.org)
echo "IP máy chủ của bạn là: $SERVER_IP"

# Cấu hình V2Ray
echo "Đang tạo cấu hình V2Ray..."
cat > /usr/local/etc/v2ray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log"
  },
  "inbounds": [
    {
      "port": 8080,
      "protocol": "http",
      "settings": {
        "timeout": 300,
        "allowTransparent": false,
        "userLevel": 0
      },
      "tag": "http_in"
    },
    {
      "port": 10086,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp"
      },
      "tag": "vmess_in"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["http_in"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

# Tạo tệp PAC
echo "Đang tạo tệp PAC..."
cat > /var/www/html/pac/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Chuyển hướng TẤT CẢ các trang web qua proxy
    return "PROXY $SERVER_IP:8080; DIRECT";
}
EOF

# Cấu hình Nginx để phục vụ tệp PAC
echo "Đang cấu hình Nginx..."
cat > /etc/nginx/sites-available/pac << EOF
server {
    listen 80;
    server_name $SERVER_IP;

    location /pac/ {
        root /var/www/html;
        default_type application/x-ns-proxy-autoconfig;
    }
}
EOF

# Kích hoạt trang Nginx
ln -sf /etc/nginx/sites-available/pac /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

# Khởi động lại dịch vụ V2Ray
echo "Khởi động lại dịch vụ V2Ray..."
systemctl restart v2ray
systemctl status v2ray

# Đặt V2Ray tự động khởi động
systemctl enable v2ray
systemctl enable nginx

# Thiết lập tường lửa
echo "Cấu hình tường lửa..."
apt install -y ufw
ufw allow ssh
ufw allow 8080/tcp
ufw allow 10086/tcp
ufw allow 80/tcp
ufw --force enable

# Tóm tắt cài đặt
echo "======================="
echo "Cài đặt hoàn tất!"
echo "======================="
echo "IP máy chủ: $SERVER_IP"
echo "Cổng HTTP: 8080"
echo "Cổng VMess: 10086"
echo "UUID VMess: $UUID"
echo "URL của tệp PAC: http://$SERVER_IP/pac/proxy.pac"
echo "======================="
echo "Hướng dẫn cấu hình iPhone:"
echo "1. Vào Settings > Wi-Fi > (chọn mạng) > Configure Proxy"
echo "2. Chọn 'Automatic'"
echo "3. Nhập URL: http://$SERVER_IP/pac/proxy.pac"
echo "4. Lưu lại và kiểm tra kết nối"
echo "======================="
echo "Thông tin cấu hình VMess cho các ứng dụng khác:"
echo "- Địa chỉ: $SERVER_IP"
echo "- Cổng: 10086"
echo "- UUID: $UUID"
echo "- Protocol: VMess"
echo "- Transport: tcp"
echo "======================="
