#!/bin/bash

# Script khắc phục lỗi "500 Internal Privoxy Error"
# Dành cho HTTP-Shadowsocks Bridge

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

echo -e "${YELLOW}===== TIẾN HÀNH KHẮC PHỤC LỖI 500 INTERNAL PRIVOXY ERROR =====${NC}"

# Đảm bảo các gói cài đặt đầy đủ
echo -e "${GREEN}Kiểm tra và cài đặt các gói cần thiết...${NC}"
apt update
apt install -y privoxy python3-pip

# Cấu hình Privoxy đơn giản nhất để loại bỏ lỗi
echo -e "${GREEN}Đặt lại cấu hình Privoxy về mức cơ bản nhất...${NC}"

# Lấy cổng hiện tại của Privoxy
PRIVOXY_PORT=$(grep -oP 'listen-address\s+0.0.0.0:\K\d+' /etc/privoxy/config || echo "8118")
echo -e "Đang sử dụng cổng Privoxy: ${GREEN}$PRIVOXY_PORT${NC}"

# Tạo cấu hình Privoxy mới, cơ bản nhất
cat > /etc/privoxy/config << EOF
listen-address 0.0.0.0:$PRIVOXY_PORT
toggle 1
enable-remote-toggle 0
enable-remote-http-toggle 0
enable-edit-actions 0
enforce-blocks 0
buffer-limit 8192
forwarded-connect-retries 5
accept-intercepted-requests 1
allow-cgi-request-crunching 0
split-large-forms 0
socket-timeout 300
keep-alive-timeout 300
max-client-connections 128

# Tăng log chi tiết để phát hiện lỗi 
debug 1024
debug 4096
debug 8192
logdir /var/log/privoxy
logfile privoxy.log

# Giảm thiểu bộ lọc, chỉ tập trung vào chuyển tiếp
filterfile default.filter
actionsfile default.action

# Cấu hình chuyển tiếp đơn giản
forward-socks5 / 127.0.0.1:1080 .
EOF

# Kiểm tra cổng SOCKS5 có đang được sử dụng không
echo -e "${GREEN}Kiểm tra cổng SOCKS5 (1080)...${NC}"
if netstat -tuln | grep -q ":1080 "; then
  echo -e "${GREEN}Cổng 1080 đang có dịch vụ chạy.${NC}"
else
  echo -e "${RED}CẢNH BÁO: Không có dịch vụ nào đang chạy trên cổng 1080.${NC}"
  echo -e "${YELLOW}Privoxy sẽ không hoạt động nếu không có dịch vụ SOCKS5 trên cổng 1080.${NC}"
  
  # Kiểm tra Shadowsocks local có cài đặt không
  if command -v sslocal &> /dev/null; then
    echo -e "${GREEN}Tìm thấy sslocal. Đang cố khởi động Shadowsocks local...${NC}"
    
    # Tìm file cấu hình Shadowsocks
    if [ -f /etc/shadowsocks/config.json ]; then
      echo -e "${GREEN}Tìm thấy cấu hình Shadowsocks. Khởi động sslocal...${NC}"
      
      # Trích xuất thông tin từ file cấu hình
      SS_PORT=$(grep -o '"server_port":[0-9]*' /etc/shadowsocks/config.json | cut -d':' -f2)
      SS_PASSWORD=$(grep -o '"password":"[^"]*"' /etc/shadowsocks/config.json | cut -d'"' -f4)
      SS_METHOD=$(grep -o '"method":"[^"]*"' /etc/shadowsocks/config.json | cut -d'"' -f4)
      
      # Khởi động sslocal
      nohup sslocal -s 127.0.0.1 -p $SS_PORT -b 127.0.0.1 -l 1080 -k "$SS_PASSWORD" -m $SS_METHOD > /var/log/sslocal.log 2>&1 &
      
      echo -e "${GREEN}Đã khởi động sslocal. Kiểm tra log tại /var/log/sslocal.log${NC}"
    else
      echo -e "${RED}Không tìm thấy cấu hình Shadowsocks.${NC}"
    fi
  else
    echo -e "${RED}Không tìm thấy sslocal. Cài đặt lại Shadowsocks...${NC}"
    pip3 install shadowsocks
  fi
fi

# Đảm bảo thư mục log tồn tại và có quyền ghi
mkdir -p /var/log/privoxy
chmod 755 /var/log/privoxy
chown privoxy:privoxy /var/log/privoxy

# Khởi động lại Privoxy
echo -e "${GREEN}Khởi động lại Privoxy...${NC}"
systemctl restart privoxy
sleep 2

# Kiểm tra Privoxy
if systemctl is-active --quiet privoxy; then
  echo -e "${GREEN}Privoxy đã khởi động thành công!${NC}"
