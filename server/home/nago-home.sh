#!/bin/bash
# NAGO VPN 집 출구(home exit) 노드 — 친구 집 리눅스 PC·라즈베리파이를 VPN 출구로 쓴다. 여러 번 실행해도 안전.
#
#   sudo NAGO_KEY='VPN 비밀번호' bash nago-home.sh minji-pc        # 켜기(이름은 앱에 "home · minji-pc"로 보임)
#   sudo bash nago-home.sh --off                                   # 끄기(출구에서 내리고 터널을 멈춤)
#
# 어떻게 도나:
# - 이 PC가 서울(kr) 서버의 WireGuard 피어로 붙는다(폰과 같은 등록 API, 키는 이 PC에서 만들어 /etc/nago-home에).
#   집 공유기에서 포트를 열 필요가 없다(이 PC가 먼저 나가서 붙고 25초마다 신호를 보낸다)
# - 앱에서 "home · 이름"을 고른 사람의 트래픽만 서버가 wg 안쪽 IP-in-IP(nagoh)로 넘기고, 이 PC가 NAT해서
#   집 회선으로 내보낸다 → 그 사람은 이 집 IP로 보인다(데이터센터 IP를 막는 사이트용)
# - 안전장치: VPN 쪽에서 들어온 트래픽은 이 집의 내부망(192.168.x 등)·이 PC 자체로는 못 간다. 인터넷으로만
# - 필요: 리눅스(커널 WireGuard·ipip), wireguard-tools, iptables, curl, python3. 데비안·우분투·라즈베리파이 OS에서 apt로 깐다
set -euo pipefail
DASH="https://d6hphd5k56.execute-api.ap-northeast-2.amazonaws.com/?format=json"
AGENT="http://10.53.53.53:8053"
DIR=/etc/nago-home
IF=nagohome
TUN=nagoh
SERVER_IN=10.9.0.1
[ "$(id -u)" = 0 ] || { echo "sudo로 실행하세요" >&2; exit 1; }

if [ "${1:-}" = "--off" ]; then
  curl -fsS --max-time 5 -X POST "$AGENT/v1/home" -d '{"off": true}' >/dev/null 2>&1 || true
  systemctl disable --now nago-home-announce.timer wg-quick@$IF 2>/dev/null || true
  echo "집 출구를 내렸다(키는 $DIR에 남김 — 다시 켜면 같은 주소)"
  exit 0
fi

NAME="${1:-$(hostname -s)}"
NAME=$(printf '%s' "$NAME" | tr -cd 'A-Za-z0-9._ -' | cut -c1-24)
# 관리자가 피어를 따로 넣어 둔 경우: NAGO_IP · NAGO_SERVER_PUB · NAGO_ENDPOINT를 주면 등록(비밀번호)을 건너뛴다
[ -n "${NAGO_IP:-}" ] || : "${NAGO_KEY:?NAGO_KEY=VPN 비밀번호 를 앞에 붙여 실행하세요}"

echo ">> 필요한 것 설치"
need=""
for c in wg iptables curl python3; do command -v $c >/dev/null || need="$need $c"; done
if [ -n "$need" ]; then
  apt-get update -qq && apt-get install -y -qq wireguard-tools iptables curl python3 >/dev/null
fi
modprobe wireguard 2>/dev/null || true
modprobe ipip

echo ">> 키(처음이면 만듦)"
mkdir -p $DIR && chmod 700 $DIR
[ -s $DIR/key ] || (umask 077; wg genkey > $DIR/key)
PUB=$(wg pubkey < $DIR/key)

if [ -n "${NAGO_IP:-}" ]; then
  IP=$NAGO_IP; SPUB=$NAGO_SERVER_PUB; ENDPOINT=$NAGO_ENDPOINT
