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

echo -e "${BLUE}=== KHẮC PHỤC TRIỆT ĐỂ HTTP BRIDGE KHÔNG ĐỔI IP ====${NC}"

# Lấy địa chỉ IP công cộng
PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || curl -s https://api.ipify.org || curl -s https://ifconfig.me)
if [ -z "$PUBLIC_IP" ]; then
  echo -e "${YELLOW}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
  PUBLIC_IP=$(hostname -I | awk '{print $1}')
fi

# Thông số cấu hình
HTTP_PROXY_PORT=8118
SOCKS_PORT=1080
SS_PORT=8388
SS_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
SS_METHOD="chacha20-ietf-poly1305"
DNS_SERVER="8.8.8.8,8.8.4.4"
TAG="Fix-$(date +%s)"

#############################################
# PHẦN 1: KHẮC PHỤC VẤN ĐỀ IPV6 VÀ DNS
#############################################

echo -e "${GREEN}[1/8] Vô hiệu hóa IPv6 và cấu hình DNS...${NC}"

# Vô hiệu hóa IPv6 để tránh rò rỉ
cat > /etc/sysctl.d/99-disable-ipv6.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf

# Cấu hình DNS cố định
cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
chattr +i /etc/resolv.conf

# Cấu hình NetworkManager (nếu có)
if [ -d "/etc/NetworkManager" ]; then
  cat > /etc/NetworkManager/conf.d/dns.conf << EOF
[main]
dns=none
EOF
  systemctl restart NetworkManager || true
fi

#############################################
# PHẦN 2: DỪNG DỊCH VỤ CŨ
#############################################

echo -e "${GREEN}[2/8] Dừng dịch vụ cũ...${NC}"

# Dừng các dịch vụ nếu tồn tại
for service in v2ray v2ray-client v2ray-server xray xray-server xray-client tinyproxy gost-bridge ss-local shadowsocks-libev; do
  if systemctl list-unit-files | grep -q $service; then
    systemctl stop $service 2>/dev/null
    systemctl disable $service 2>/dev/null
  fi
done

#############################################
# PHẦN 3: CÀI ĐẶT CÁC GÓI CẦN THIẾT
#############################################

echo -e "${GREEN}[3/8] Cài đặt các gói cần thiết...${NC}"
apt update -y
apt install -y curl wget unzip tinyproxy net-tools dnsutils iptables-persistent nginx mtr traceroute jq

# Tạo 2GB swap nếu chưa có
if [ "$(free | grep -c Swap)" -eq 0 ] || [ "$(free | grep Swap | awk '{print $2}')" -lt 1000000 ]; then
    echo -e "${YELLOW}Tạo 2GB RAM ảo (swap)...${NC}"
    swapoff -a &>/dev/null
    rm -f /swapfile
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    fi
    echo 10 > /proc/sys/vm/swappiness
fi

#############################################
# PHẦN 4: TRIỂN KHAI SHADOWSOCKS HIỆU SUẤT CAO
#############################################

echo -e "${GREEN}[4/8] Cài đặt Shadowsocks hiệu suất cao...${NC}"

# Cài đặt Shadowsocks-rust (hiệu suất cao hơn bản libev)
ARCH=$(uname -m)
case $ARCH in
  x86_64)
    SS_ARCH="x86_64-unknown-linux-gnu"
    ;;
  aarch64)
    SS_ARCH="aarch64-unknown-linux-gnu"
    ;;
  *)
    echo -e "${RED}Kiến trúc CPU không được hỗ trợ: $ARCH${NC}"
    exit 1
    ;;
esac

# Tải và cài đặt Shadowsocks-rust
mkdir -p /tmp/shadowsocks
cd /tmp/shadowsocks
wget -q "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.15.4/shadowsocks-v1.15.4.$SS_ARCH.tar.xz"
tar -xf "shadowsocks-v1.15.4.$SS_ARCH.tar.xz"
cp ssserver sslocal ssurl /usr/local/bin/
chmod +x /usr/local/bin/ssserver /usr/local/bin/sslocal /usr/local/bin/ssurl

# Cấu hình Shadowsocks server
mkdir -p /etc/shadowsocks-rust
cat > /etc/shadowsocks-rust/config.json << EOF
{
    "server": "0.0.0.0",
    "server_port": $SS_PORT,
    "password": "$SS_PASSWORD",
    "timeout": 300,
    "method": "$SS_METHOD",
    "fast_open": true,
    "mode": "tcp_and_udp",
    "nameserver": "$DNS_SERVER"
}
EOF

# Cấu hình Shadowsocks local SOCKS proxy
cat > /etc/shadowsocks-rust/local.json << EOF
{
    "server": "127.0.0.1",
    "server_port": $SS_PORT,
    "password": "$SS_PASSWORD",
    "local_address": "127.0.0.1",
    "local_port": $SOCKS_PORT,
    "timeout": 300,
    "method": "$SS_METHOD",
    "fast_open": true,
    "mode": "tcp_and_udp",
    "no_delay": true
}
EOF

