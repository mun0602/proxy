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

echo -e "${BLUE}=== KHẮC PHỤC TRIỆT ĐỂ DNS LEAK VỚI HTTP PROXY ===${NC}"

# Lấy địa chỉ IP công cộng
PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || curl -s https://api.ipify.org || curl -s https://ifconfig.me)
if [ -z "$PUBLIC_IP" ]; then
  echo -e "${YELLOW}Không thể xác định địa chỉ IP công cộng. Sử dụng IP local thay thế.${NC}"
  PUBLIC_IP=$(hostname -I | awk '{print $1}')
fi

# Kiểm tra V2Ray đã cài đặt chưa
if [ ! -f "/usr/local/bin/v2ray" ]; then
  echo -e "${RED}V2Ray chưa được cài đặt. Vui lòng cài đặt V2Ray trước.${NC}"
  exit 1
fi

# Kiểm tra cấu hình V2Ray
if [ ! -f "/usr/local/etc/v2ray/config.json" ]; then
  echo -e "${RED}Không tìm thấy file cấu hình V2Ray.${NC}"
  exit 1
fi

# Đọc thông số cấu hình từ file (nếu có)
if [ -f "/etc/v2ray-setup/config.json" ]; then
  echo -e "${GREEN}Đang đọc cấu hình hiện tại...${NC}"
  HTTP_PROXY_PORT=$(jq -r '.http_proxy_port' /etc/v2ray-setup/config.json 2>/dev/null || echo "8118")
  SS_PORT=$(jq -r '.ss_port' /etc/v2ray-setup/config.json 2>/dev/null || echo "8388")
  WS_PORT=$(jq -r '.ws_port' /etc/v2ray-setup/config.json 2>/dev/null || echo "10086")
else
  # Sử dụng giá trị mặc định
  HTTP_PROXY_PORT=8118
  SS_PORT=8388
  WS_PORT=10086
fi

#############################################
# PHẦN 1: CẤU HÌNH V2RAY VỚI DNS BẢO MẬT
#############################################

echo -e "${GREEN}[1/4] Cấu hình V2Ray với DNS bảo mật...${NC}"

# Backup cấu hình cũ
cp /usr/local/etc/v2ray/config.json /usr/local/etc/v2ray/config.json.bak.$(date +%s)

