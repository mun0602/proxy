#!/bin/bash

# Màu sắc cho output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Vui lòng chạy script với quyền root (sudo)${NC}"
  exit 1
fi

echo -e "${BLUE}=== SCRIPT TỐI ƯU V2RAY VỚI 2GB RAM ẢO ===${NC}"

# Lấy địa chỉ IP công cộng
PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || curl -s https://api.ipify.org || curl -s https://ifconfig.me)
if [ -z "$PUBLIC_IP" ]; then
  echo -e "${YELLOW}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
  PUBLIC_IP=$(hostname -I | awk '{print $1}')
fi

# Thông số cấu hình
HTTP_BRIDGE_PORT=8118
V2RAY_PORT=10086
INTERNAL_V2RAY_PORT=10087
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/$(head /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)"

#############################################
# PHẦN 1: CẤU HÌNH HỆ THỐNG VÀ RAM ẢO
#############################################

echo -e "${GREEN}[1/7] Cấu hình hệ thống và RAM ảo...${NC}"

# Tạo 2GB swap
echo -e "${YELLOW}Tạo 2GB RAM ảo (swap)...${NC}"
# Xóa swap cũ nếu có
swapoff -a
rm -f /swapfile

# Tạo swap mới
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab

# Cấu hình swap
echo -e "${YELLOW}Tối ưu cấu hình swap...${NC}"
cat > /etc/sysctl.d/99-swap.conf << EOF
# Giảm swappiness để ưu tiên sử dụng RAM
vm.swappiness = 10
# Tăng giá trị cache để cải thiện hiệu suất
vm.vfs_cache_pressure = 50
# Tối ưu hóa kết nối mạng
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_fastopen = 3
EOF
sysctl -p /etc/sysctl.d/99-swap.conf

# Tối ưu hóa limits.conf cho hiệu suất
cat > /etc/security/limits.d/proxy-limits.conf << EOF
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

echo -e "${GREEN}✅ RAM ảo và cấu hình hệ thống đã được tối ưu hóa${NC}"

#############################################
# PHẦN 2: CÀI ĐẶT PHẦN MỀM
#############################################

echo -e "${GREEN}[2/7] Cài đặt các gói cần thiết...${NC}"
apt update -y
# Sử dụng apt-fast thay vì apt để tăng tốc độ tải xuống
if ! command -v apt-fast > /dev/null; then
  apt install -y software-properties-common
  add-apt-repository -y ppa:apt-fast/stable
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y apt-fast
  apt-fast update
else
  apt update
fi

# Cài đặt các gói cần thiết
apt-fast install -y nginx curl wget unzip jq htop apparmor lsb-release ca-certificates preload zlib1g-dev

# Tối ưu preload
echo -e "${YELLOW}Tối ưu hóa preload...${NC}"
cat > /etc/preload.conf << EOF
[memload]
# Tăng cache thêm 20%
memloadcycle = 120
ioprio = 3

[processes]
expiretime = 14
autosave = 60

[statfs]
timeout = 3600

[system]
maxsize = 303
EOF
systemctl enable preload
systemctl restart preload

#############################################
# PHẦN 3: CÀI ĐẶT GOST (HTTP BRIDGE)
#############################################

echo -e "${GREEN}[3/7] Cài đặt và tối ưu GOST HTTP Bridge...${NC}"
mkdir -p /tmp/gost
cd /tmp/gost
wget -q https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
gunzip gost-linux-amd64-2.11.5.gz
mv gost-linux-amd64-2.11.5 /usr/local/bin/gost
chmod +x /usr/local/bin/gost

# Cấu hình GOST với tối ưu hiệu suất
cat > /etc/systemd/system/gost-bridge.service << EOF
[Unit]
Description=GOST HTTP-VMess Bridge
After=network.target v2ray.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -L http://:$HTTP_BRIDGE_PORT -F tcp://127.0.0.1:$INTERNAL_V2RAY_PORT
Restart=always
RestartSec=3
LimitNOFILE=65535

# Tối ưu hiệu suất
CPUSchedulingPolicy=batch
IOSchedulingClass=best-effort
IOSchedulingPriority=0
MemoryDenyWriteExecute=no

[Install]
WantedBy=multi-user.target
EOF

#############################################
# PHẦN 4: CÀI ĐẶT V2RAY
#############################################