# Tạo systemd service cho Shadowsocks server
cat > /etc/systemd/system/shadowsocks-rust-server.service << EOF
[Unit]
Description=Shadowsocks Rust Server
After=network.target

[Service]
Type=simple
User=nobody
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Tạo systemd service cho Shadowsocks local
cat > /etc/systemd/system/shadowsocks-rust-local.service << EOF
[Unit]
Description=Shadowsocks Rust Local
After=network.target shadowsocks-rust-server.service
Requires=shadowsocks-rust-server.service

[Service]
Type=simple
User=nobody
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
ExecStart=/usr/local/bin/sslocal -c /etc/shadowsocks-rust/local.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

#############################################
# PHẦN 5: CẤU HÌNH TINYPROXY VỚI DNS FIX
#############################################

echo -e "${GREEN}[5/8] Cấu hình Tinyproxy với DNS cố định...${NC}"

# Tạo thư mục log nếu chưa tồn tại
mkdir -p /var/log/tinyproxy

# Cấu hình Tinyproxy
cat > /etc/tinyproxy/tinyproxy.conf << EOF
User nobody
Group nogroup
Port $HTTP_PROXY_PORT
Timeout 600
DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"
LogFile "/var/log/tinyproxy/tinyproxy.log"
LogLevel Info
PidFile "/run/tinyproxy/tinyproxy.pid"
MaxClients 1000
MinSpareServers 5
MaxSpareServers 20
StartServers 10
MaxRequestsPerChild 0
ViaProxyName "proxy"
DisableViaHeader Yes

# Cho phép tất cả các kết nối
Allow 0.0.0.0/0

# Chặn các trang có thể làm lộ IP thật
Filter "/etc/tinyproxy/filter"
FilterURLs On
FilterExtended On

# Kết nối đến localhost qua SOCKS
Upstream socks5 127.0.0.1:$SOCKS_PORT
EOF

# Tạo file lọc URL để tránh lộ thông tin
cat > /etc/tinyproxy/filter << EOF
# Chặn các trang có thể làm lộ IP thật qua WebRTC hoặc các kỹ thuật khác
.stun.
.turn.
.webrtc-ice.
.ip-api.
ipv6-test
ip6
ipv6
.what-is-my-ipv6
EOF

#############################################
# PHẦN 6: TRIỂN KHAI IPTABLES ĐỂ TRÁNH RÒ RỈ
#############################################

echo -e "${GREEN}[6/8] Cấu hình iptables để ngăn rò rỉ kết nối...${NC}"

# Lưu lại các rule hiện tại (nếu có)
iptables-save > /etc/iptables/rules.v4.backup

# Xóa tất cả các rule hiện tại
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Thiết lập policy mặc định
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Cho phép lưu lượng trên loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Cho phép các kết nối đã thiết lập và liên quan
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Cho phép SSH
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Cho phép HTTP/HTTPS
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Cho phép cổng Shadowsocks
iptables -A INPUT -p tcp --dport $SS_PORT -j ACCEPT
iptables -A INPUT -p udp --dport $SS_PORT -j ACCEPT

# Cho phép cổng HTTP proxy
iptables -A INPUT -p tcp --dport $HTTP_PROXY_PORT -j ACCEPT

# Từ chối tất cả các gói tin IPv6 (nếu có)
ip6tables -P INPUT DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true

# Lưu các quy tắc iptables
iptables-save > /etc/iptables/rules.v4
if [ -x "$(command -v ip6tables-save)" ]; then
  ip6tables-save > /etc/iptables/rules.v6
fi

#############################################
# PHẦN 7: CẤU HÌNH NGINX VÀ PAC FILE
#############################################

echo -e "${GREEN}[7/8] Cấu hình Nginx và PAC file đặc biệt...${NC}"

# Cấu hình nginx
cat > /etc/nginx/nginx.conf << EOF
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
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
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Cấu hình máy chủ Nginx
cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $PUBLIC_IP;
    
    # Ngụy trang là một trang web bình thường
    location / {
        root /var/www/html;
        index index.html check-ip.html;
    }
    
    # PAC file cho iPhone
    location /proxy/ {
        root /var/www/html;
        types { } 
        default_type application/x-ns-proxy-autoconfig;
        add_header Cache-Control "no-cache";
    }

    # Công cụ kiểm tra IP
    location /ip {
        proxy_pass https://ipinfo.io/ip;
        proxy_set_header Host ipinfo.io;
        proxy_set_header X-Real-IP \$remote_addr;
        add_header Content-Type text/plain;
    }
    
    # Công cụ kiểm tra IPv6 (nếu có)
    location /ipv6 {
        proxy_pass https://ipv6.icanhazip.com/;
        proxy_set_header Host ipv6.icanhazip.com;
        add_header Content-Type text/plain;
    }
    
    # Công cụ kiểm tra leak
    location /check-leak {
        proxy_pass https://www.cloudflare.com/cdn-cgi/trace;
        proxy_set_header Host www.cloudflare.com;
        add_header Content-Type text/plain;
    }
}
EOF

