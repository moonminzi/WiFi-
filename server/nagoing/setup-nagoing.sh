#!/bin/bash
# nagoing 서버 프록시를 올린다(막힌 망 우회). 여러 번 실행해도 안전(idempotent).
#
# 하는 일: WG(wg0, udp 51820)는 그대로 두고, 그 앞에 nagoing 프록시를 세운다.
#   - TCP 443   : 진짜 TLS 1.3(rustls) — 학교·회사·호텔처럼 VPN 막는 망의 핵심 경로(①)
#   - UDP 51821 : QUIC 모양 — 손실 보정(FEC)·빠른 전환이 사는 경로(②③). udp 443은 기존 WG REDIRECT가
#                 먼저 가로채므로 쓰지 않고 전용 포트를 쓴다
#   받은 걸 인증·복호화해 로컬 wg0(127.0.0.1:51820)로 넘긴다. WireGuard는 하나도 안 바뀐다.
#
# v2 키: HELLO 인증에 wg0의 WireGuard 개인키를 쓴다(클라가 이미 아는 serverPub의 짝 — 새 키 배포 없음).
#   /etc/nago/wg.key(root 전용)로 꺼내 두고, TLS용 자체서명 인증서도 서버마다 만든다. 서비스(DynamicUser)는
#   systemd LoadCredential로만 받아 읽는다. wg0 키를 바꿨으면 이 스크립트를 다시 돌린다.
#
# 빌드: NagoTun 크레이트(엔진 포함)를 그대로 빌드한다 — crates.io에서 의존 크레이트를 받으므로 서버에 외부 접속이 필요하다.
#
# ★ AWS 보안그룹(SG)에서 다음을 열어야 바깥에서 닿는다(호스트 iptables INPUT은 ACCEPT라 따로 안 건드린다):
#     - inbound TCP 443      0.0.0.0/0
#     - inbound UDP 51821     0.0.0.0/0
#   예) aws ec2 authorize-security-group-ingress --group-id <sg> --ip-permissions \
#        IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=0.0.0.0/0}]' \
#        IpProtocol=udp,FromPort=51821,ToPort=51821,IpRanges='[{CidrIp=0.0.0.0/0}]'
#
# 환경변수(선택): NAGO_PSK(난독화 키, 클라와 같아야 함), NAGO_UDP_PORT, NAGO_TCP_PORT, WG_ADDR, REPO, FORCE_BUILD=1
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# SSM/cloud-init 등 HOME 없는 환경에서도 돌게(rustup·cargo가 HOME을 쓴다).
export HOME="${HOME:-/root}"

PSK="${NAGO_PSK:-nago-obfs-v1}"
UDP_PORT="${NAGO_UDP_PORT:-51821}"
TCP_PORT="${NAGO_TCP_PORT:-443}"
WG_ADDR="${WG_ADDR:-127.0.0.1:51820}"
REPO="${REPO:-https://github.com/moonminzi/WiFi-}"
BRANCH="${NAGO_BRANCH:-main}"   # nagoing이 main에 병합되기 전에는 기능 브랜치를 가리킨다
SRC=/opt/nago/WiFi-
BIN=/usr/local/sbin/nagoing-proxy

echo ">> C 링커 확인/설치(rustc가 링크에 cc를 쓴다 — 최소 우분투엔 없다)"
command -v cc >/dev/null 2>&1 || apt-get -o DPkg::Lock::Timeout=120 install -y build-essential >/dev/null \
  || { apt-get -o DPkg::Lock::Timeout=120 update -y >/dev/null; apt-get -o DPkg::Lock::Timeout=120 install -y build-essential >/dev/null; }

echo ">> Rust 확인/설치"
if ! command -v cargo >/dev/null 2>&1; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi
if ! command -v cargo >/dev/null 2>&1; then
  command -v curl >/dev/null || apt-get -o DPkg::Lock::Timeout=120 install -y curl >/dev/null
  curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal >/dev/null
  export PATH="$HOME/.cargo/bin:$PATH"
fi

echo ">> 소스 받기/갱신"
command -v git >/dev/null || apt-get -o DPkg::Lock::Timeout=120 install -y git >/dev/null
mkdir -p /opt/nago
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --depth 1 origin "$BRANCH" >/dev/null 2>&1 && git -C "$SRC" reset --hard FETCH_HEAD >/dev/null 2>&1 || true
else
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$SRC" >/dev/null 2>&1
fi

