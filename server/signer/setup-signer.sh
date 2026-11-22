#!/bin/bash
# NAGO signer를 서울 서버(컨트롤 서버와 같은 서버)에 설치한다. 여러 번 실행해도 안전.
#
#   cd /root/server/signer && ./setup-signer.sh
#
# - /opt/nago-sign/signer.py + systemd nago-sign (127.0.0.1:8090)
# - rcodesign(apple-codesign 0.29.0): /opt/nago-sign/bin/rcodesign 이 없으면
#   RCODESIGN_BIN=<파일> 로 주거나, 없으면 cargo로 musl 정적 빌드(몇 분)
# - 인증서: /etc/nago/sign/certs/<번호>-<이름>.json  {"p12": base64, "password": "…", "profile": base64}
#   (레포에 넣지 않는다. 번호 순서가 페이지의 선택 순서, 맨 앞이 기본)
# - Caddy: control/setup-control.sh의 Caddyfile에 /sign* → 8090 경로가 들어 있다(없으면 setup-control.sh를 다시 실행)
# - 주소: https://<서울 IP>:8443/sign/?t=<대시보드 토큰>
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "root로 실행" >&2; exit 1; }

echo ">> 파일"
install -d -m 755 /opt/nago-sign /opt/nago-sign/bin
install -m 644 signer.py /opt/nago-sign/signer.py
install -d -m 700 /etc/nago/sign /etc/nago/sign/certs /var/lib/nago-sign

echo ">> rcodesign"
if [ -n "${RCODESIGN_BIN:-}" ]; then
  install -m 755 "$RCODESIGN_BIN" /opt/nago-sign/bin/rcodesign
elif [ ! -x /opt/nago-sign/bin/rcodesign ]; then
  CARGO=$(command -v cargo || echo /root/.cargo/bin/cargo)
  if [ ! -x "$CARGO" ]; then
    curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    CARGO=/root/.cargo/bin/cargo
  fi
  apt-get install -y -qq musl-tools >/dev/null
  "$(dirname "$CARGO")/rustup" target add x86_64-unknown-linux-musl
  CC_x86_64_unknown_linux_musl=musl-gcc CARGO_PROFILE_RELEASE_STRIP=true \
    "$CARGO" install apple-codesign --version 0.29.0 --locked --target x86_64-unknown-linux-musl --root /opt/nago-sign
fi
/opt/nago-sign/bin/rcodesign --version

echo ">> systemd nago-sign"
cat > /etc/systemd/system/nago-sign.service <<'UNIT'
[Unit]
Description=NAGO signer (IPA sign + OTA install)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /opt/nago-sign/signer.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1
# 서명은 CPU를 많이 쓴다: VPN 트래픽이 먼저
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable nago-sign >/dev/null
systemctl restart nago-sign
sleep 2
systemctl is-active nago-sign
curl -s http://127.0.0.1:8090/sign/healthz; echo
grep -q '/sign\*' /etc/caddy/Caddyfile || echo "!! Caddyfile에 /sign 경로가 없음: control/setup-control.sh를 다시 실행"
echo "인증서: $(ls /etc/nago/sign/certs | tr '\n' ' ')"