echo -e "${GREEN}[4/7] Cài đặt và tối ưu V2Ray...${NC}"
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

# Tối ưu cấu hình V2Ray
cat > /usr/local/etc/v2ray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log"
  },
  "inbounds": [
    {
      "port": $INTERNAL_V2RAY_PORT,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "",
        "port": 0,
        "network": "tcp,udp",
        "followRedirect": true
      },
      "tag": "http-bridge-in",
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "port": $V2RAY_PORT,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 0,
            "security": "auto"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WS_PATH"
        },
        "sockopt": {
          "tcpFastOpen": true,
          "tproxy": "redirect"
        }
      },
      "tag": "vmess-in",
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      },
      "tag": "direct"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["http-bridge-in", "vmess-in"],
        "outboundTag": "direct"
      }
    ]
  },
  "policy": {
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  }
}
EOF

# Tối ưu V2Ray service
cat > /etc/systemd/system/v2ray.service << EOF
[Unit]
Description=V2Ray Service
Documentation=https://www.v2fly.org/
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/v2ray -config /usr/local/etc/v2ray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

#############################################
# PHẦN 5: CẤU HÌNH NGINX
#############################################

echo -e "${GREEN}[5/7] Cấu hình và tối ưu Nginx...${NC}"

# Tối ưu cấu hình chính của Nginx
cat > /etc/nginx/nginx.conf << EOF
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 8192;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    
    # Tối ưu buffer
    client_max_body_size 10m;
    client_body_buffer_size 128k;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 4k;
    
    # Tối ưu timeouts
    client_body_timeout 12;
    client_header_timeout 12;
    send_timeout 10;
    
    # Tối ưu gzip
    gzip on;
    gzip_vary on;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_proxied any;
    gzip_types
        application/atom+xml
        application/javascript
        application/json
        application/rss+xml
        application/vnd.ms-fontobject
        application/x-font-ttf
        application/x-web-app-manifest+json
        application/xhtml+xml
        application/xml
        font/opentype
        image/svg+xml
        image/x-icon
        text/css
        text/plain
        text/x-component;
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Cấu hình máy chủ Nginx cho V2Ray
cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $PUBLIC_IP;
    
    access_log /var/log/nginx/v2ray-access.log;
    error_log /var/log/nginx/v2ray-error.log;
    
    # Ngụy trang là một trang web bình thường
    location / {
        root /var/www/html;
        index index.html;
        
        # Thêm các HTTP header bảo mật
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Referrer-Policy "no-referrer-when-downgrade" always;
    }
    
    # Định tuyến WebSocket đến V2Ray
    location $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$V2RAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 60s;
        
        # Tối ưu proxy buffer
        proxy_buffer_size 16k;
        proxy_buffers 8 16k;
        proxy_busy_buffers_size 32k;
    }
    
    # PAC file cho iPhone
    location /proxy/ {
        root /var/www/html;
        types { } 
        default_type application/x-ns-proxy-autoconfig;
        
        # Thêm cache headers cho PAC file
        add_header Cache-Control "public, max-age=86400";
    }
}
EOF

#############################################
# PHẦN 6: TẠO PAC FILE VÀ TRANG WEB
#############################################

echo -e "${GREEN}[6/7] Tạo PAC file và trang web ngụy trang...${NC}"

