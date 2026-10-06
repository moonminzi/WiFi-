#!/usr/bin/env bash
#
# NAGO VPN - 국가 선택용 해외 IKEv2 서버(strongSwan) 구축 스크립트
# 대상: Ubuntu 22.04 (arm64/amd64). root로 실행하세요.
#
# 서울 서버(setup-strongswan.sh)와 다른 점
#   - 서버 ID가 공인 IP가 아니라 FQDN(예: jp.nago.vpn). 인스턴스를 껐다 켜서 IP가 바뀌어도
#     인증서를 다시 만들 필요가 없다. 앱은 API로 현재 IP를 받아 접속하고 ID로 인증서를 검증한다.
#   - 인증서/비밀번호는 만들지 않고 번들 디렉터리에서 가져온다(기존 CA로 미리 서명해 둔 것).
#   - 처음부터 MTU 1500, BBR, TCP 분할 가속(haproxy)을 켠다.
#
# 번들 디렉터리 내용: ca-cert.pem server-cert.pem server-key.pem ipsec.secrets id
#
# 사용법: sudo ./setup-region.sh /path/to/bundle
#
set -euo pipefail

B="${1:?번들 디렉터리를 지정하세요}"
ID="$(cat "$B/id")"
POOL="10.10.10.0/24"
export DEBIAN_FRONTEND=noninteractive

echo ">> 패키지 설치"
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
for i in $(seq 1 30); do
    apt-get -o DPkg::Lock::Timeout=120 update -y && \
    apt-get -o DPkg::Lock::Timeout=120 install -y strongswan libcharon-extra-plugins \
        libcharon-extauth-plugins libstrongswan-extra-plugins iptables-persistent haproxy && break
    sleep 10
done

echo ">> 인증서 설치 (ID=${ID})"
install -d -m 755 /etc/ipsec.d/cacerts /etc/ipsec.d/certs
install -d -m 700 /etc/ipsec.d/private
install -m 644 "$B/ca-cert.pem" /etc/ipsec.d/cacerts/ca-cert.pem
install -m 644 "$B/server-cert.pem" /etc/ipsec.d/certs/server-cert.pem
install -m 600 "$B/server-key.pem" /etc/ipsec.d/private/server-key.pem
install -m 600 "$B/ipsec.secrets" /etc/ipsec.secrets
openssl verify -CAfile /etc/ipsec.d/cacerts/ca-cert.pem /etc/ipsec.d/certs/server-cert.pem
[ "$(openssl x509 -noout -modulus -in /etc/ipsec.d/certs/server-cert.pem | md5sum)" = \
  "$(openssl rsa -noout -modulus -in /etc/ipsec.d/private/server-key.pem | md5sum)" ] \
  || { echo "인증서와 키가 맞지 않음"; exit 1; }

echo ">> /etc/ipsec.conf 작성"
cat > /etc/ipsec.conf <<EOF
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=never

conn ikev2-vpn
    auto=add
    compress=no
    type=tunnel
    keyexchange=ikev2
    fragmentation=yes
    forceencaps=yes
    dpdaction=clear
    dpddelay=300s
    rekey=no
    left=%any
    leftid=@${ID}
    leftcert=server-cert.pem
    leftsendcert=always
    leftsubnet=0.0.0.0/0
    right=%any
    rightid=%any
    rightauth=eap-mschapv2
    rightsourceip=${POOL}
    rightdns=1.1.1.1,8.8.8.8
    rightsendcert=never
    eap_identity=%identity
    ike=aes256gcm16-prfsha256-ecp256,aes256-sha256-modp2048,aes256-sha256-ecp256,aes128-sha256-modp2048
    esp=aes256gcm16-ecp256,aes256gcm16,aes256-sha256,aes128-sha256
EOF

echo ">> 커널 설정 (포워딩, BBR, 원거리용 TCP 버퍼)"
echo tcp_bbr > /etc/modules-load.d/bbr.conf
modprobe tcp_bbr || true
modprobe nf_conntrack || true
cat > /etc/sysctl.d/99-nago.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fastopen=3
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 131072 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.netfilter.nf_conntrack_max=262144
EOF
sysctl -q -p /etc/sysctl.d/99-nago.conf

