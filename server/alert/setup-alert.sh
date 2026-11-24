#!/bin/bash
# NAGO alert(폰 알림, ntfy)를 설치한다. 여러 번 실행해도 안전.
#
#   서울(컨트롤 서버):  ./setup-alert.sh check
#   도쿄(서울 감시):    NTFY_URL=https://ntfy.sh/<토픽> ./setup-alert.sh watch [https://<서울 IP>:8443/healthz]
#
# - /opt/nago-alert/alert.py + systemd 타이머 nago-alert.timer(1분마다)
# - 설정 /etc/nago/alert.json 이 없으면 만든다. 토픽은 NTFY_URL로 주거나, 없으면 무작위로 만든다(서울에서 처음 한 번).
#   폰: ntfy 앱 설치 → "+" → 서버 ntfy.sh, 토픽 이름 입력(설치 끝에 출력)
# - 토픽 이름을 아는 사람은 알림을 볼 수 있으니 레포·채팅에 올리지 말 것
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "root로 실행" >&2; exit 1; }
ROLE="${1:-check}"
shift || true
case "$ROLE" in
  check) ARGS="check" ;;
  watch) ARGS="watch ${*:-https://141.164.54.197:8443/healthz}" ;;
  *) echo "사용법: $0 check | watch [URL...]" >&2; exit 1 ;;
esac

echo ">> 파일"
install -d -m 755 /opt/nago-alert
install -m 644 alert.py /opt/nago-alert/alert.py
install -d -m 700 /etc/nago /var/lib/nago-alert

if [ ! -s /etc/nago/alert.json ]; then
  URL="${NTFY_URL:-https://ntfy.sh/nago-$(head -c 48 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 20)}"
  umask 077
  printf '{"ntfy": "%s", "hourly_gb": 20, "budget_usd": 40, "credit_usd": 10, "disk_pct": 85, "peer_online": true, "digest_hour": 9}\n' "$URL" > /etc/nago/alert.json
  echo "새 설정을 만들었어요: /etc/nago/alert.json"
fi
chmod 600 /etc/nago/alert.json

echo ">> systemd nago-alert ($ARGS)"
cat > /etc/systemd/system/nago-alert.service <<UNIT
[Unit]
Description=NAGO alert ($ROLE)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/nago-alert/alert.py $ARGS
Nice=10
TimeoutStartSec=120
UNIT
cat > /etc/systemd/system/nago-alert.timer <<'UNIT'
[Unit]
Description=NAGO alert every minute

[Timer]
OnBootSec=90
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now nago-alert.timer >/dev/null
systemctl start nago-alert.service || true
systemctl is-active nago-alert.timer
echo "ntfy 토픽: $(python3 -c 'import json;print(json.load(open("/etc/nago/alert.json"))["ntfy"].rsplit("/",1)[1])')"