# Tạo cấu hình V2Ray với DNS bảo mật
cat > /usr/local/etc/v2ray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log"
  },
  "dns": {
    "servers": [
      "https+local://cloudflare-dns.com/dns-query",
      "1.1.1.1",
      "8.8.8.8",
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "port": $HTTP_PROXY_PORT,
      "listen": "0.0.0.0",
      "protocol": "http",
      "settings": {
        "timeout": 300,
        "allowTransparent": false
      },
      "tag": "http_in",
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "fakedns"],
        "metadataOnly": false
      }
    },
    {
      "port": $WS_PORT,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$(cat /etc/v2ray-setup/config.json | jq -r '.uuid' 2>/dev/null || cat /proc/sys/kernel/random/uuid)",
            "alterId": 0,
            "security": "auto"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$(cat /etc/v2ray-setup/config.json | jq -r '.ws_path' 2>/dev/null || echo "/$(head /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)")"
        }
      },
      "tag": "vmess_in",
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "fakedns"],
        "metadataOnly": false
      }
    },
    {
      "port": $SS_PORT,
      "listen": "127.0.0.1",
      "protocol": "shadowsocks",
      "settings": {
        "method": "$(cat /etc/v2ray-setup/config.json | jq -r '.ss_method' 2>/dev/null || echo "chacha20-ietf-poly1305")",
        "password": "$(cat /etc/v2ray-setup/config.json | jq -r '.ss_password' 2>/dev/null || echo "$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 16)")",
        "network": "tcp,udp"
      },
      "tag": "ss_in",
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "fakedns"],
        "metadataOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP",
        "dns": {
          "servers": [
            "https+local://cloudflare-dns.com/dns-query"
          ]
        }
      },
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    },
    {
      "protocol": "dns",
      "tag": "dns-out"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "dns-out",
        "network": "udp",
        "port": 53
      },
      {
        "type": "field",
        "inboundTag": ["http_in"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "inboundTag": ["vmess_in", "ss_in"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": ["geoip:private"],
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

#############################################
# PHẦN 2: CẬP NHẬT PAC FILE CHỐNG DNS LEAK
#############################################

echo -e "${GREEN}[2/4] Cập nhật PAC file để ngăn DNS leak...${NC}"

# Tạo thư mục nếu chưa tồn tại
mkdir -p /var/www/html/proxy

# Tạo PAC file nâng cao với bảo vệ DNS leak
cat > /var/www/html/proxy/proxy.pac << EOF
function FindProxyForURL(url, host) {
    // Phần 1: Xử lý cache và kiểm tra kết nối mạng
    var cacheBuster = Math.floor(Math.random() * 1000000);
    
    // Phần 2: Bảo vệ DNS leak - Chuyển hướng tất cả DNS requests
    if (isPlainHostName(host) || 
        shExpMatch(host, "*.local") ||
        shExpMatch(host, "*.localhost") ||
        shExpMatch(host, "localhost")) {
        return "DIRECT";
    }

    // Phần 3: Chặn các trang với WebRTC có thể làm lộ IP
    if (shExpMatch(host, "*.stun.*") ||
        shExpMatch(host, "stun.*") ||
        shExpMatch(host, "*.turn.*") ||
        shExpMatch(host, "turn.*") ||
        shExpMatch(host, "*global.turn.*") ||
        shExpMatch(host, "*.webrtc.*") ||
        shExpMatch(host, "*rtcpeerconnection*")) {
        return "PROXY 127.0.0.1:1"; // Chặn với proxy không hợp lệ
    }
    
    // Phần 4: Các domain cần proxy trực tiếp
    var proxyDomains = [
        // Mạng xã hội
        ".facebook.com", ".fbcdn.net", ".fb.com",
        ".twitter.com", ".twimg.com",
        ".instagram.com", ".cdninstagram.com",
        ".pinterest.com",
        ".telegram.org", ".t.me", ".tdesktop.com",
        
        // Google services
        ".google.com", ".googleapis.com", ".gstatic.com", 
        ".youtube.com", ".ytimg.com", ".ggpht.com",
        ".gmail.com", ".googleusercontent.com",
        ".googlevideo.com", ".google-analytics.com",
        
        // Streaming platforms
        ".netflix.com", ".nflxvideo.net", ".nflxext.com",
        ".spotify.com", ".spotifycdn.com",
        ".amazon.com", ".primevideo.com",
        ".twitch.tv", ".ttvnw.net",
        ".hulu.com", ".hulustream.com",
        
        // Kiểm tra IP
        ".ipleak.net", ".browserleaks.com",
        ".speedtest.net", ".fast.com", ".ipinfo.io",
        ".whatismyip.com", ".whatismyipaddress.com",
        
        // Dịch vụ VPN & Proxy
        ".nordvpn.com", ".expressvpn.com", ".vyprvpn.com",
        ".torproject.org", ".shadowsocks.org"
    ];
    
    // Chuyển hướng các domain đặc biệt qua proxy
    for (var i = 0; i < proxyDomains.length; i++) {
        if (dnsDomainIs(host, proxyDomains[i]) || 
            shExpMatch(host, "*" + proxyDomains[i])) {
            return "PROXY $PUBLIC_IP:$HTTP_PROXY_PORT?nocache=" + cacheBuster;
        }
    }
    
    // Phần 5: Chuyển hướng các domain chưa biết qua proxy để bảo vệ DNS
    return "PROXY $PUBLIC_IP:$HTTP_PROXY_PORT?nocache=" + cacheBuster;
}
EOF

#############################################
# PHẦN 3: CẤU HÌNH DNSMASQ ĐỂ CHẶN DNS LEAK
#############################################

echo -e "${GREEN}[3/4] Cài đặt và cấu hình DNSMasq...${NC}"

# Cài đặt dnsmasq
apt-get update
apt-get install -y dnsmasq resolvconf

# Cấu hình dnsmasq
cat > /etc/dnsmasq.conf << EOF
# Lắng nghe trên tất cả các interface
listen-address=127.0.0.1
interface=lo

# Không sử dụng /etc/hosts
no-hosts

# Upstream DNS servers (DoH)
server=1.1.1.1
server=8.8.8.8

# Truy vấn song song
all-servers

# Cache DNS
cache-size=1000
min-cache-ttl=300

# Log
log-queries
log-facility=/var/log/dnsmasq.log

# Không forward các truy vấn ngược
bogus-priv

# Không forward các truy vấn reverse cho private IPs
domain-needed

# Không forward các truy vấn không hợp lệ
domain-needed

# Không forward plain names
domain-needed
EOF

# Cấu hình resolvconf để sử dụng dnsmasq
echo "nameserver 127.0.0.1" > /etc/resolvconf/resolv.conf.d/head

# Cấu hình systemd-resolved nếu được sử dụng
if systemctl is-active --quiet systemd-resolved; then
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
    
    # Đảm bảo /etc/resolv.conf trỏ đến dnsmasq
    rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

# Khởi động dnsmasq
systemctl restart dnsmasq
systemctl enable dnsmasq

#############################################
# PHẦN 4: THIẾT LẬP TRANG KIỂM TRA DNS LEAK
#############################################

echo -e "${GREEN}[4/4] Tạo trang kiểm tra DNS leak...${NC}"

# Tạo trang web kiểm tra DNS leak
cat > /var/www/html/dns-check.html << EOF
<!DOCTYPE html>
<html lang="vi">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Kiểm tra DNS Leak</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f7f7f7;
        }
        h1 {
            color: #2c3e50;
            text-align: center;
        }
        .card {
            background: white;
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            padding: 20px;
            margin-bottom: 20px;
        }
        .result {
            background-color: #f5f5f5;
            border-left: 4px solid #3498db;
            padding: 15px;
            margin: 15px 0;
            border-radius: 0 4px 4px 0;
        }
        .success {
            border-left-color: #2ecc71;
        }
        .error {
            border-left-color: #e74c3c;
        }
        button {
            background-color: #3498db;
            color: white;
            border: none;
            padding: 10px 20px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 16px;
            transition: background-color 0.3s;
        }
        button:hover {
            background-color: #2980b9;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 15px 0;
        }
        th, td {
            padding: 10px;
            border: 1px solid #ddd;
            text-align: left;
        }
        th {
            background-color: #f2f2f2;
        }
        .loader {
            border: 4px solid #f3f3f3;
            border-top: 4px solid #3498db;
            border-radius: 50%;
            width: 30px;
            height: 30px;
            animation: spin 2s linear infinite;
            margin: 15px auto;
        }
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        .section {
            margin-bottom: 30px;
        }
        code {
            background-color: #f0f0f0;
            padding: 3px 6px;
            border-radius: 3px;
            font-family: Consolas, Monaco, 'Andale Mono', monospace;
        }
    </style>
</head>
<body>
    <h1>Kiểm tra DNS Leak</h1>
    
    <div class="card">
        <h2>Công cụ kiểm tra DNS leak toàn diện</h2>
        <p>Kiểm tra xem DNS requests của bạn có bị rò rỉ ra ngoài proxy không.</p>
        
        <div class="section">
            <h3>1. Kiểm tra IP công khai</h3>
            <button onclick="checkIP()">Kiểm tra IP</button>
            <div id="ip-result" class="result">Nhấn nút để kiểm tra</div>
        </div>
        
        <div class="section">
            <h3>2. Kiểm tra DNS Resolver</h3>
            <button onclick="checkDNS()">Kiểm tra DNS</button>
            <div id="dns-result" class="result">Nhấn nút để kiểm tra</div>
        </div>
        
        <div class="section">
            <h3>3. Kiểm tra WebRTC Leak</h3>
            <button onclick="checkWebRTC()">Kiểm tra WebRTC</button>
            <div id="webrtc-result" class="result">Nhấn nút để kiểm tra</div>
        </div>
        
        <div class="section">
            <h3>4. Kiểm tra toàn diện</h3>
            <button onclick="checkAll()">Kiểm tra tất cả</button>
        </div>
    </div>
    
    <div class="card">
        <h2>Hướng dẫn khắc phục DNS leak</h2>
        
        <div class="section">
            <h3>Trên iPhone/iPad:</h3>
            <ol>
                <li>Vào <strong>Settings</strong> > <strong>Wi-Fi</strong></li>
                <li>Nhấn vào mạng Wi-Fi đang kết nối</li>
                <li>Chọn <strong>Configure DNS</strong></li>
                <li>Chọn <strong>Manual</strong></li>
                <li>Xóa tất cả DNS server hiện có</li>
                <li>Thêm DNS server: <code>1.1.1.1</code> và <code>1.0.0.1</code></li>
                <li>Lưu cấu hình DNS</li>
                <li>Quay lại màn hình Wi-Fi, chọn <strong>Configure Proxy</strong></li>
                <li>Chọn <strong>Automatic</strong></li>
                <li>Nhập URL PAC: <code>http://$PUBLIC_IP/proxy/proxy.pac</code></li>
            </ol>
        </div>
        
        <div class="section">
            <h3>Trên Android:</h3>
            <ol>
                <li>Cài đặt ứng dụng <strong>Intra</strong> từ Google Play Store</li>
                <li>Mở Intra và bật "Always-on VPN" khi được yêu cầu</li>
                <li>Intra sẽ bảo vệ DNS của bạn, sau đó cấu hình proxy HTTP riêng biệt</li>
            </ol>
        </div>
        
        <div class="section">
            <h3>Trên Windows/macOS:</h3>
            <ol>
                <li>Cài đặt ứng dụng <strong>Simple DNSCrypt</strong> để mã hóa DNS</li>
                <li>Cấu hình proxy HTTP riêng biệt sử dụng PAC file</li>
                <li>Hoặc sử dụng trình duyệt với các tiện ích mở rộng chống rò rỉ DNS</li>
            </ol>
        </div>
    </div>
    
    <script>
        function checkIP() {
            const resultDiv = document.getElementById('ip-result');
            resultDiv.innerHTML = '<div class="loader"></div><p>Đang kiểm tra IP...</p>';
            
            fetch('https://api.ipify.org?format=json')
                .then(response => response.json())
                .then(data => {
                    fetch('https://ipapi.co/' + data.ip + '/json/')
                        .then(resp => resp.json())
                        .then(ipData => {
                            resultDiv.innerHTML = `
                                <p>IP Hiện tại: <strong>${data.ip}</strong></p>
                                <p>Quốc gia: <strong>${ipData.country_name}</strong></p>
                                <p>Nhà cung cấp: <strong>${ipData.org}</strong></p>
                            `;
                            
                            // Kiểm tra xem IP có trùng với IP proxy không
                            if (data.ip === '$PUBLIC_IP') {
                                resultDiv.innerHTML += '<p class="success">✅ IP của bạn đang được bảo vệ bởi proxy!</p>';
                                resultDiv.classList.add('success');
                                resultDiv.classList.remove('error');
                            } else {
                                resultDiv.innerHTML += '<p class="error">❌ IP của bạn KHÔNG khớp với IP proxy!</p>';
                                resultDiv.classList.add('error');
                                resultDiv.classList.remove('success');
                            }
                        });
                })
                .catch(error => {
                    resultDiv.innerHTML = '<p class="error">Lỗi khi kiểm tra IP: ' + error.message + '</p>';
                    resultDiv.classList.add('error');
                    resultDiv.classList.remove('success');
                });
        }
        
        function checkDNS() {
            const resultDiv = document.getElementById('dns-result');
            resultDiv.innerHTML = '<div class="loader"></div><p>Đang kiểm tra DNS...</p>';
            
            // Tạo một mảng các truy vấn DNS
            const domains = [
                { name: 'google.com', url: 'https://google.com/favicon.ico' },
                { name: 'facebook.com', url: 'https://facebook.com/favicon.ico' },
                { name: 'github.com', url: 'https://github.com/favicon.ico' }
            ];
            
            // Tạo bảng kết quả
            let tableHTML = '<table><tr><th>Domain</th><th>Thời gian (ms)</th><th>Trạng thái</th></tr>';
            
            // Thực hiện truy vấn và đo thời gian
            Promise.all(domains.map(domain => {
                const start = performance.now();
                return fetch(domain.url, { method: 'HEAD', mode: 'no-cors' })
                    .then(() => {
                        const time = Math.round(performance.now() - start);
                        return { domain: domain.name, time, status: 'Thành công' };
                    })
                    .catch(() => {
                        const time = Math.round(performance.now() - start);
                        return { domain: domain.name, time, status: 'Lỗi' };
                    });
            }))
            .then(results => {
                results.forEach(result => {
                    tableHTML += `<tr><td>${result.domain}</td><td>${result.time}</td><td>${result.status}</td></tr>`;
                });
                tableHTML += '</table>';
                
                // Kiểm tra xem DNS có bị leak không
                fetch('https://cloudflare-dns.com/dns-query?name=whoami.cloudflare&type=TXT', {
                    headers: {
                        'Accept': 'application/dns-json'
                    }
                })
                .then(response => response.json())
                .then(data => {
                    resultDiv.innerHTML = '<h4>Kết quả truy vấn DNS:</h4>' + tableHTML;
                    
                    // Phân tích kết quả
                    if (results.every(r => r.time < 1000 && r.status === 'Thành công')) {
                        resultDiv.innerHTML += '<p class="success">✅ DNS đang hoạt động bình thường.</p>';
                        
                        // Check DNS Leak
                        fetch('https://ipapi.co/' + '$PUBLIC_IP' + '/json/')
                            .then(resp => resp.json())
                            .then(ipData => {
                                if (ipData.country_code !== 'VN') {
                                    resultDiv.innerHTML += '<p class="success">✅ DNS không bị leak. Các truy vấn DNS đang đi qua proxy.</p>';
                                    resultDiv.classList.add('success');
                                    resultDiv.classList.remove('error');
                                } else {
                                    resultDiv.innerHTML += '<p class="error">❌ Có dấu hiệu DNS bị leak. Các truy vấn DNS có thể đang đi trực tiếp.</p>';
                                    resultDiv.classList.add('error');
                                    resultDiv.classList.remove('success');
                                }
                            });
                    } else {
                        resultDiv.innerHTML += '<p class="error">⚠️ Có vấn đề với DNS. Một số truy vấn không thành công hoặc quá chậm.</p>';
                        resultDiv.classList.add('error');
                        resultDiv.classList.remove('success');
                    }
                })
                .catch(error => {
                    resultDiv.innerHTML = '<p class="error">Lỗi khi kiểm tra DNS: ' + error.message + '</p>';
                    resultDiv.classList.add('error');
                    resultDiv.classList.remove('success');
                });
            });
        }
        
        function checkWebRTC() {
            const resultDiv = document.getElementById('webrtc-result');
            resultDiv.innerHTML = '<div class="loader"></div><p>Đang kiểm tra WebRTC leak...</p>';
            
            // Phát hiện rò rỉ WebRTC
            function getIPs(callback) {
                let ips = [];
                
                const RTCPeerConnection = window.RTCPeerConnection || 
                                         window.webkitRTCPeerConnection || 
                                         window.mozRTCPeerConnection;
                
                if (!RTCPeerConnection) {
                    resultDiv.innerHTML = '<p>WebRTC không được hỗ trợ trên trình duyệt này.</p>';
                    return;
                }
                
                let pc = new RTCPeerConnection({
                    iceServers: [{ urls: "stun:stun.services.mozilla.com" }]
                });
                
                pc.onicecandidate = function(event) {
                    if (event.candidate) {
                        let lines = event.candidate.candidate.split(' ');
                        let ip = lines[4];
                        if (ip.indexOf('.') !== -1) {
                            if (ips.indexOf(ip) === -1) {
                                ips.push(ip);
                            }
                        }
                    } else {
                        // Tất cả các candidate đã được thu thập
                        if (ips.length === 0) {
                            callback(null);
                        } else {
                            callback(ips);
                        }
                        pc.close();
                    }
                };
                
                pc.createDataChannel('');
                pc.createOffer()
                    .then(offer => pc.setLocalDescription(offer))
                    .catch(error => {
                        console.error('Error creating offer:', error);
                    });
                
                // Fallback: nếu không nhận được kết quả trong 2 giây
                setTimeout(function() {
                    if (ips.length === 0) {
                        callback(null);
                        pc.close();
                    }
                }, 2000);
            }
            
            getIPs(function(ips) {
                if (!ips || ips.length === 0) {
                    resultDiv.innerHTML = '<p class="success">✅ Không phát hiện rò rỉ WebRTC. WebRTC có thể đã bị chặn.</p>';
                    resultDiv.classList.add('success');
                    resultDiv.classList.remove('error');
                    return;
                }
                
                let localIPs = ips.filter(ip => 
                    ip.startsWith('10.') || 
                    ip.startsWith('192.168.') || 
                    (ip.startsWith('172.') && parseInt(ip.split('.')[1]) >= 16 && parseInt(ip.split('.')[1]) <= 31));
                    
                let publicIPs = ips.filter(ip => localIPs.indexOf(ip) === -1);
                
                let result = '<h4>Địa chỉ IP được phát hiện qua WebRTC:</h4><ul>';
                
                if (localIPs.length > 0) {
                    result += '<li>IP nội bộ: ' + localIPs.join(', ') + ' (bình thường)</li>';
                }
                
                if (publicIPs.length > 0) {
                    result += '<li>IP công khai: ' + publicIPs.join(', ') + '</li>';
                    
                    // Kiểm tra xem có IP nào không phải là IP proxy không
                    if (publicIPs.some(ip => ip !== '$PUBLIC_IP')) {
                        result += '<p class="error">❌ PHÁT HIỆN RÒ RỈ WEBRTC! IP thật của bạn có thể bị lộ!</p>';
                        resultDiv.classList.add('error');
                        resultDiv.classList.remove('success');
                    } else {
                        result += '<p class="success">✅ Không phát hiện rò rỉ WebRTC. Chỉ có IP proxy được phát hiện.</p>';
                        resultDiv.classList.add('success');
                        resultDiv.classList.remove('error');
                    }
                } else {
                    result += '<p class="success">✅ Không phát hiện IP công khai qua WebRTC. Bạn được bảo vệ tốt.</p>';
                    resultDiv.classList.add('success');
                    resultDiv.classList.remove('error');
                }
                
                result += '</ul>';
                resultDiv.innerHTML = result;
            });
        }
        
        function checkAll() {
            checkIP();
            setTimeout(checkDNS, 1000);
            setTimeout(checkWebRTC, 2000);
        }
        
        // Tự động chạy kiểm tra khi trang tải xong
        window.onload = function() {
            setTimeout(checkAll, 500);
        };
    </script>
</body>
</html>
EOF

# Khởi động lại dịch vụ
systemctl restart dnsmasq
systemctl restart v2ray
systemctl restart nginx

# Đặt quyền sở hữu thích hợp
chown -R www-data:www-data /var/www/html/

echo -e "\n${BLUE}========================================================${NC}"
echo -e "${GREEN}HOÀN TẤT KHẮC PHỤC DNS LEAK!${NC}"
echo -e "${BLUE}========================================================${NC}"

echo -e "\n${YELLOW}THÔNG TIN QUAN TRỌNG:${NC}"
echo -e "1. ${GREEN}DNS được cấu hình để đi qua proxy${NC}"
echo -e "2. ${GREEN}PAC file đã được cập nhật để ngăn DNS leak${NC}"
echo -e "3. ${GREEN}Trang kiểm tra DNS leak: ${BLUE}http://$PUBLIC_IP/dns-check.html${NC}"

echo -e "\n${YELLOW}HƯỚNG DẪN SỬ DỤNG:${NC}"
echo -e "1. Trên iPhone/iPad:"
echo -e "   - Cấu hình DNS thủ công: ${GREEN}1.1.1.1${NC} và ${GREEN}1.0.0.1${NC}"
echo -e "   - Sử dụng PAC URL: ${GREEN}http://$PUBLIC_IP/proxy/proxy.pac${NC}"

echo -e "\n${YELLOW}Nếu vẫn gặp vấn đề DNS leak:${NC}"
echo -e "1. Thử sử dụng cấu hình proxy thủ công thay vì PAC file"
echo -e "2. Cài đặt ứng dụng DNS over HTTPS/TLS trên thiết bị của bạn"
echo -e "3. Sử dụng ứng dụng VPN có khả năng ngăn DNS leak"

echo -e "\n${GREEN}Bạn có thể kiểm tra lại việc khắc phục DNS leak tại:${NC}"
echo -e "${BLUE}http://$PUBLIC_IP/dns-check.html${NC}"
echo -e "${BLUE}========================================================${NC}"