else
  echo -e "${RED}Privoxy không khởi động được.${NC}"
  echo -e "${YELLOW}Đang thử phương pháp khởi động thủ công...${NC}"
  
  pkill privoxy
  sleep 1
  /usr/sbin/privoxy --no-daemon /etc/privoxy/config &
  sleep 2
  
  if pgrep privoxy > /dev/null; then
    echo -e "${GREEN}Khởi động thủ công Privoxy thành công!${NC}"
  else
    echo -e "${RED}Không thể khởi động Privoxy. Đang xem log lỗi...${NC}"
    if [ -f /var/log/privoxy/privoxy.log ]; then
      echo -e "${YELLOW}10 dòng cuối của log Privoxy:${NC}"
      tail -10 /var/log/privoxy/privoxy.log
    else
      echo -e "${RED}Không tìm thấy file log Privoxy.${NC}"
    fi
  fi
fi

# Kiểm tra kết nối qua Privoxy
echo -e "${GREEN}Kiểm tra kết nối qua Privoxy...${NC}"
HTTP_TEST=$(curl -x http://localhost:$PRIVOXY_PORT -s https://httpbin.org/ip 2>/dev/null)

if [ -n "$HTTP_TEST" ]; then
  echo -e "${GREEN}Kết nối thành công qua Privoxy!${NC}"
  echo -e "Kết quả: $HTTP_TEST"
else
  echo -e "${RED}Không thể kết nối qua Privoxy.${NC}"
  
  # Thử phương án khác - dùng GOST thay Privoxy
  echo -e "${YELLOW}Đang thử dùng GOST thay thế Privoxy...${NC}"
  
  # Kiểm tra GOST đã cài đặt chưa
  if command -v /usr/local/bin/gost &> /dev/null; then
    echo -e "${GREEN}Đã tìm thấy GOST. Sử dụng GOST làm HTTP-SOCKS5 bridge...${NC}"
  else
    echo -e "${GREEN}Cài đặt GOST...${NC}"
    mkdir -p /tmp/gost
    cd /tmp/gost
    wget https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
    gunzip gost-linux-amd64-2.11.5.gz
    mv gost-linux-amd64-2.11.5 /usr/local/bin/gost
    chmod +x /usr/local/bin/gost
  fi
  
  # Dừng Privoxy
  systemctl stop privoxy
  
  # Khởi động GOST như một HTTP-SOCKS5 bridge
  echo -e "${GREEN}Khởi động GOST như HTTP-SOCKS5 bridge...${NC}"
  pkill -f "gost -L http://:$PRIVOXY_PORT"
  nohup /usr/local/bin/gost -L http://:$PRIVOXY_PORT -F socks5://127.0.0.1:1080 > /var/log/gost.log 2>&1 &
  
  sleep 2
  if pgrep -f "gost -L http://:$PRIVOXY_PORT" > /dev/null; then
    echo -e "${GREEN}GOST đã khởi động thành công!${NC}"
    
    # Cập nhật service để tự động khởi động GOST thay vì Privoxy
    cat > /etc/systemd/system/gost-bridge.service << EOF
[Unit]
Description=GOST HTTP-SOCKS5 Bridge
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -L http://:$PRIVOXY_PORT -F socks5://127.0.0.1:1080
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable gost-bridge
    
    echo -e "${GREEN}Đã cấu hình GOST để tự động khởi động khi boot.${NC}"
    
    # Kiểm tra kết nối qua GOST
    echo -e "${GREEN}Kiểm tra kết nối qua GOST...${NC}"
    HTTP_TEST=$(curl -x http://localhost:$PRIVOXY_PORT -s https://httpbin.org/ip 2>/dev/null)
    
    if [ -n "$HTTP_TEST" ]; then
      echo -e "${GREEN}Kết nối thành công qua GOST!${NC}"
      echo -e "Kết quả: $HTTP_TEST"
    else
      echo -e "${RED}Không thể kết nối qua GOST.${NC}"
    fi
  else
    echo -e "${RED}Không thể khởi động GOST.${NC}"
  fi
fi

echo -e "\n${GREEN}=== THÔNG TIN KẾT NỐI ===${NC}"
echo -e "HTTP Proxy: ${GREEN}127.0.0.1:$PRIVOXY_PORT${NC}"
echo -e "\n${GREEN}=== HƯỚNG DẪN TRÊN iPHONE ===${NC}"
echo -e "1. Vào Settings > Wi-Fi > [Mạng của bạn] > Configure Proxy > Manual"
echo -e "2. Server: ${GREEN}[IP_SERVER]${NC}"
echo -e "3. Port: ${GREEN}$PRIVOXY_PORT${NC}"
echo -e "4. Không cần Authentication"

echo -e "\n${YELLOW}TẬP TIN LOG CHO DEBUGGING:${NC}"
echo -e "- Privoxy log: ${GREEN}/var/log/privoxy/privoxy.log${NC}"
echo -e "- GOST log: ${GREEN}/var/log/gost.log${NC}"
echo -e "- Shadowsocks local log: ${GREEN}/var/log/sslocal.log${NC}"

echo -e "\n${GREEN}===== HOÀN TẤT QUÁ TRÌNH KHẮC PHỤC =====${NC}"