# Tạo thư mục và PAC file
mkdir -p /var/www/html/proxy
cat > /var/www/html/proxy/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Tối ưu hiệu suất bằng cache
    if (isPlainHostName(host) || 
        dnsDomainIs(host, "local") ||
        isInNet(host, "10.0.0.0", "255.0.0.0") ||
        isInNet(host, "172.16.0.0", "255.240.0.0") ||
        isInNet(host, "192.168.0.0", "255.255.0.0") ||
        isInNet(host, "127.0.0.0", "255.0.0.0")) {
        return "DIRECT";
    }
    
    // Các domain cần dùng proxy
    var domains = [
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
        
        // Mạng xã hội phổ biến khác
        ".facebook.com", ".fbcdn.net",
        ".twitter.com",
        ".instagram.com",
        ".pinterest.com",
        ".telegram.org",
        ".t.me",
        
        // Google services
        ".google.com", ".googleapis.com", ".gstatic.com", 
        ".youtube.com", ".ytimg.com", ".ggpht.com",
        ".googlevideo.com", ".googleusercontent.com",
        
        // Dịch vụ phổ biến khác
        ".netflix.com", ".nflxvideo.net",
        ".spotify.com",
        ".amazon.com",
        ".twitch.tv",
        ".reddit.com",
        
        // IP/Speed checking
        ".ipleak.net",
        ".speedtest.net",
        ".fast.com"
    ];
    
    // Kiểm tra domain trong danh sách hiệu quả hơn
    var domain = host.toLowerCase();
    for (var i = 0; i < domains.length; i++) {
        if (dnsDomainIs(domain, domains[i]) || 
            shExpMatch(domain, "*" + domains[i])) {
            return "PROXY $PUBLIC_IP:$HTTP_BRIDGE_PORT";
        }
    }
    
    // Kiểm tra các dải IP Trung Quốc (tối ưu hóa danh sách)
    if (isInNet(dnsResolve(host), "58.14.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "58.16.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "58.24.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.128.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.132.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.136.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "61.139.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "101.227.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "101.226.0.0", "255.255.0.0") ||
        isInNet(dnsResolve(host), "101.224.0.0", "255.255.0.0")) {
        return "PROXY $PUBLIC_IP:$HTTP_BRIDGE_PORT";
    }
    
    // Mặc định truy cập trực tiếp
    return "DIRECT";
}
EOF

# Tạo trang web ngụy trang
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Cloud Storage Solutions</title>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { 
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, "Open Sans", "Helvetica Neue", sans-serif;
            margin: 0; 
            padding: 0; 
            line-height: 1.6; 
            color: #333;
            background-color: #f8f9fa;
        }
        .header { 
            background: linear-gradient(135deg, #0072ff, #00c6ff);
            color: white; 
            text-align: center; 
            padding: 60px 0; 
            margin-bottom: 30px;
        }
        .container { 
            max-width: 1000px; 
            margin: 0 auto; 
            padding: 0 20px; 
        }
        .features {
            display: flex;
            flex-wrap: wrap;
            justify-content: space-between;
            margin: 40px 0;
        }
        .feature {
            flex: 0 0 30%;
            background: white;
            padding: 20px;
            border-radius: 5px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.05);
            margin-bottom: 30px;
        }
        .feature h3 {
            color: #0072ff;
            margin-top: 0;
        }
        .cta {
            background: #f0f0f0;
            padding: 40px 0;
            text-align: center;
            margin: 40px 0;
        }
        .button {
            display: inline-block;
            background: #0072ff;
            color: white;
            padding: 12px 30px;
            border-radius: 4px;
            text-decoration: none;
            font-weight: bold;
            margin-top: 20px;
        }
        .footer { 
            background: #333; 
            color: white; 
            text-align: center; 
            padding: 30px 0; 
            margin-top: 40px; 
        }
    </style>
</head>
<body>
    <div class="header">
        <div class="container">
            <h1>CloudSafe Storage Solutions</h1>
            <p>Secure, reliable cloud storage for personal and business use</p>
        </div>
    </div>
    
    <div class="container">
        <h2>Our Services</h2>
        <p>CloudSafe provides industry-leading cloud storage solutions with a focus on security, reliability, and ease of use.</p>
        
        <div class="features">
            <div class="feature">
                <h3>Personal Cloud</h3>
                <p>Store your photos, videos, and documents securely with our personal cloud storage plans.</p>
            </div>
            
            <div class="feature">
                <h3>Business Solutions</h3>
                <p>Enterprise-grade storage with advanced security features for businesses of all sizes.</p>
            </div>
            
            <div class="feature">
                <h3>Backup & Recovery</h3>
                <p>Automated backup solutions to keep your important data safe from loss or corruption.</p>
            </div>
            
            <div class="feature">
                <h3>File Sharing</h3>
                <p>Easily share files with colleagues and clients with secure access controls.</p>
            </div>
            
            <div class="feature">
                <h3>Mobile Access</h3>
                <p>Access your files from anywhere with our mobile applications for iOS and Android.</p>
            </div>
            
            <div class="feature">
                <h3>24/7 Support</h3>
                <p>Our team of experts is available around the clock to assist with any issues.</p>
            </div>
        </div>
        
        <div class="cta">
            <h2>Ready to get started?</h2>
            <p>Join thousands of satisfied customers using CloudSafe storage solutions.</p>
            <a href="#" class="button">Contact Sales</a>
        </div>
    </div>
    
    <div class="footer">
        <div class="container">
            <p>&copy; 2025 CloudSafe Storage Solutions. All rights reserved.</p>
            <p>Privacy Policy | Terms of Service | Contact Us</p>
        </div>
    </div>