DEFIF=$(ip route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')

echo ">> ${DEFIF} MTU 1500 (AWS 점보 프레임 9001이면 ESP 바깥 패킷이 인터넷 1500을 넘음)"
cat > /etc/netplan/60-nago-mtu.yaml <<EOF
network:
  version: 2
  ethernets:
    ${DEFIF}:
      mtu: 1500
      dhcp4-overrides:
        use-mtu: false
EOF
chmod 600 /etc/netplan/60-nago-mtu.yaml
netplan apply || true
sleep 3
if ! curl -fsS -o /dev/null --max-time 10 https://www.cloudflare.com; then
    echo "MTU 변경 후 인터넷 안 됨 → 되돌림"
    rm -f /etc/netplan/60-nago-mtu.yaml
    netplan apply || true
    sleep 3
fi
ip link show "$DEFIF" | grep -o 'mtu [0-9]*'

echo ">> NAT/포워딩"
iptables -t nat -C POSTROUTING -s "$POOL" -o "$DEFIF" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$POOL" -o "$DEFIF" -j MASQUERADE
iptables -C FORWARD -s "$POOL" -j ACCEPT 2>/dev/null || iptables -A FORWARD -s "$POOL" -j ACCEPT
iptables -C FORWARD -d "$POOL" -j ACCEPT 2>/dev/null || iptables -A FORWARD -d "$POOL" -j ACCEPT
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
# 가속 규칙이 들어가기 전에 저장해 둔다(가속은 haproxy와 함께 켜지고 꺼진다)
netfilter-persistent save

echo ">> TCP 분할 가속 (haproxy 투명 프록시, VPN 사용자 TCP만)"
cat > /etc/haproxy/haproxy.cfg <<'CFG'
global
    log /dev/log local0 warning
    chroot /var/lib/haproxy
    user haproxy
    group haproxy
    maxconn 40000
    stats socket /run/haproxy/admin.sock mode 660 level admin

defaults
    log global
    mode tcp
    option dontlognull
    option splice-auto
    timeout connect 8s
    timeout client 6h
    timeout server 6h
    timeout client-fin 30s
    timeout server-fin 30s

frontend nago_split
    bind :12345
    default_backend nago_orig

backend nago_orig
    server orig 0.0.0.0
CFG
haproxy -c -f /etc/haproxy/haproxy.cfg

cat > /usr/local/sbin/nago-accel <<'SH'
#!/bin/bash
# NAGO VPN TCP 분할 가속 on|off|status (IKEv2 사용자 TCP만, 사설망 제외)
IKE_MATCH="-s 10.10.10.0/24 -p tcp -m policy --dir in --pol ipsec"
case "$1" in
on)
  iptables -t nat -N NAGO_ACCEL 2>/dev/null; iptables -t nat -F NAGO_ACCEL
  for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16 100.64.0.0/10; do
    iptables -t nat -A NAGO_ACCEL -d $n -j RETURN
  done
  iptables -t nat -A NAGO_ACCEL -p tcp -j REDIRECT --to-ports 12345
  iptables -t nat -C PREROUTING $IKE_MATCH -j NAGO_ACCEL 2>/dev/null || iptables -t nat -I PREROUTING $IKE_MATCH -j NAGO_ACCEL ;;
off)
  iptables -t nat -D PREROUTING $IKE_MATCH -j NAGO_ACCEL 2>/dev/null
  iptables -t nat -F NAGO_ACCEL 2>/dev/null; iptables -t nat -X NAGO_ACCEL 2>/dev/null ;;
status)
  iptables -t nat -C PREROUTING $IKE_MATCH -j NAGO_ACCEL 2>/dev/null && echo "accel: ON" || echo "accel: OFF"
  echo "haproxy: $(systemctl is-active haproxy)" ;;
*) echo "usage: nago-accel on|off|status" ;;
esac
SH
chmod +x /usr/local/sbin/nago-accel

cat > /etc/systemd/system/nago-accel.service <<'UNIT'
[Unit]
Description=NAGO VPN TCP split acceleration (turns off if haproxy stops)
After=haproxy.service strongswan-starter.service
BindsTo=haproxy.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nago-accel on
ExecStop=/usr/local/sbin/nago-accel off
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target haproxy.service
UNIT
systemctl daemon-reload
systemctl enable haproxy nago-accel
systemctl restart haproxy
systemctl restart nago-accel

echo ">> 유휴 자동 중지 (기본 30분 동안 분당 송신 300KB 미만이면 스스로 꺼짐 → EC2 '중지')"
cat > /usr/local/sbin/nago-idle <<'SH'
#!/bin/bash
# 매분 실행. VPN 사용자가 거의 안 쓰면(분당 송신량 < NAGO_IDLE_BYTES) 카운트를 올리고,
# NAGO_IDLE_MIN분 연속이면 poweroff 한다. 카운터는 /run(tmpfs)에 있어서 부팅할 때마다 0부터.
LIMIT_MIN=${NAGO_IDLE_MIN:-30}
THRESH=${NAGO_IDLE_BYTES:-300000}
DEV=$(ip route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
S=/run/nago-idle; mkdir -p "$S"
tx=$(cat "/sys/class/net/$DEV/statistics/tx_bytes")
last=$(cat "$S/tx" 2>/dev/null || echo "$tx")
echo "$tx" > "$S/tx"
idle=$(cat "$S/idle" 2>/dev/null || echo 0)
if [ $((tx - last)) -lt "$THRESH" ]; then idle=$((idle + 1)); else idle=0; fi
echo "$idle" > "$S/idle"
if [ "$idle" -ge "$LIMIT_MIN" ]; then
    logger -t nago-idle "idle ${idle}m -> poweroff"
    systemctl poweroff
fi
SH
chmod +x /usr/local/sbin/nago-idle
cat > /etc/systemd/system/nago-idle.service <<'UNIT'
[Unit]
Description=NAGO VPN idle check (poweroff when unused)
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nago-idle
UNIT
cat > /etc/systemd/system/nago-idle.timer <<'UNIT'
[Unit]
Description=NAGO VPN idle check every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now nago-idle.timer

echo ">> strongSwan 기동"
systemctl enable strongswan-starter
systemctl restart strongswan-starter
sleep 3
ipsec statusall | sed -n '1,25p' || true
/usr/local/sbin/nago-accel status
echo "NAGO_REGION_READY id=${ID}"
