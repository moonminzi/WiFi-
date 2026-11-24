#!/bin/bash
# NAGO share(친구에게 기간 한정 다운로드 링크)를 서울 서버에 설치한다. 여러 번 실행해도 안전.
#
#   cd /root/server/share && ./setup-share.sh
#
# - /opt/nago-share/share.py + systemd nago-share (127.0.0.1:8091)
# - 파일: /var/lib/nago-share/<id>/ (기간이 지나면 지움)
# - 한도: SHARE_MAX_GB(기본 25) · 디스크는 SHARE_MIN_FREE_GB(기본 8)만큼 늘 남김 ·
#   받기 속도 합계 SHARE_RATE_MBPS(기본 300) → 유닛의 Environment에서 바꿈
# - QR 코드: qrencode(우분투 패키지)
# - Caddy: control/setup-control.sh의 Caddyfile에 /share* → 8091 경로가 들어 있다(없으면 setup-control.sh를 다시 실행)
# - 주소: https://<서울 IP>:8443/share/?t=<대시보드 토큰>
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "root로 실행" >&2; exit 1; }

echo ">> 파일"
install -d -m 755 /opt/nago-share
install -m 644 share.py /opt/nago-share/share.py
install -d -m 700 /var/lib/nago-share
command -v qrencode >/dev/null || { apt-get update -qq; apt-get install -y -qq qrencode >/dev/null; }   # QR 코드

echo ">> systemd nago-share"
cat > /etc/systemd/system/nago-share.service <<'UNIT'
[Unit]
Description=NAGO share (time-limited download links)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /opt/nago-share/share.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1
Environment=SHARE_MAX_GB=25
Environment=SHARE_MIN_FREE_GB=8
# 받기 속도 합계 한도(Mbps). 회선을 다 쓰지 않아 같은 서버의 VPN이 느려지지 않게. 0이면 제한 없음
Environment=SHARE_RATE_MBPS=300
# 파일 전송은 VPN 트래픽보다 뒤로(CPU·디스크)
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable nago-share >/dev/null
systemctl restart nago-share
sleep 2
systemctl is-active nago-share
curl -s http://127.0.0.1:8091/share/healthz; echo
grep -q '/share\*' /etc/caddy/Caddyfile || echo "!! Caddyfile에 /share 경로가 없음: control/setup-control.sh를 다시 실행"
