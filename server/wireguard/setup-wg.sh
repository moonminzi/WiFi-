#!/bin/bash
# 해외 서버(jp/us/uk)에 WireGuard(wg0)를 올린다. 여러 번 실행해도 안전.
#
# - 서울과 같은 대역 10.9.0.0/24(서버 10.9.0.1), 포트 udp 51820 + udp 443(→51820, 잘 안 막히는 포트)
# - 서버 키는 서버마다 따로 만든다(개인키는 서버 밖으로 안 나감). 공개키는 마지막 줄에 출력
# - 피어 목록은 여기서 넣지 않는다. Lambda가 SSM 파라미터 /nago/wg/peers를 nago-peer sync로 맞춘다
# - TCP 분할 가속(nago-accel)에 wg0 사용자도 포함
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo ">> wireguard-tools 설치"
command -v wg >/dev/null || apt-get -o DPkg::Lock::Timeout=120 install -y wireguard-tools >/dev/null \
  || { apt-get -o DPkg::Lock::Timeout=120 update -y >/dev/null; apt-get -o DPkg::Lock::Timeout=120 install -y wireguard-tools >/dev/null; }

DEFIF=$(ip route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')

if [ ! -f /etc/wireguard/wg0.conf ]; then
  echo ">> wg0.conf 만들기(새 서버 키)"
  umask 077
  KEY=$(wg genkey)
  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.9.0.1/24
ListenPort = 51820
MTU = 1420
PrivateKey = ${KEY}
PostUp = iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o ${DEFIF} -j MASQUERADE; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s 10.9.0.0/24 -o ${DEFIF} -j MASQUERADE; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT
EOF
  umask 022
fi

echo ">> TCP 분할 가속에 wg0 포함"
cat > /usr/local/sbin/nago-accel <<'SH'
#!/bin/bash
# NAGO VPN TCP 분할 가속 on|off|status  (WireGuard wg0 + IKEv2 10.10.10.0/24 사용자 TCP만, 사설망 제외)
# 프록시 포트(12345)는 REDIRECT로 들어온 연결만 받는다(직접 접속하면 자기 자신에게 무한 연결됨).
GUARD="INPUT -p tcp --dport 12345 -m conntrack ! --ctstate DNAT -j DROP"
IKE_MATCH="-s 10.10.10.0/24 -p tcp -m policy --dir in --pol ipsec"
WG_MATCH="-i wg0 -p tcp"
case "$1" in
on)
  iptables -t nat -N NAGO_ACCEL 2>/dev/null; iptables -t nat -F NAGO_ACCEL
  for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16 100.64.0.0/10; do
    iptables -t nat -A NAGO_ACCEL -d $n -j RETURN
  done
  iptables -t nat -A NAGO_ACCEL -p tcp -j REDIRECT --to-ports 12345
  iptables -C $GUARD 2>/dev/null || iptables -I $GUARD
  iptables -t nat -C PREROUTING $IKE_MATCH -j NAGO_ACCEL 2>/dev/null || iptables -t nat -I PREROUTING $IKE_MATCH -j NAGO_ACCEL
  iptables -t nat -C PREROUTING $WG_MATCH -j NAGO_ACCEL 2>/dev/null || iptables -t nat -I PREROUTING $WG_MATCH -j NAGO_ACCEL ;;
off)
  iptables -t nat -D PREROUTING $IKE_MATCH -j NAGO_ACCEL 2>/dev/null
  iptables -t nat -D PREROUTING $WG_MATCH -j NAGO_ACCEL 2>/dev/null
  iptables -D $GUARD 2>/dev/null
  iptables -t nat -F NAGO_ACCEL 2>/dev/null; iptables -t nat -X NAGO_ACCEL 2>/dev/null ;;
status)
  iptables -t nat -C PREROUTING $IKE_MATCH -j NAGO_ACCEL 2>/dev/null && echo "accel ike: ON" || echo "accel ike: OFF"
  iptables -t nat -C PREROUTING $WG_MATCH -j NAGO_ACCEL 2>/dev/null && echo "accel wg0: ON" || echo "accel wg0: OFF"
  echo "haproxy: $(systemctl is-active haproxy)" ;;
*) echo "usage: nago-accel on|off|status" ;;
esac
SH
chmod +x /usr/local/sbin/nago-accel

echo ">> udp 443 → 51820, 규칙 저장(wg0/가속 규칙은 빼고 저장: 부팅 때 각자 다시 넣음)"
systemctl stop wg-quick@wg0 2>/dev/null || true
/usr/local/sbin/nago-accel off
iptables -t nat -C PREROUTING -i "$DEFIF" -p udp --dport 443 -j REDIRECT --to-ports 51820 2>/dev/null \
  || iptables -t nat -A PREROUTING -i "$DEFIF" -p udp --dport 443 -j REDIRECT --to-ports 51820
netfilter-persistent save >/dev/null 2>&1 || true
systemctl enable wg-quick@wg0 >/dev/null 2>&1
systemctl start wg-quick@wg0
/usr/local/sbin/nago-accel on

echo ">> 확인"
systemctl is-active wg-quick@wg0
/usr/local/sbin/nago-accel status
ip -brief addr show wg0
echo "WGPUB $(wg show wg0 public-key)"
