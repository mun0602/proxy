#!/bin/bash

# Script cài đặt HTTP to VMess Bridge
# Sử dụng trên Ubuntu server

# Kiểm tra quyền root
if [[ $EUID -ne 0 ]]; then
   echo "Script này cần chạy với quyền root" 
   exit 1
fi

# Cập nhật hệ thống
echo "Đang cập nhật hệ thống..."
apt update && apt upgrade -y

# Cài đặt các công cụ cần thiết
echo "Đang cài đặt các công cụ cần thiết..."
apt install -y curl wget unzip nginx apache2-utils

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

# Tạo tên người dùng và mật khẩu cho HTTP proxy
echo "Thiết lập xác thực cho HTTP proxy..."
echo -n "Nhập tên người dùng cho HTTP proxy: "
read HTTP_USER
echo -n "Nhập mật khẩu cho HTTP proxy: "
read -s HTTP_PASS
echo ""

# Tạo file mật khẩu
echo "Tạo file xác thực..."
htpasswd -bc /usr/local/etc/v2ray/http_auth $HTTP_USER $HTTP_PASS

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
        "accounts": [
          {
            "user": "$HTTP_USER",
            "pass": "$HTTP_PASS"
          }
        ],
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
    // Các trang web Trung Quốc phổ biến
    if (shExpMatch(host, "*.qq.com") || 
        shExpMatch(host, "*.weibo.com") || 
        shExpMatch(host, "*.baidu.com") || 
        shExpMatch(host, "*.douyin.com") ||
        shExpMatch(host, "*.tiktok.com") ||
        shExpMatch(host, "*.bilibili.com") ||
        shExpMatch(host, "*.zhihu.com") ||
        shExpMatch(host, "*.163.com") ||
        shExpMatch(host, "*.taobao.com") ||
        shExpMatch(host, "*.jd.com") ||
        shExpMatch(host, "*.alipay.com") ||
        shExpMatch(host, "*.youku.com") ||
        shExpMatch(host, "*.iqiyi.com") ||
        shExpMatch(host, "*.tmall.com")) {
        return "PROXY $SERVER_IP:8080; DIRECT";
    }
    
    // Truy cập trực tiếp các trang khác
    return "DIRECT";
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
echo "Tên người dùng HTTP: $HTTP_USER"
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