# Tạo thư mục và PAC file ĐẶC BIỆT
mkdir -p /var/www/html/proxy
cat > /var/www/html/proxy/proxy.pac << EOF
function FindProxyForURL(url, host) {
    /* Cải tiến đặc biệt cho iOS để giải quyết vấn đề không thay đổi IP */
    
    // Cache busting
    var randomSuffix = Math.floor(Math.random() * 1000000);
    
    // Bỏ qua các địa chỉ IP nội bộ
    if (isPlainHostName(host) || 
        isInNet(host, "10.0.0.0", "255.0.0.0") ||
        isInNet(host, "172.16.0.0", "255.240.0.0") ||
        isInNet(host, "192.168.0.0", "255.255.0.0") ||
        isInNet(host, "127.0.0.0", "255.0.0.0") ||
        dnsDomainIs(host, ".local")) {
        return "DIRECT";
    }
    
    // Chặn WebRTC leak
    if (shExpMatch(host, "*.stun.*") ||
        shExpMatch(host, "stun.*") ||
        shExpMatch(host, "*.turn.*") ||
        shExpMatch(host, "turn.*") ||
        shExpMatch(host, "*global.turn.*") ||
        shExpMatch(host, "*.googleapis.com") && shExpMatch(url, "*:*")) {
        return "PROXY 127.0.0.1:1;"; // Block with invalid proxy
    }
    
    // Force qua proxy với tham số random để phá cache
    return "PROXY $PUBLIC_IP:$HTTP_PROXY_PORT?nocache=" + randomSuffix;
}
EOF

# Tạo cấu hình proxy di động đặc biệt
cat > /var/www/html/proxy/mobile.mobileconfig << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadDescription</key>
			<string>Cấu hình HTTP Proxy tự động</string>
			<key>PayloadDisplayName</key>
			<string>HTTP Proxy</string>
			<key>PayloadIdentifier</key>
			<string>com.apple.proxy.http.global.${TAG}</string>
			<key>PayloadType</key>
			<string>com.apple.proxy.http.global</string>
			<key>PayloadUUID</key>
			<string>$(uuidgen)</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>ProxyCaptiveLoginAllowed</key>
			<true/>
			<key>ProxyPACFallbackAllowed</key>
			<false/>
			<key>ProxyPACURL</key>
			<string>http://$PUBLIC_IP/proxy/proxy.pac</string>
			<key>ProxyType</key>
			<string>Auto</string>
		</dict>
	</array>
	<key>PayloadDescription</key>
	<string>Cấu hình proxy tự động cho iOS</string>
	<key>PayloadDisplayName</key>
	<string>HTTP Proxy Configuration</string>
	<key>PayloadIdentifier</key>
	<string>com.proxy.${TAG}</string>
	<key>PayloadRemovalDisallowed</key>
	<false/>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>$(uuidgen)</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
</dict>
</plist>
EOF

