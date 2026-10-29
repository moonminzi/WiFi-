#!/bin/bash
# nagoing 서버 프록시를 올린다(막힌 망 우회). 여러 번 실행해도 안전(idempotent).
#
# 하는 일: WG(wg0, udp 51820)는 그대로 두고, 그 앞에 nagoing 프록시를 세운다.
#   - TCP 443   : TLS 흉내(ClientHello) — 학교·회사·호텔처럼 VPN 막는 망의 핵심 경로(①)
#   - UDP 51821 : QUIC 모양 — 손실 보정(FEC)·빠른 전환이 사는 경로(②③). udp 443은 기존 WG REDIRECT가
#                 먼저 가로채므로 쓰지 않고 전용 포트를 쓴다
#   받은 걸 풀어서 로컬 wg0(127.0.0.1:51820)로 넘긴다. WireGuard는 하나도 안 바뀐다.
#
# 빌드: neptun을 안 끌어오는 --no-default-features라 외부 크레이트가 0개다(rustc만 있으면 됨, git/crates.io 불필요).
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
  if [ "$SRC/NagoTun/src/nagoing" -ot "$BIN" ] 2>/dev/null; then NEED_BUILD=0; fi
fi
if [ "$NEED_BUILD" = "1" ]; then
  echo ">> nagoing-proxy 빌드(neptun 없이, 외부 의존 0개)"
  ( cd "$SRC/NagoTun" && cargo build --release --no-default-features --example nagoing_proxy )
  install -m 0755 "$SRC/NagoTun/target/release/examples/nagoing_proxy" "$BIN"
else
  echo ">> 빌드 건너뜀(이미 최신). FORCE_BUILD=1로 강제 빌드"
fi

echo ">> 설정·서비스 쓰기"
install -d -m 0750 /etc/nago
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
ExecStart=/usr/local/sbin/nagoing-proxy server ${NAGO_PSK} ${NAGO_UDP} ${NAGO_TCP} ${WG_ADDR}
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
systemctl is-active nagoing-proxy && echo "nagoing-proxy: ON  (tcp ${TCP_PORT} · udp ${UDP_PORT} → ${WG_ADDR})" || {
  echo "nagoing-proxy 시작 실패 — 로그:"; journalctl -u nagoing-proxy --no-pager -n 20; exit 1;
}
echo ">> 잊지 말기: SG에서 inbound tcp ${TCP_PORT} · udp ${UDP_PORT} 열기(위 주석 참고)"
