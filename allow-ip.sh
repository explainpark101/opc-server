#!/bin/bash

# ====================================================================================
# Nginx 설정 수정 스크립트 (IP 기반 접근 제어/분기 기능 추가)
# ====================================================================================
#
# 이 스크립트는 기존에 Certbot으로 SSL 설정까지 완료된 Nginx 설정을 수정합니다.
# 1. 사용자로부터 도메인, 관리자용 앱 포트, 허용할 IP 목록을 입력받습니다.
# 2. 허용되지 않은 IP의 요청을 '공개용 포트로 전달'할지 '모두 거부'할지 선택받습니다.
# 3. 선택에 따라 Nginx 설정 파일을 동적으로 수정합니다.
# 4. Nginx 설정을 테스트하고 리로드하여 변경 사항을 적용합니다.
#
# [주의] 이 스크립트는 'install_nginx_python11' 스크립트를 실행한 후에 사용해야 합니다.
#
# ====================================================================================

# 스크립트 실행 중 오류 발생 시 즉시 중단
set -euo pipefail

# --- 변수 및 환경 설정 ---
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

# 2. 사용자로부터 정보 입력받기
log_info "기존 Nginx 설정을 수정하여 IP 기반 접근 제어/분기 기능을 추가합니다."
read -p "설정을 수정할 도메인 이름을 입력하세요: " DOMAIN
read -p "관리자용(허용된 IP) 앱의 포트 번호를 입력하세요 (예: 8080): " ADMIN_APP_PORT
read -p "관리자 접근을 허용할 IP 주소들을 띄어쓰기로 구분하여 입력하세요: " ALLOWED_IPS
read -p "허용되지 않은 IP의 요청을 어떻게 처리할까요? (1: 공개용 포트로 전달, 2: 모든 접속 거부) [1/2]: " ACTION_CHOICE

# 입력값 검증
if [ -z "$DOMAIN" ] || [ -z "$ADMIN_APP_PORT" ] || [ -z "$ALLOWED_IPS" ]; then
    log_error "도메인, 관리자 포트, 허용 IP는 필수 입력입니다."
fi

# 설정 파일 경로 확인
CONF_FILE="/etc/nginx/conf.d/${DOMAIN}.conf"
GEO_FILE="/etc/nginx/conf.d/geoip_map.conf"

if [ ! -f "$CONF_FILE" ]; then
    log_error "원본 설정 파일(${CONF_FILE})을 찾을 수 없습니다. 도메인 이름을 확인해 주세요."
fi

# 3. 기존 Nginx 설정 파일 수정
log_info "기존 설정 파일(${CONF_FILE})을 백업하고 수정합니다..."
# 원본 파일 백업
cp "$CONF_FILE" "${CONF_FILE}.bak_$(date +%F-%T)"

REPLACEMENT_BLOCK=""
FINAL_MESSAGE=""

# 선택에 따라 Nginx 설정 블록을 다르게 생성
case "$ACTION_CHOICE" in
    1) # 공개용 포트로 전달
        read -p "공개용(그 외 IP) 앱의 포트 번호를 입력하세요 (예: 3000): " PUBLIC_APP_PORT
        if [ -z "$PUBLIC_APP_PORT" ]; then
            log_error "공개용 앱 포트를 입력해야 합니다."
        fi

        log_info "'geo' IP 맵 파일을 생성합니다: ${GEO_FILE}"
        {
            echo "geo \$remote_addr \$is_allowed {"
            echo "    default 0;"
            for ip in $ALLOWED_IPS; do
                echo "    ${ip} 1;"
            done
            echo "}"
        } > "$GEO_FILE"

        read -r -d '' REPLACEMENT_BLOCK << EOM
        # \$is_allowed 변수 값에 따라 다른 포트로 포워딩
        if (\$is_allowed) {
            proxy_pass http://127.0.0.1:${ADMIN_APP_PORT};
        }
        if (\$is_allowed = 0) {
            proxy_pass http://127.0.0.1:${PUBLIC_APP_PORT};
        }

        # 공통 프록시 헤더
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
EOM
        FINAL_MESSAGE="이제 https://${DOMAIN} 으로 접속 시 허용된 IP는 ${ADMIN_APP_PORT}로, 그 외 IP는 ${PUBLIC_APP_PORT}로 연결됩니다."
        ;;
    2) # 모든 접속 거부
        # 'allow' 규칙들을 문자열로 생성
        ALLOW_RULES=""
        for ip in $ALLOWED_IPS; do
            ALLOW_RULES+="        allow ${ip};"$'\n'
        done

        read -r -d '' REPLACEMENT_BLOCK << EOM
        # --- IP 접근 제어 ---
${ALLOW_RULES}
        # 나머지 모든 IP는 접근을 차단합니다.
        deny all;

        # --- 리버스 프록시 설정 (허용된 IP만 이 부분에 도달) ---
        proxy_pass http://127.0.0.1:${ADMIN_APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
EOM
        FINAL_MESSAGE="이제 https://${DOMAIN} 으로 접속 시 허용된 IP는 ${ADMIN_APP_PORT}로 연결되고, 그 외 IP는 거부됩니다."
        ;;
    *)
        log_error "잘못된 선택입니다. 1 또는 2를 입력하세요."
        ;;
esac

# 임시 파일을 사용하여 Nginx 설정 파일을 안전하게 수정
TMP_FILE=$(mktemp)
in_location_block=false

while IFS= read -r line || [[ -n "$line" ]]; do
    # 'location / {' 블록 시작 감지
    if [[ "$line" =~ ^[[:space:]]*location[[:space:]]+\/[[:space:]]*\{ ]]; then
        echo "$line" >> "$TMP_FILE"
        echo "$REPLACEMENT_BLOCK" >> "$TMP_FILE"
        in_location_block=true
    # 원본 블록의 끝 감지
    elif [[ "$line" =~ ^[[:space:]]*\} && "$in_location_block" == "true" ]]; then
        in_location_block=false
        # 원본 블록의 내용은 건너뛰고 닫는 괄호만 추가
        echo "$line" >> "$TMP_FILE"
    # 블록 바깥의 내용은 그대로 복사
    elif [[ "$in_location_block" == "false" ]]; then
        echo "$line" >> "$TMP_FILE"
    fi
done < "$CONF_FILE"

# 원본 파일과 수정한 임시 파일 교체
mv "$TMP_FILE" "$CONF_FILE"

log_info "설정 파일 수정이 완료되었습니다."

# 4. Nginx 설정 테스트 및 리로드
log_info "Nginx 설정을 테스트하고 적용합니다..."
if ! nginx -t; then
    log_error "수정된 Nginx 설정 파일에 오류가 있습니다. ${CONF_FILE} 파일을 확인해 주세요."
fi

systemctl reload nginx
log_info "Nginx 서비스가 성공적으로 리로드되었습니다."

# --- 최종 완료 ---
log_info "모든 설정이 완료되었습니다!"
log_info "${FINAL_MESSAGE}"