else
  echo ">> 서버에 피어로 등록"
  REPLY=$(curl -fsS --max-time 20 -X POST "$DASH" -H "x-nago-key: $NAGO_KEY" -H 'content-type: application/json' \
    -d "{\"op\":\"add\",\"pub\":\"$PUB\",\"name\":\"home: $NAME\"}") || { echo "등록 실패(비밀번호?)" >&2; exit 1; }
  read -r IP SPUB ENDPOINT < <(printf '%s' "$REPLY" | python3 -c '
import json,sys; r=json.load(sys.stdin); print(r["ip"], r["serverPub"], r["endpoint"])')
fi
# 서버 쪽 포트는 udp 443도 받는다(51820이 막힌 망이 있어서 443으로)
ENDPOINT="${ENDPOINT%:*}:443"
echo "   $IP → $ENDPOINT"

DEFIF=$(ip route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')

cat > /usr/local/sbin/nago-home-up <<EOF
#!/bin/bash
# wg가 뜬 뒤: 서버와 IP-in-IP, 포워딩·NAT, 내부망 막기
set -e
ip link show $TUN >/dev/null 2>&1 || ip tunnel add $TUN mode ipip local $IP remote $SERVER_IN ttl 64
ip link set $TUN mtu 1400 up
# 서버에서 넘어온 사람들(wg 10.9.0.0/24)에게 돌아가는 길은 IP-in-IP로(서버 자신 10.9.0.1만 wg로 바로)
ip route replace 10.9.0.0/24 dev $TUN
sysctl -qw net.ipv4.ip_forward=1
sysctl -qw net.ipv4.conf.$TUN.rp_filter=0
iptables -N NAGO_HOME 2>/dev/null || iptables -F NAGO_HOME
for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10 224.0.0.0/4; do
  iptables -A NAGO_HOME -d \$n -j DROP
done
iptables -A NAGO_HOME -o $DEFIF -j ACCEPT
iptables -A NAGO_HOME -j DROP
iptables -C FORWARD -i $TUN -j NAGO_HOME 2>/dev/null || iptables -I FORWARD -i $TUN -j NAGO_HOME
iptables -C FORWARD -o $TUN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \\
  || iptables -I FORWARD -o $TUN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -C INPUT -i $TUN -j DROP 2>/dev/null || iptables -I INPUT -i $TUN -j DROP
iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -o $DEFIF -j MASQUERADE 2>/dev/null \\
  || iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o $DEFIF -j MASQUERADE
iptables -t mangle -C FORWARD -o $DEFIF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \\
  || iptables -t mangle -A FORWARD -o $DEFIF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF
cat > /usr/local/sbin/nago-home-down <<EOF
#!/bin/bash
iptables -D FORWARD -i $TUN -j NAGO_HOME 2>/dev/null
iptables -D FORWARD -o $TUN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
iptables -D INPUT -i $TUN -j DROP 2>/dev/null
iptables -t nat -D POSTROUTING -s 10.9.0.0/24 -o $DEFIF -j MASQUERADE 2>/dev/null
iptables -t mangle -D FORWARD -o $DEFIF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
iptables -F NAGO_HOME 2>/dev/null; iptables -X NAGO_HOME 2>/dev/null
ip link del $TUN 2>/dev/null
exit 0
EOF
cat > /usr/local/sbin/nago-home-announce <<EOF
#!/bin/bash
# 서버 에이전트에 "나는 출구 $NAME"이라고 알린다(서버가 재부팅돼도 5분 안에 다시 잡힌다)
curl -fsS --max-time 8 -X POST $AGENT/v1/home -H 'content-type: application/json' -d '{"name": "$NAME"}'
EOF
chmod 755 /usr/local/sbin/nago-home-up /usr/local/sbin/nago-home-down /usr/local/sbin/nago-home-announce

echo ">> WireGuard($IF)"
umask 077
cat > /etc/wireguard/$IF.conf <<EOF
[Interface]
PrivateKey = $(cat $DIR/key)
Address = $IP/32
MTU = 1420
PostUp = /usr/local/sbin/nago-home-up
PostDown = /usr/local/sbin/nago-home-down

[Peer]
PublicKey = $SPUB
Endpoint = $ENDPOINT
# 서버 자신과 서버의 에이전트만 wg로 바로. 사람들 트래픽은 IP-in-IP(nagoh)로 오간다
AllowedIPs = $SERVER_IN/32, 10.53.53.53/32
PersistentKeepalive = 25
EOF
umask 022

cat > /etc/systemd/system/nago-home-announce.service <<'EOF'
[Unit]
Description=NAGO VPN home exit: announce to the server
After=wg-quick@nagohome.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nago-home-announce
EOF
cat > /etc/systemd/system/nago-home-announce.timer <<'EOF'
[Unit]
Description=NAGO VPN home exit: announce every 5 minutes
[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable wg-quick@$IF >/dev/null 2>&1
systemctl restart wg-quick@$IF
systemctl enable --now nago-home-announce.timer >/dev/null 2>&1

echo ">> 서버에 출구로 알리기"
for i in 1 2 3 4 5 6; do
  if OUT=$(/usr/local/sbin/nago-home-announce 2>/dev/null); then echo "   $OUT"; break; fi
  sleep 3
done
wg show $IF | grep -E "endpoint|handshake|transfer" || true
echo "완료: 앱에서 kr에 wg로 연결 → exit via → home · $NAME"