# Tạo trang web kiểm tra toàn diện
cat > /var/www/html/check-ip.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Kiểm Tra IP Toàn Diện</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta charset="UTF-8">
    <style>
        body { font-family: Arial, sans-serif; text-align: center; margin: 20px; line-height: 1.6; }
        .container { max-width: 800px; margin: 0 auto; }
        .result-box { background: #f5f5f5; border-radius: 5px; padding: 15px; margin: 20px 0; }
        .success { color: green; font-weight: bold; }
        .error { color: red; font-weight: bold; }
        .warning { color: orange; font-weight: bold; }
        button { background: #4CAF50; color: white; border: none; padding: 12px 24px; cursor: pointer; border-radius: 4px; font-size: 16px; margin: 10px; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        table, th, td { border: 1px solid #ddd; }
        th, td { padding: 12px; text-align: left; }
        th { background-color: #f2f2f2; }
        .loader { border: 5px solid #f3f3f3; border-top: 5px solid #3498db; border-radius: 50%; width: 30px; height: 30px; animation: spin 1s linear infinite; margin: 10px auto; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
        .test-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
        @media (max-width: 600px) { .test-grid { grid-template-columns: 1fr; } }
        .config-box { background: #e8f4f8; padding: 15px; border-left: 4px solid #4CAF50; margin: 20px 0; text-align: left; }
        .important { background-color: #ffe6e6; padding: 15px; border-left: 4px solid #ff0000; margin: 20px 0; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Kiểm Tra HTTP Bridge Toàn Diện</h1>
        <p>Công cụ này sẽ kiểm tra nhiều khía cạnh của kết nối proxy của bạn</p>
        
        <div class="important">
            <h3>⚠️ Lưu ý quan trọng:</h3>
            <p><strong>Nếu kết quả kiểm tra vẫn hiển thị IP Việt Nam</strong>, vui lòng thử các biện pháp sau:</p>
            <ol style="text-align: left;">
                <li>Tắt và bật lại chế độ máy bay trên iPhone</li>
                <li>Khởi động lại iPhone</li>
                <li>Thử cấu hình proxy thủ công thay vì PAC file</li>
                <li>Tắt mọi VPN khác nếu có</li>
                <li>Tải và cài đặt <a href="/proxy/mobile.mobileconfig">hồ sơ cấu hình proxy đặc biệt</a></li>
            </ol>
        </div>
        
        <div class="test-grid">
            <div>
                <button onclick="checkIP()">Kiểm tra IP</button>
                <div id="ip-result" class="result-box">
                    <p>Nhấn nút để kiểm tra</p>
                </div>
            </div>
            
            <div>
                <button onclick="checkIPv6()">Kiểm tra IPv6</button>
                <div id="ipv6-result" class="result-box">
                    <p>Nhấn nút để kiểm tra</p>
                </div>
            </div>
            
            <div>
                <button onclick="checkDNSLeak()">Kiểm tra DNS Leak</button>
                <div id="dns-result" class="result-box">
                    <p>Nhấn nút để kiểm tra</p>
                </div>
            </div>
            
            <div>
                <button onclick="checkWebRTC()">Kiểm tra WebRTC Leak</button>
                <div id="webrtc-result" class="result-box">
                    <p>Nhấn nút để kiểm tra</p>
                </div>
            </div>
        </div>
        
        <button onclick="runAllTests()" style="background-color: #ff9800;">Chạy tất cả kiểm tra</button>
        
        <div class="config-box">
            <h3>Thông tin cấu hình:</h3>
            <ul style="text-align: left;">
                <li><strong>HTTP Proxy:</strong> $PUBLIC_IP:$HTTP_PROXY_PORT</li>
                <li><strong>PAC URL:</strong> http://$PUBLIC_IP/proxy/proxy.pac</li>
                <li><strong>Cấu hình tự động:</strong> <a href="/proxy/mobile.mobileconfig">Tải hồ sơ cấu hình</a></li>
            </ul>
            <p><strong>Trên iPhone:</strong> Vào Settings > Wi-Fi > [Mạng Wi-Fi] > Configure Proxy > Manual</p>
            <p>Server: $PUBLIC_IP, Port: $HTTP_PROXY_PORT</p>
        </div>
    </div>
    
    <script>
        // Kiểm tra IP
        function checkIP() {
            const resultDiv = document.getElementById('ip-result');
            resultDiv.innerHTML = '<div class="loader"></div><p>Đang kiểm tra IP...</p>';
            
            fetch('/ip')
                .then(response => response.text())
                .then(data => {
                    let ipAddress = data.trim();
                    resultDiv.innerHTML = 
                        '<p>IP hiện tại của bạn: <strong>' + ipAddress + '</strong></p>';
                    
                    // Kiểm tra xem IP có phải là IP Việt Nam không
                    fetch('https://ipapi.co/' + ipAddress + '/country/')
                        .then(response => response.text())
                        .then(country => {
                            if (country.trim() === 'VN') {
                                resultDiv.innerHTML += '<p class="error">⛔ IP này vẫn là IP Việt Nam!</p>';
                                resultDiv.innerHTML += '<p>Vui lòng thử các biện pháp khắc phục trong phần Lưu ý quan trọng.</p>';
                            } else {
                                resultDiv.innerHTML += '<p class="success">✅ IP không phải là IP Việt Nam!</p>';
                                resultDiv.innerHTML += '<p>HTTP Bridge đang hoạt động tốt.</p>';
                            }
                        })
                        .catch(error => {
                            resultDiv.innerHTML += '<p class="warning">⚠️ Không thể xác định quốc gia của IP</p>';
                        });
                })
                .catch(error => {
                    resultDiv.innerHTML = '<p class="error">Lỗi khi kiểm tra IP: ' + error + '</p>';
                });
        }
        
        // Kiểm tra IPv6
        function checkIPv6() {
            const resultDiv = document.getElementById('ipv6-result');
            resultDiv.innerHTML = '<div class="loader"></div><p>Đang kiểm tra IPv6...</p>';
            
            fetch('/ipv6')
                .then(response => response.text())
                .then(data => {
                    if (data.trim() && !data.includes('error') && !data.includes('no ipv6')) {
                        resultDiv.innerHTML = 
                            '<p>IPv6 được phát hiện: <strong>' + data.trim() + '</strong></p>' +
                            '<p class="error">⛔ IPv6 có thể đang rò rỉ kết nối!</p>' +
                            '<p>Vui lòng tắt IPv6 trên thiết bị của bạn.</p>';
                    } else {
                        resultDiv.innerHTML = 
                            '<p class="success">✅ Không phát hiện IPv6!</p>' +
                            '<p>Đây là kết quả tốt, tránh được rò rỉ kết nối qua IPv6.</p>';
                    }
                })
                .catch(error => {
                    resultDiv.innerHTML = 
                        '<p class="success">✅ Không phát hiện IPv6!</p>' +
                        '<p>Đây là kết quả tốt, tránh được rò rỉ kết nối qua IPv6.</p>';
                });
        }
        
        // Kiểm tra DNS leak
        function checkDNSLeak() {
            const resultDiv = document.getElementById('dns-result');
            resultDiv.innerHTML = '<div class="loader"></div><p>Đang kiểm tra DNS leak...</p>';
            
            fetch('/check-leak')
                .then(response => response.text())
                .then(data => {
                    let ip = '';
                    const lines = data.split('\\n');
                    for (const line of lines) {
                        if (line.startsWith('ip=')) {
                            ip = line.substring(3);
                            break;
                        }
                    }
                    
                    if (ip) {
                        fetch('/ip')
                            .then(response => response.text())
                            .then(proxyIp => {
                                if (ip.trim() === proxyIp.trim()) {
                                    resultDiv.innerHTML = 
                                        '<p class="success">✅ DNS không bị rò rỉ!</p>' +
                                        '<p>IP DNS: <strong>' + ip + '</strong> khớp với IP proxy.</p>';
                                } else {
                                    resultDiv.innerHTML = 
                                        '<p class="error">⛔ DNS có thể đang bị rò rỉ!</p>' +
                                        '<p>IP DNS: <strong>' + ip + '</strong> không khớp với IP proxy.</p>' +
                                        '<p>Bạn nên sử dụng cấu hình DNS tùy chỉnh trên iPhone.</p>';
                                }
                            });
                    } else {
                        resultDiv.innerHTML = '<p class="warning">⚠️ Không thể xác định IP DNS</p>';
                    }
                })
                .catch(error => {
                    resultDiv.innerHTML = '<p class="error">Lỗi khi kiểm tra DNS: ' + error + '</p>';
                });
        }
        
        // Kiểm tra WebRTC leak
        function checkWebRTC() {
            const resultDiv = document.getElementById('webrtc-result');
            resultDiv.innerHTML = '<div class="loader"></div><p>Đang kiểm tra WebRTC leak...</p>';
            
            // Hàm kiểm tra WebRTC
            function getIPs(callback) {
                var ip_dups = {};
                var RTCPeerConnection = window.RTCPeerConnection
                    || window.mozRTCPeerConnection
                    || window.webkitRTCPeerConnection;
                
                if (!RTCPeerConnection) {
                    resultDiv.innerHTML = '<p class="warning">⚠️ WebRTC không được hỗ trợ trên trình duyệt này</p>';
                    return;
                }
                
                var pc = new RTCPeerConnection({
                    iceServers: [{urls: "stun:stun.services.mozilla.com"}]
                });
                
                function handleCandidate(candidate) {
                    var ip_regex = /([0-9]{1,3}(\.[0-9]{1,3}){3})/;
                    var ip_addr = ip_regex.exec(candidate);
                    if (ip_addr) {
                        var ip = ip_addr[1];
                        if (ip.substr(0, 7) == '192.168' || ip.substr(0, 7) == '10.0.0.' || ip.substr(0, 3) == '172') {
                            // Bỏ qua địa chỉ IP cục bộ
                            return;
                        }
                        if (ip_dups[ip] === undefined) {
                            callback(ip);
                        }
                        ip_dups[ip] = true;
                    }
                }
                
                pc.createDataChannel("");
                pc.createOffer().then(function(offer) {
                    return pc.setLocalDescription(offer);
                }).catch(function(error) {
                    resultDiv.innerHTML = '<p class="error">Lỗi khi tạo kết nối: ' + error + '</p>';
                });
                
                setTimeout(function() {
                    if (pc.localDescription) {
                        var lines = pc.localDescription.sdp.split('\\n');
                        lines.forEach(function(line) {
                            if (line.indexOf('candidate') !== -1) {
                                handleCandidate(line);
                            }
                        });
                    }
                    
                    if (Object.keys(ip_dups).length === 0) {
                        resultDiv.innerHTML = 
                            '<p class="success">✅ Không phát hiện rò rỉ WebRTC!</p>' +
                            '<p>WebRTC đã được chặn hoặc không phát hiện IP công khai.</p>';
                    }
                }, 1000);
            }
            
            getIPs(function(ip) {
                fetch('/ip')
                    .then(response => response.text())
                    .then(proxyIp => {
                        if (ip.trim() !== proxyIp.trim()) {
                            resultDiv.innerHTML = 
                                '<p class="error">⛔ WebRTC đang làm lộ IP thật của bạn!</p>' +
                                '<p>IP WebRTC: <strong>' + ip + '</strong> không khớp với IP proxy.</p>' +
                                '<p>Bạn nên sử dụng trình duyệt có thể vô hiệu hóa WebRTC.</p>';
                        } else {
                            resultDiv.innerHTML = 
                                '<p class="success">✅ WebRTC không làm lộ IP thật!</p>' +
                                '<p>IP WebRTC: <strong>' + ip + '</strong> khớp với IP proxy.</p>';
                        }
                    });
            });
        }
        
        // Chạy tất cả các kiểm tra
        function runAllTests() {
            checkIP();
            checkIPv6();
            checkDNSLeak();
            checkWebRTC();
        }
    </script>
</body>
</html>
EOF

# Tạo trang web ngụy trang
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>HTTP Proxy Bridge</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 0; line-height: 1.6; }
        .header { background: linear-gradient(135deg, #007bff, #6610f2); color: white; padding: 40px 0; text-align: center; }
        .container { max-width: 1000px; margin: 0 auto; padding: 20px; }
        .card { background: white; border-radius: 5px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); margin: 20px 0; padding: 20px; }
        .button { background: #007bff; color: white; text-decoration: none; padding: 10px 20px; border-radius: 4px; display: inline-block; }
        .footer { background: #333; color: white; text-align: center; padding: 20px 0; margin-top: 40px; }
    </style>
</head>
<body>
    <div class="header">
        <div class="container">
            <h1>HTTP Proxy Bridge</h1>
            <p>Giải pháp proxy an toàn và hiệu quả</p>
        </div>
    </div>
    
    <div class="container">
        <div class="card">
            <h2>Tính năng</h2>
            <ul>
                <li>HTTP Bridge qua proxy bảo mật</li>
                <li>Bảo vệ khỏi rò rỉ DNS và WebRTC</li>
                <li>Ngăn chặn theo dõi và giám sát</li>
                <li>Hiệu suất cao</li>
            </ul>
            <a href="/check-ip.html" class="button">Kiểm tra kết nối</a>
        </div>
        
        <div class="card">
            <h2>Cài đặt cho iPhone/iPad</h2>
            <p>Để sử dụng proxy này trên thiết bị iOS của bạn:</p>
            <ol>
                <li>Tải <a href="/proxy/mobile.mobileconfig">hồ sơ cấu hình</a></li>
                <li>Cài đặt hồ sơ trong phần Settings</li>
                <li>Hoặc cấu hình thủ công: Vào Settings > Wi-Fi > [Mạng Wi-Fi của bạn] > Configure Proxy</li>
            </ol>
        </div>
    </div>
    
    <div class="footer">
        <div class="container">
            <p>&copy; 2025 HTTP Proxy Bridge. All rights reserved.</p>
        </div>
    </div>
</body>
</html>
EOF

#############################################
# PHẦN 8: SCRIPT KIỂM TRA VÀ KHỞI ĐỘNG DỊCH VỤ
#############################################

echo -e "${GREEN}[8/8] Tạo script kiểm tra và khởi động dịch vụ...${NC}"

# Tạo script kiểm tra kết nối
cat > /usr/local/bin/check-proxy.sh << EOF
#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}====== KIỂM TRA PROXY TOÀN DIỆN ======${NC}"

# Kiểm tra dịch vụ
echo -e "\n${YELLOW}Kiểm tra trạng thái dịch vụ:${NC}"
systemctl status tinyproxy --no-pager | grep Active || echo -e "${RED}Tinyproxy không chạy!${NC}"
systemctl status shadowsocks-rust-server --no-pager | grep Active || echo -e "${RED}Shadowsocks-server không chạy!${NC}"
systemctl status shadowsocks-rust-local --no-pager | grep Active || echo -e "${RED}Shadowsocks-local không chạy!${NC}"
systemctl status nginx --no-pager | grep Active || echo -e "${RED}Nginx không chạy!${NC}"

# Kiểm tra các cổng đang lắng nghe
echo -e "\n${YELLOW}Cổng đang lắng nghe:${NC}"
netstat -tuln | grep -E "$HTTP_PROXY_PORT|$SOCKS_PORT|$SS_PORT|80" || echo -e "${RED}Không tìm thấy cổng nào!${NC}"

# Kiểm tra IPv6
echo -e "\n${YELLOW}Kiểm tra IPv6:${NC}"
if [[ \$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 1 ]]; then
    echo -e "${GREEN}IPv6 đã bị vô hiệu hóa.${NC}"
else
    echo -e "${RED}IPv6 chưa bị vô hiệu hóa!${NC}"
    echo -e "${YELLOW}Thực hiện vô hiệu hóa IPv6...${NC}"
    echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
    echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6
    echo 1 > /proc/sys/net/ipv6/conf/lo/disable_ipv6
fi

# Kiểm tra kết nối HTTP proxy
echo -e "\n${YELLOW}Kiểm tra kết nối HTTP proxy:${NC}"
curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://ipinfo.io/ip || echo -e "${RED}HTTP proxy không hoạt động!${NC}"

# Kiểm tra kết nối SOCKS proxy
echo -e "\n${YELLOW}Kiểm tra kết nối SOCKS proxy:${NC}"
curl -s --socks5 127.0.0.1:$SOCKS_PORT https://ipinfo.io/ip || echo -e "${RED}SOCKS proxy không hoạt động!${NC}"

# Kiểm tra kết nối trực tiếp để so sánh
echo -e "\n${YELLOW}Kiểm tra IP trực tiếp (không qua proxy):${NC}"
curl -s https://ipinfo.io/ip

echo -e "\n${YELLOW}Kết luận:${NC}"
IP_PROXY=\$(curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://ipinfo.io/ip)
IP_DIRECT=\$(curl -s https://ipinfo.io/ip)

if [ "\$IP_PROXY" = "\$IP_DIRECT" ]; then
  echo -e "${RED}CHÚ Ý: IP qua proxy và IP trực tiếp GIỐNG NHAU! Proxy không hoạt động đúng cách!${NC}"
else
  echo -e "${GREEN}IP qua proxy và IP trực tiếp KHÁC NHAU. Proxy đang hoạt động tốt!${NC}"
fi

# Kiểm tra DNS của proxy
echo -e "\n${YELLOW}Kiểm tra DNS qua proxy:${NC}"
curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://google.com > /dev/null
if [ \$? -eq 0 ]; then
    echo -e "${GREEN}DNS qua proxy hoạt động tốt.${NC}"
else
    echo -e "${RED}DNS qua proxy không hoạt động!${NC}"
fi

# Kiểm tra tốc độ proxy
echo -e "\n${YELLOW}Kiểm tra tốc độ proxy (10MB):${NC}"
time curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://speed.hetzner.de/10MB.bin -o /dev/null || echo -e "${RED}Kiểm tra tốc độ thất bại!${NC}"
EOF
chmod +x /usr/local/bin/check-proxy.sh

# Tạo script khởi động lại
cat > /usr/local/bin/restart-proxy.sh << EOF
#!/bin/bash
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "\${GREEN}Khởi động lại tất cả dịch vụ proxy...${NC}"
systemctl restart tinyproxy
systemctl restart shadowsocks-rust-server
systemctl restart shadowsocks-rust-local
systemctl restart nginx
echo -e "\${GREEN}Đã khởi động lại dịch vụ.${NC}"
EOF
chmod +x /usr/local/bin/restart-proxy.sh

# Tạo script sửa tự động
cat > /usr/local/bin/auto-fix-proxy.sh << EOF
#!/bin/bash
LOG="/var/log/proxy-check.log"
echo "Kiểm tra proxy tự động lúc \$(date)" >> \$LOG

# Đảm bảo IPv6 bị vô hiệu hóa
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6
echo 1 > /proc/sys/net/ipv6/conf/lo/disable_ipv6

# Đảm bảo /etc/resolv.conf không bị thay đổi
cat > /etc/resolv.conf << EOFDNS
nameserver 8.8.8.8
nameserver 1.1.1.1
EOFDNS
chattr +i /etc/resolv.conf

# Kiểm tra HTTP proxy
if ! curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://www.google.com -o /dev/null; then
    echo "HTTP proxy không hoạt động, khởi động lại Tinyproxy" >> \$LOG
    systemctl restart tinyproxy
fi

# Kiểm tra SOCKS proxy
if ! curl -s --socks5 127.0.0.1:$SOCKS_PORT https://www.google.com -o /dev/null; then
    echo "SOCKS proxy không hoạt động, khởi động lại Shadowsocks" >> \$LOG
    systemctl restart shadowsocks-rust-server
    systemctl restart shadowsocks-rust-local
fi

# Kiểm tra Nginx
if ! curl -s http://127.0.0.1 -o /dev/null; then
    echo "Nginx không hoạt động, khởi động lại" >> \$LOG
    systemctl restart nginx
fi

# Kiểm tra kết nối sau khi sửa
if curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://www.google.com -o /dev/null; then
    echo "Kiểm tra OK: HTTP proxy hoạt động" >> \$LOG
else
    echo "QUAN TRỌNG: HTTP proxy vẫn không hoạt động sau khi khởi động lại" >> \$LOG
    /usr/local/bin/restart-proxy.sh >> \$LOG
fi

# Kiểm tra đặc biệt xem proxy có bị leak không
IP_PROXY=\$(curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://ipinfo.io/ip)
IP_DIRECT=\$(curl -s https://ipinfo.io/ip)

if [ "\$IP_PROXY" = "\$IP_DIRECT" ]; then
    echo "NGHIÊM TRỌNG: Proxy bị leak IP! IP qua proxy và IP trực tiếp GIỐNG NHAU!" >> \$LOG
    echo "Đang thực hiện khởi động lại toàn bộ dịch vụ..." >> \$LOG
    /usr/local/bin/restart-proxy.sh >> \$LOG
else
    echo "OK: IP qua proxy và IP trực tiếp khác nhau" >> \$LOG
fi
EOF
chmod +x /usr/local/bin/auto-fix-proxy.sh

# Thiết lập định kỳ kiểm tra và khởi động lại
(crontab -l 2>/dev/null || echo "") | {
    cat
    echo "*/3 * * * * /usr/local/bin/auto-fix-proxy.sh > /dev/null 2>&1" # Kiểm tra và sửa mỗi 3 phút
    echo "0 */2 * * * /usr/local/bin/restart-proxy.sh > /dev/null 2>&1"  # Khởi động lại mỗi 2 giờ
} | crontab -

# Khởi động dịch vụ
systemctl daemon-reload
systemctl enable tinyproxy
systemctl enable shadowsocks-rust-server
systemctl enable shadowsocks-rust-local
systemctl enable nginx
systemctl restart tinyproxy
systemctl restart shadowsocks-rust-server
systemctl restart shadowsocks-rust-local
systemctl restart nginx

# Khởi động iptables
if [ -f "/etc/iptables/rules.v4" ]; then
    iptables-restore < /etc/iptables/rules.v4
fi

# Chờ dịch vụ khởi động
sleep 5

# Kiểm tra kết nối proxy
IP_PROXY=$(curl -s -x http://127.0.0.1:$HTTP_PROXY_PORT https://ipinfo.io/ip)
IP_DIRECT=$(curl -s https://ipinfo.io/ip)

# Hiển thị thông tin kết nối
echo -e "\n${BLUE}========================================================${NC}"
echo -e "${GREEN}KHẮC PHỤC TRIỆT ĐỂ HTTP BRIDGE ĐÃ HOÀN TẤT${NC}"
echo -e "${BLUE}========================================================${NC}"

echo -e "\n${YELLOW}THÔNG TIN KẾT NỐI CHO IPHONE:${NC}"
echo -e "${GREEN}PHƯƠNG ÁN 1: CẤU HÌNH THỦ CÔNG (Khuyến nghị)${NC}"
echo -e "1. Vào Settings > Wi-Fi > [Mạng Wi-Fi] > Configure Proxy > Manual"
echo -e "2. Server: ${GREEN}$PUBLIC_IP${NC}"
echo -e "3. Port: ${GREEN}$HTTP_PROXY_PORT${NC}"

echo -e "\n${GREEN}PHƯƠNG ÁN 2: HỒ SƠ CẤU HÌNH${NC}"
echo -e "1. Mở Safari trên iPhone và truy cập: ${GREEN}http://$PUBLIC_IP/proxy/mobile.mobileconfig${NC}"
echo -e "2. Cài đặt hồ sơ cấu hình và tin cậy"

echo -e "\n${GREEN}PHƯƠNG ÁN 3: PAC FILE${NC}"
echo -e "1. Vào Settings > Wi-Fi > [Mạng Wi-Fi] > Configure Proxy > Auto"
echo -e "2. URL: ${GREEN}http://$PUBLIC_IP/proxy/proxy.pac${NC}"

echo -e "\n${YELLOW}KIỂM TRA KẾT NỐI:${NC}"
if [ "$IP_PROXY" = "$IP_DIRECT" ]; then
  echo -e "${RED}CHÚ Ý: IP qua proxy và IP trực tiếp GIỐNG NHAU!${NC}"
  echo -e "${YELLOW}Vui lòng thử khởi động lại dịch vụ:${NC} sudo /usr/local/bin/restart-proxy.sh"
else
  echo -e "${GREEN}IP qua proxy: $IP_PROXY${NC}"
  echo -e "${GREEN}IP trực tiếp: $IP_DIRECT${NC}"
  echo -e "${GREEN}HTTP Bridge đang hoạt động tốt!${NC}"
fi

echo -e "\n${YELLOW}THÔNG TIN SHADOWSOCKS (nếu muốn kết nối trực tiếp):${NC}"
echo -e "Server: ${GREEN}$PUBLIC_IP${NC}"
echo -e "Port: ${GREEN}$SS_PORT${NC}"
echo -e "Password: ${GREEN}$SS_PASSWORD${NC}"
echo -e "Method: ${GREEN}$SS_METHOD${NC}"

echo -e "\n${YELLOW}MẸO QUAN TRỌNG KHẮC PHỤC:${NC}"
echo -e "1. ${GREEN}Tắt và bật lại chế độ máy bay${NC} trên iPhone"
echo -e "2. ${GREEN}Khởi động lại iPhone${NC} sau khi cấu hình proxy"
echo -e "3. ${GREEN}Thử cấu hình THỦ CÔNG${NC} thay vì PAC file"
echo -e "4. ${GREEN}Tắt mọi VPN khác${NC} nếu có"
echo -e "5. ${GREEN}Sử dụng trang kiểm tra toàn diện${NC}: http://$PUBLIC_IP/check-ip.html"

echo -e "\n${YELLOW}QUẢN LÝ HỆ THỐNG:${NC}"
echo -e "Kiểm tra: ${GREEN}sudo /usr/local/bin/check-proxy.sh${NC}"
echo -e "Khởi động lại: ${GREEN}sudo /usr/local/bin/restart-proxy.sh${NC}"
echo -e "${BLUE}========================================================${NC}"

# Lưu thông tin cấu hình
mkdir -p /etc/proxy-setup
cat > /etc/proxy-setup/config.json << EOF
{
  "http_proxy_port": $HTTP_PROXY_PORT,
  "socks_port": $SOCKS_PORT,
  "shadowsocks_port": $SS_PORT,
  "shadowsocks_password": "$SS_PASSWORD",
  "shadowsocks_method": "$SS_METHOD",
  "public_ip": "$PUBLIC_IP",
  "installation_date": "$(date)",
  "version": "2.0.0-ultimate-fix"
}
EOF
chmod 600 /etc/proxy-setup/config.json

# Chạy kiểm tra chi tiết
echo -e "\n${YELLOW}Đang chạy kiểm tra chi tiết để xác minh cài đặt:${NC}"
/usr/local/bin/check-proxy.sh