</body>
</html>
EOF

#############################################
# PHẦN 7: TẠO SCRIPT BẢO TRÌ VÀ KHỞI ĐỘNG DỊCH VỤ
#############################################

echo -e "${GREEN}[7/7] Tạo script bảo trì và khởi động dịch vụ...${NC}"

# Tạo script giám sát
cat > /usr/local/bin/monitor-proxy.sh << EOF
#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "\${YELLOW}Kiểm tra tài nguyên hệ thống:${NC}"
echo -e "CPU: \$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - \$1}')% đang sử dụng"
echo -e "RAM: \$(free -m | awk 'NR==2{printf "%.2f%%", \$3*100/\$2}')"
echo -e "SWAP: \$(free -m | awk 'NR==3{printf "%.2f%%", \$3*100/\$2}')"
echo -e "Dung lượng: \$(df -h / | awk 'NR==2{print \$5}')"

echo -e "\${YELLOW}Kiểm tra dịch vụ:${NC}"
for service in v2ray gost-bridge nginx; do
  if systemctl is-active --quiet \$service; then
    echo -e "\${GREEN}\$service: đang chạy${NC}"
  else
    echo -e "\${RED}\$service: không chạy${NC}"
    systemctl restart \$service
    echo -e "Đã cố gắng khởi động lại \$service"
  fi
done

echo -e "\${YELLOW}Thống kê mạng:${NC}"
echo "Kết nối HTTP Bridge:"
netstat -anp | grep :$HTTP_BRIDGE_PORT | wc -l
echo "Kết nối WebSocket:"
netstat -anp | grep :$V2RAY_PORT | wc -l

echo -e "\${YELLOW}Kiểm tra kết nối:${NC}"
curl -s -x http://localhost:$HTTP_BRIDGE_PORT -o /dev/null -w "HTTP Bridge: %{http_code}\n" https://www.google.com

echo -e "\${YELLOW}Lưu lượng V2Ray:${NC}"
v2ray_running=\$(systemctl is-active v2ray)
if [ "\$v2ray_running" == "active" ]; then
    v2ctl api --server=127.0.0.1:10085 StatsService.QueryStats 'pattern: "" reset: false' | grep -E 'name|value' || echo "Không thể lấy thống kê"
else
    echo "V2Ray không chạy"
fi

# Kiểm tra và khởi động lại nếu có lỗi
error_count=\$(grep -c "error" /var/log/v2ray/error.log 2>/dev/null)
if [ \$error_count -gt 10 ]; then
    echo -e "\${RED}Phát hiện quá nhiều lỗi trong log V2Ray, khởi động lại...${NC}"
    systemctl restart v2ray
fi
EOF
chmod +x /usr/local/bin/monitor-proxy.sh

# Tạo script khôi phục nhanh
cat > /usr/local/bin/restart-proxy.sh << EOF
#!/bin/bash
systemctl restart v2ray
systemctl restart gost-bridge
systemctl restart nginx
echo "Tất cả dịch vụ đã được khởi động lại"
EOF
chmod +x /usr/local/bin/restart-proxy.sh

# Tạo script cập nhật tự động
cat > /usr/local/bin/update-proxy.sh << EOF
#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "\${GREEN}Đang cập nhật hệ thống...${NC}"
apt update && apt upgrade -y

echo -e "\${GREEN}Đang cập nhật V2Ray...${NC}"
systemctl stop v2ray
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

echo -e "\${GREEN}Khởi động lại dịch vụ...${NC}"
systemctl daemon-reload
systemctl restart v2ray
systemctl restart gost-bridge
systemctl restart nginx

echo -e "\${GREEN}Cập nhật hoàn tất${NC}"
EOF
chmod +x /usr/local/bin/update-proxy.sh

