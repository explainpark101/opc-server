#!/bin/bash

# ====================================================================================
# Nginx, Certbot, DuckDNS 자동 설정 (Oracle Linux 9 + Python 3.11 + SELinux 호환)
# ====================================================================================
#
# 이 스크립트는 다음 작업을 자동화합니다:
# 1. 필수 시스템 패키지 설치 (Nginx, Python 3.11, 개발 도구, SELinux 유틸리티 등)
# 2. Python 3.11 가상 환경을 생성하고 pip를 통해 Certbot 설치
# 3. Nginx 리버스 프록시를 위한 SELinux 정책 설정
# 4. 방화벽 설정 (80, 443 포트 개방)
# 5. Nginx를 리버스 프록시로 설정
# 6. Certbot으로 Let's Encrypt SSL 인증서 발급
# 7. Certbot 인증서 및 DuckDNS IP 자동 갱신을 위한 systemd 타이머 생성/활성화
#
# ====================================================================================

# 스크립트 실행 중 오류 발생 시 즉시 중단
set -euo pipefail

# --- 변수 및 환경 설정 ---
CONFIG_FILE="./config.sh"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

# 로그 출력 함수
log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }

# --- 스크립트 실행 ---

# 1. 루트 권한 확인
if [ "$EUID" -ne 0 ]; then
    log_error "이 스크립트는 반드시 루트(root) 권한으로 실행해야 합니다."
fi

# 2. 설정 파일 확인 및 로드
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_warn "'$CONFIG_FILE' 파일이 없습니다. 설정 예시 파일을 생성합니다."
    cat > "$CONFIG_FILE" << EOF
    chmod 777 $CONFIG_FILE
# --- 웹 서버 설정 변수 ---
DOMAIN="your-domain.duckdns.org"
EMAIL="your-email@example.com"
APP_PORT=8080
DUCKDNS_TOKEN="your-duckdns-token"
EOF
    log_info "'$CONFIG_FILE' 파일이 생성되었습니다. 파일에 정보를 정확히 입력 후 다시 실행해 주십시오."
    exit 0
fi
source "$CONFIG_FILE"
log_info "설정 파일을 로드했습니다: DOMAIN=${DOMAIN}, EMAIL=${EMAIL}, APP_PORT=${APP_PORT}"

# 3. 패키지 관리자 확인
if ! command -v dnf &> /dev/null; then
    log_error "'dnf' 패키지 관리자를 찾을 수 없습니다. 이 스크립트는 RHEL 9 계열에 최적화되어 있습니다."
fi
PKG_MANAGER="dnf"
log_info "패키지 관리자로 '${PKG_MANAGER}'를 사용합니다."

# 4. 필수 패키지 및 Certbot 설치
log_info "기본 패키지(nginx, firewalld, curl)를 설치합니다..."
$PKG_MANAGER install -y nginx firewalld curl

log_info "Certbot 설치를 위해 최신 Python(3.11) 및 개발 도구, SELinux 유틸리티를 설치합니다..."
$PKG_MANAGER install -y python3.11 python3.11-pip gcc augeas-libs openssl-devel libffi-devel redhat-rpm-config ca-certificates policycoreutils-python-utils

log_info "시스템 충돌 방지를 위해 '/opt/certbot/'에 Python 3.11 가상 환경을 생성합니다..."
python3.11 -m venv /opt/certbot/
log_info "가상 환경 내 pip를 업그레이드하고 Certbot을 설치합니다..."
/opt/certbot/bin/pip install --upgrade pip
/opt/certbot/bin/pip install certbot certbot-nginx

log_info "Certbot 명령을 시스템 경로에 연결합니다..."
if [ ! -L /usr/bin/certbot ]; then
    ln -s /opt/certbot/bin/certbot /usr/bin/certbot
fi
log_info "패키지 및 Certbot 설치가 완료되었습니다."

# 5. SELinux 설정 (리버스 프록시 허용)
log_info "Nginx가 리버스 프록시로 동작할 수 있도록 SELinux 정책을 설정합니다..."
setsebool -P httpd_can_network_connect 1
log_info "SELinux 'httpd_can_network_connect' 정책이 활성화되었습니다."

