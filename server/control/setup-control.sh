#!/usr/bin/env bash
#
# NAGO VPN 컨트롤 서버(국가 API + 대시보드 + 피어 관리)를 서울 Vultr 서버에 올린다.
# AWS 시절 Lambda 두 개 + API Gateway를 대신한다. 여러 번 실행해도 안전(설정·키는 있으면 그대로 둠).
#
#   sudo NAGO_KEY='<VPN 비밀번호>' ./setup-control.sh            # IP 주소로 HTTPS (Let's Encrypt IP 인증서)
#   sudo NAGO_KEY='<VPN 비밀번호>' DOMAIN=vpn.example.com ./setup-control.sh   # 도메인이 있으면
#
# - 앱(127.0.0.1:8080, root) ← Caddy(HTTPS 443, 인증서 자동). Caddy는 TCP 80/443만 쓴다
#   (UDP 443은 WireGuard가 쓰므로 HTTP/3는 끈다)
# - 설정 /etc/nago/control.json, 상태 /var/lib/nago, 다른 서버용 SSH 키 /etc/nago/id_ed25519
# - 끝나면 SSH 공개키를 출력한다 → jp/us/uk 서버의 /root/.ssh/authorized_keys에 넣는다
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SRC="$(cd "$(dirname "$0")" && pwd)"
APP=/opt/nago-control
ETC=/etc/nago
STATE=/var/lib/nago
PUBLIC_IP="${PUBLIC_IP:-$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')}"
SITE="${DOMAIN:-$PUBLIC_IP}"

echo ">> 패키지 (python3, openssh-client, caddy)"
apt-get -o DPkg::Lock::Timeout=120 update -y >/dev/null
apt-get -o DPkg::Lock::Timeout=120 install -y python3 openssh-client curl gnupg debian-keyring \
    debian-archive-keyring apt-transport-https >/dev/null
if ! command -v caddy >/dev/null; then
    # Caddy 공식 저장소(우분투 기본 저장소의 caddy는 너무 오래돼서 IP 인증서를 못 받는다)
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get -o DPkg::Lock::Timeout=120 update -y >/dev/null
    apt-get -o DPkg::Lock::Timeout=120 install -y caddy >/dev/null
fi
caddy version

echo ">> 앱 설치 (${APP})"
install -d -m 755 "$APP"
install -m 644 "$SRC/app.py" "$SRC/nago-peer.py" "$APP/"
install -d -m 700 "$ETC" "$STATE"

if [ ! -f "$ETC/control.json" ]; then
    echo ">> 새 설정 ${ETC}/control.json (서울 IP ${PUBLIC_IP})"
    : "${NAGO_KEY:?처음 설치할 때는 NAGO_KEY(VPN 비밀번호)가 필요합니다}"
    TOKEN="$(openssl rand -hex 24)" KEY="$NAGO_KEY" IP="$PUBLIC_IP" python3 - "$SRC/control.example.json" "$ETC/control.json" <<'PY'
import hashlib, json, os, sys
cfg = json.load(open(sys.argv[1]))
cfg["token"] = os.environ["TOKEN"]
cfg["key_sha256"] = hashlib.sha256(os.environ["KEY"].encode()).hexdigest()
for n in cfg["nodes"]:
    if n["code"] == "kr":
        n["addr"] = n["id"] = os.environ["IP"]
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as fh:
    json.dump(cfg, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
    echo "   jp/us/uk의 addr(서버 IP), vultr_id, 요금은 직접 채워 넣고 'systemctl restart nago-control'"
elif [ -n "${NAGO_KEY:-}" ]; then
    echo ">> VPN 비밀번호 해시 갱신"
    KEY="$NAGO_KEY" python3 - "$ETC/control.json" <<'PY'
import hashlib, json, os, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["key_sha256"] = hashlib.sha256(os.environ["KEY"].encode()).hexdigest()
json.dump(cfg, open(p, "w"), ensure_ascii=False, indent=2)
PY
fi
chmod 600 "$ETC/control.json"

if [ ! -f "$ETC/id_ed25519" ]; then
    echo ">> 다른 서버에 붙을 SSH 키 만들기"
    ssh-keygen -q -t ed25519 -N '' -C nago-control -f "$ETC/id_ed25519"
fi

echo ">> systemd: nago-control"
cat > /etc/systemd/system/nago-control.service <<UNIT
[Unit]
Description=NAGO VPN control server (region API + dashboard)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 ${APP}/app.py
Environment=NAGO_CONFIG=${ETC}/control.json NAGO_STATE=${STATE} PYTHONUNBUFFERED=1
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable nago-control >/dev/null
systemctl restart nago-control

echo ">> Caddy: https://${SITE} → 127.0.0.1:8080"
if [ -n "${DOMAIN:-}" ]; then
    TLS=""
else
    # IP 주소 인증서는 Let's Encrypt의 짧은 수명(약 6일) 프로필로만 나온다. Caddy가 알아서 갱신한다.
    TLS=$'    tls {\n        issuer acme {\n            profile shortlived\n        }\n    }'
fi
cat > /etc/caddy/Caddyfile <<CADDY
{
    servers {
        protocols h1 h2
    }
}

https://${SITE} {
${TLS}
    encode gzip
    reverse_proxy 127.0.0.1:8080
}
CADDY
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
systemctl enable caddy >/dev/null
systemctl reload caddy 2>/dev/null || systemctl restart caddy

echo ">> 확인"
for i in $(seq 1 10); do
    curl -fsS http://127.0.0.1:8080/healthz >/dev/null && break
    sleep 1
done
systemctl is-active nago-control
echo "   (인증서 발급에 몇십 초 걸릴 수 있음. 'journalctl -u caddy -f'로 확인)"
echo
echo "API      https://${SITE}/region   (앱의 RegionAPI)"
echo "대시보드  https://${SITE}/?format=json   (앱의 DashAPI)"
echo "사이트    https://${SITE}/?t=$(python3 -c "import json;print(json.load(open('$ETC/control.json'))['token'])")"
echo
echo "jp/us/uk 서버의 /root/.ssh/authorized_keys에 넣을 키:"
cat "$ETC/id_ed25519.pub"