# Tự động khởi động lại dịch vụ mỗi ngày
(crontab -l 2>/dev/null || echo "") | {
    cat
    echo "0 4 * * * /usr/local/bin/restart-proxy.sh > /dev/null 2>&1"
    echo "0 */6 * * * /usr/local/bin/monitor-proxy.sh > /var/log/proxy-monitor.log 2>&1"
} | crontab -

# Thay đổi quyền sở hữu
chown -R nobody:nogroup /var/log/v2ray/
chmod 755 /var/log/v2ray/

# Khởi động dịch vụ
echo -e "${GREEN}Khởi động dịch vụ...${NC}"
systemctl daemon-reload
systemctl enable v2ray
systemctl enable gost-bridge
systemctl enable nginx
systemctl restart v2ray
systemctl restart gost-bridge
systemctl restart nginx

# Lưu thông tin cấu hình
mkdir -p /etc/v2ray-setup
cat > /etc/v2ray-setup/config.json << EOF
{
  "uuid": "$UUID",
  "ws_path": "$WS_PATH",
  "http_bridge_port": $HTTP_BRIDGE_PORT,
  "v2ray_port": $V2RAY_PORT,
  "internal_v2ray_port": $INTERNAL_V2RAY_PORT,
  "public_ip": "$PUBLIC_IP",
  "installation_date": "$(date)",
  "note": "Cấu hình đã được tối ưu với 2GB RAM ảo"
}
EOF
chmod 600 /etc/v2ray-setup/config.json

# Tạo URL chia sẻ V2Ray
V2RAY_CONFIG=$(cat <<EOF
{
  "v": "2",
  "ps": "V2Ray-WebSocket-Optimized",
  "add": "$PUBLIC_IP",
  "port": "80",
  "id": "$UUID",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "$PUBLIC_IP",
  "path": "$WS_PATH",
  "tls": ""
}
EOF
)

# Mã hóa cấu hình để tạo URL
V2RAY_LINK="vmess://$(echo $V2RAY_CONFIG | jq -c . | base64 -w 0)"

echo -e "\n${BLUE}========================================================${NC}"
echo -e "${GREEN}CÀI ĐẶT THÀNH CÔNG! HỆ THỐNG ĐÃ ĐƯỢC TỐI ƯU HÓA${NC}"
echo -e "${BLUE}========================================================${NC}"

echo -e "\n${YELLOW}THÔNG TIN KẾT NỐI:${NC}"
echo -e "V2Ray WebSocket: ${GREEN}http://$PUBLIC_IP:80$WS_PATH${NC}"
echo -e "UUID: ${GREEN}$UUID${NC}"
echo -e "HTTP Bridge Port: ${GREEN}$HTTP_BRIDGE_PORT${NC}"
echo -e "PAC URL: ${GREEN}http://$PUBLIC_IP/proxy/proxy.pac${NC}"

echo -e "\n${YELLOW}URL V2RAY (Import vào ứng dụng):${NC}"
echo -e "${GREEN}$V2RAY_LINK${NC}"

echo -e "\n${YELLOW}HƯỚNG DẪN SỬ DỤNG TRÊN IPHONE:${NC}"
echo -e "1. Vào Settings > Wi-Fi > [Mạng Wi-Fi] > Configure Proxy > Auto"
echo -e "2. URL: ${GREEN}http://$PUBLIC_IP/proxy/proxy.pac${NC}"

echo -e "\n${YELLOW}QUẢN LÝ HỆ THỐNG:${NC}"
echo -e "Giám sát: ${GREEN}sudo /usr/local/bin/monitor-proxy.sh${NC}"
echo -e "Khởi động lại: ${GREEN}sudo /usr/local/bin/restart-proxy.sh${NC}"
echo -e "Cập nhật: ${GREEN}sudo /usr/local/bin/update-proxy.sh${NC}"

echo -e "\n${GREEN}RAM ảo 2GB và tối ưu hóa hệ thống đã được thiết lập!${NC}"
echo -e "${BLUE}========================================================${NC}"

# Kiểm tra trạng thái dịch vụ
sleep 3
echo -e "\n${YELLOW}Kiểm tra trạng thái dịch vụ:${NC}"
systemctl status v2ray --no-pager | grep Active || echo "V2Ray không chạy!"
systemctl status gost-bridge --no-pager | grep Active || echo "GOST Bridge không chạy!"
systemctl status nginx --no-pager | grep Active || echo "Nginx không chạy!"