# 6. 서비스 활성화
log_info "Nginx와 firewalld 서비스를 시작하고 부팅 시 자동 실행되도록 설정합니다."
systemctl enable --now nginx
systemctl enable --now firewalld
log_info "서비스 활성화가 완료되었습니다."

# 7. 방화벽 설정
log_info '방화벽에서 HTTP(80) 및 HTTPS(443) 포트를 영구적으로 개방합니다.'
firewall-cmd --permanent --zone=public --add-service=http
firewall-cmd --permanent --zone=public --add-service=https
firewall-cmd --reload
log_info "방화벽 설정이 적용되었습니다."

# 8. Nginx 리버스 프록시 설정
log_info "Nginx 리버스 프록시 설정을 생성합니다."
cat > "/etc/nginx/conf.d/${DOMAIN}.conf" << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
if ! nginx -t; then log_error "Nginx 설정 파일에 오류가 있습니다."; fi
systemctl reload nginx

# 8.1. duckdns 설정
log_info "DuckDNS 설정을 시작합니다."
curl -s "https://www.duckdns.org/update?domains=${DOMAIN}&token=${DUCKDNS_TOKEN}"
log_info "DuckDNS 설정이 완료되었습니다."

# 9. Certbot으로 SSL 인증서 발급
log_info "Certbot을 실행하여 '${DOMAIN}'에 대한 SSL 인증서를 발급받습니다..."
certbot --nginx --non-interactive --agree-tos -m "${EMAIL}" -d "${DOMAIN}" --redirect
if [ $? -ne 0 ]; then log_error "Certbot 실행 중 오류가 발생했습니다."; fi
log_info "SSL 인증서가 성공적으로 발급 및 적용되었습니다."

# 10. Certbot 자동 갱신 타이머 생성
log_info "Certbot 인증서 자동 갱신을 위한 systemd 타이머를 생성합니다."
cat > /etc/systemd/system/certbot-renew.service << EOF
[Unit]
Description=Renew Let's Encrypt certificates
[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet
EOF

cat > /etc/systemd/system/certbot-renew.timer << EOF
[Unit]
Description=Run certbot renew twice daily
[Timer]
OnCalendar=*-*-* 00:00:00
OnCalendar=*-*-* 12:00:00
RandomizedDelaySec=3600
[Install]
WantedBy=timers.target
EOF

systemctl enable --now certbot-renew.timer
log_info "자동 갱신 프로세스를 테스트합니다 (실제 갱신은 수행하지 않음)."
certbot renew --dry-run

# 11. DuckDNS IP 자동 갱신 설정
log_info "DuckDNS IP 주소 자동 갱신을 위한 systemd 타이머를 설정합니다."
cat > /usr/local/bin/update_duckdns.sh << EOF
#!/bin/bash
DOMAIN="${DOMAIN}"
TOKEN="${DUCKDNS_TOKEN}"
# 현재 공인 IP 주소를 조회합니다.
CURRENT_IP=\$(/usr/bin/curl -s icanhazip.com)
# 조회된 IP로 DuckDNS를 업데이트하고 결과를 로그에 기록합니다.
RESPONSE=\$(/usr/bin/curl -s "https://www.duckdns.org/update?domains=\${DOMAIN}&token=\${TOKEN}&ip=\${CURRENT_IP}")
/usr/bin/logger -t duckdns-update "Domain: \${DOMAIN}, IP: \${CURRENT_IP}, Response: \${RESPONSE}"
EOF
chmod +x /usr/local/bin/update_duckdns.sh

cat > /etc/systemd/system/duckdns-update.service << EOF
[Unit]
Description=Update DuckDNS IP address
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/update_duckdns.sh
EOF

cat > /etc/systemd/system/duckdns-update.timer << EOF
[Unit]
Description=Run duckdns-update.service every 5 minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF

log_info "systemd 데몬을 리로드하고 타이머를 활성화합니다."
systemctl daemon-reload
systemctl enable --now duckdns-update.timer
log_info "DuckDNS 자동 갱신 타이머가 활성화되었습니다."
log_info "갱신 로그는 'journalctl -u duckdns-update.service' 명령으로 확인할 수 있습니다."

# --- 최종 완료 ---
log_info "모든 설정이 완료되었습니다!"
log_info "이제 https://${DOMAIN} 으로 접속하여 웹 서버가 정상적으로 동작하는지 확인하십시오."