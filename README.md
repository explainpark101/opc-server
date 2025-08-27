# opc-server

Oracle Cloud 인스턴스에서 Nginx, Certbot, DuckDNS를 이용한 자동 HTTPS 설정 도구입니다.

## 🚀 주요 기능

- **Nginx 리버스 프록시 설정**: 웹 애플리케이션을 안전하게 프록시
- **Let's Encrypt SSL 인증서 자동 발급**: HTTPS 보안 연결 설정
- **DuckDNS IP 자동 갱신**: 동적 IP 주소 변경 시 자동 업데이트
- **방화벽 자동 설정**: HTTP(80) 및 HTTPS(443) 포트 개방
- **SELinux 정책 설정**: Oracle Linux 9 호환 보안 정책 적용
- **자동 갱신 시스템**: SSL 인증서 및 DuckDNS IP 자동 갱신

## 📋 사전 요구사항

- Oracle Cloud 인스턴스 (Oracle Linux 9 권장)
- 루트 권한 (sudo 접근)
- DuckDNS 도메인 및 토큰
- 이메일 주소 (SSL 인증서 발급용)

## 🔧 설치 방법

### 1. 스크립트 실행 권한 부여
```bash
chmod +x install.sh
```

### 2. 설정 파일 생성 및 수정
스크립트 실행 시 자동으로 `config.sh` 파일이 생성됩니다. 다음 정보를 입력하세요:

```bash
# 웹 서버 설정 변수
DOMAIN="your-domain.duckdns.org"
EMAIL="your-email@example.com"
APP_PORT=8080
DUCKDNS_TOKEN="your-duckdns-token"
```

### 3. 스크립트 실행
```bash
sudo install.sh
```

## ☁️ Oracle Cloud 설정

### Ingress Rule 설정
Oracle Cloud 콘솔에서 다음 포트를 열어주세요:

- **포트 80**: HTTP 트래픽용
- **포트 443**: HTTPS 트래픽용

설정 방법:
1. Oracle Cloud 콘솔 → 네트워킹 → 가상 클라우드 네트워크
2. 해당 VCN 선택 → 보안 목록
3. 인바운드 규칙 추가:
   - 소스: 0.0.0.0/0
   - 포트: 80 (HTTP)
   - 소스: 0.0.0.0/0
   - 포트: 443 (HTTPS)

## ⚙️ 자동화된 설정 내용

### Nginx 설정
- 리버스 프록시 구성
- SSL/TLS 종료
- 웹소켓 지원
- 보안 헤더 설정

### SSL 인증서 관리
- Let's Encrypt 인증서 자동 발급
- 90일마다 자동 갱신
- Nginx 자동 재설정

### DuckDNS 통합
- 5분마다 IP 주소 자동 갱신
- 시스템 로그에 갱신 기록
- 네트워크 연결 확인

### 보안 설정
- SELinux 정책 최적화
- 방화벽 규칙 자동 적용
- 시스템 서비스 자동 활성화

## 📁 설정 파일

### config.sh
```bash
DOMAIN="your-domain.duckdns.org"    # DuckDNS 도메인
EMAIL="your-email@example.com"       # SSL 인증서용 이메일
APP_PORT=8080                        # 애플리케이션 포트
DUCKDNS_TOKEN="your-duckdns-token"   # DuckDNS 토큰
```

## 🔍 문제 해결

### 로그 확인
```bash
# Nginx 로그
sudo journalctl -u nginx

# DuckDNS 업데이트 로그
sudo journalctl -u duckdns-update.service

# Certbot 갱신 로그
sudo journalctl -u certbot-renew.service
```

### 수동 SSL 갱신 테스트
```bash
sudo certbot renew --dry-run
```

### DuckDNS 수동 업데이트
```bash
sudo /usr/local/bin/update_duckdns.sh
```

## ✅ 완료 확인

설정 완료 후 다음 URL로 접속하여 HTTPS가 정상 작동하는지 확인하세요:
```
https://your-domain.duckdns.org
```

## 📝 참고사항

- 이 스크립트는 Oracle Linux 9 + Python 3.11 환경에 최적화되어 있습니다
- SELinux가 활성화된 환경에서 안전하게 동작합니다
- 모든 설정은 자동으로 백업되며 필요시 롤백 가능합니다
- 시스템 재부팅 후에도 모든 서비스가 자동으로 시작됩니다