# 바이너리가 이미 있고 소스가 안 바뀌었으면 빌드를 건너뛴다(FORCE_BUILD=1로 강제).
NEED_BUILD=1
if [ -x "$BIN" ] && [ -z "${FORCE_BUILD:-}" ]; then
  # 프록시에 들어가는 소스(코어·예제·엔진·Cargo 파일) 중 바이너리보다 새 파일이 하나도 없을 때만 건너뛴다.
  # (예전엔 src/nagoing 디렉터리의 mtime만 봐서 파일 내용만 바뀐 갱신을 놓칠 수 있었다)
  if [ -z "$(find "$SRC/NagoTun/src" "$SRC/NagoTun/examples" "$SRC/NagoTun/engine" \
              "$SRC/NagoTun/Cargo.toml" "$SRC/NagoTun/Cargo.lock" \
              -path "$SRC/NagoTun/engine/target" -prune -o -type f -newer "$BIN" -print -quit 2>/dev/null)" ]; then
    NEED_BUILD=0
  fi
fi
if [ "$NEED_BUILD" = "1" ]; then
  echo ">> nagoing-proxy 빌드(crates.io에서 의존 크레이트를 받는다)"
  ( cd "$SRC/NagoTun" && cargo build --release --example nagoing_proxy )
  install -m 0755 "$SRC/NagoTun/target/release/examples/nagoing_proxy" "$BIN"
else
  echo ">> 빌드 건너뜀(이미 최신). FORCE_BUILD=1로 강제 빌드"
fi

echo ">> v2 키: wg0 개인키 · TLS 인증서"
install -d -m 0750 /etc/nago
WG_KEY=$(wg show wg0 private-key 2>/dev/null || sed -n 's/^PrivateKey *= *//p' /etc/wireguard/wg0.conf | head -1)
[ -n "$WG_KEY" ] || { echo "wg0 개인키를 못 찾음(wg0가 떠 있어야 함)"; exit 1; }
( umask 077; printf '%s\n' "$WG_KEY" > /etc/nago/wg.key )
if [ ! -s /etc/nago/tls.crt ] || [ ! -s /etc/nago/tls.key ]; then
  ( umask 077; openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj "/CN=www.cloudflare.com" -keyout /etc/nago/tls.key -out /etc/nago/tls.crt 2>/dev/null )
fi

echo ">> 설정·서비스 쓰기"
cat > /etc/nago/nagoing.env <<EOF
NAGO_PSK=${PSK}
NAGO_UDP=0.0.0.0:${UDP_PORT}
NAGO_TCP=0.0.0.0:${TCP_PORT}
WG_ADDR=${WG_ADDR}
EOF
chmod 0640 /etc/nago/nagoing.env

cat > /etc/systemd/system/nagoing-proxy.service <<'EOF'
[Unit]
Description=NAGO VPN nagoing proxy (obfuscated WireGuard transport)
After=network-online.target wg-quick@wg0.service
Wants=network-online.target

[Service]
EnvironmentFile=/etc/nago/nagoing.env
# v2 키·인증서는 자격증명으로만 넘긴다(DynamicUser는 root 전용 파일을 직접 못 읽음). 프록시는 이름을
# $CREDENTIALS_DIRECTORY에서 찾는다.
LoadCredential=wg.key:/etc/nago/wg.key
LoadCredential=tls.crt:/etc/nago/tls.crt
LoadCredential=tls.key:/etc/nago/tls.key
ExecStart=/usr/local/sbin/nagoing-proxy server ${NAGO_PSK} ${NAGO_UDP} ${NAGO_TCP} ${WG_ADDR} wg.key tls.crt tls.key
Restart=always
RestartSec=2
# 특권 포트(443) 바인드만 필요. 나머지는 묶는다.
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nagoing-proxy >/dev/null 2>&1
systemctl restart nagoing-proxy

echo ">> 확인"
sleep 1
systemctl is-active nagoing-proxy && echo "nagoing-proxy v2: ON  (tls ${TCP_PORT} · udp ${UDP_PORT} → ${WG_ADDR})" || {
  echo "nagoing-proxy 시작 실패 — 로그:"; journalctl -u nagoing-proxy --no-pager -n 20; exit 1;
}
echo ">> 잊지 말기: SG에서 inbound tcp ${TCP_PORT} · udp ${UDP_PORT} 열기(위 주석 참고)"
