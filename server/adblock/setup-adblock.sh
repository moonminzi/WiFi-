#!/bin/bash
# NAGO VPN 광고·추적 차단 DNS. 모든 서버(kr/jp/us/uk)에서 한 번 실행하면 된다(여러 번 실행해도 안전).
#
# - dnsmasq가 VPN 안쪽 전용 주소 10.53.53.53에서만 응답한다(공인 IP로는 안 열림)
# - 차단 목록: OISD big + YousList(한국 광고). 매일 새로 받고, 받은 게 이상하면 이전 목록 유지
# - IKEv2에서 IKE ID가 adblock.nago인 연결에만 이 DNS를 준다(앱의 --adblock 스위치).
#   보통 연결(ID = 사용자 이름)과 WireGuard는 그대로 1.1.1.1
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
DNS_IP=10.53.53.53

echo ">> dnsmasq 설치(바이너리만, 시스템 서비스 없이)"
command -v dnsmasq >/dev/null || apt-get -o DPkg::Lock::Timeout=120 install -y dnsmasq-base >/dev/null \
  || { apt-get -o DPkg::Lock::Timeout=120 update -y >/dev/null; apt-get -o DPkg::Lock::Timeout=120 install -y dnsmasq-base >/dev/null; }

mkdir -p /etc/nago-dns /var/lib/nago-dns
touch /var/lib/nago-dns/block.conf
[ -f /etc/nago-dns/allow.conf ] || cat > /etc/nago-dns/allow.conf <<'EOF'
# 잘못 막힌 사이트를 풀 때: server=/도메인/1.1.1.1  (하위 도메인 포함) 후 systemctl restart nago-dns
EOF
cat > /etc/nago-dns/dnsmasq.conf <<EOF
bind-interfaces
listen-address=${DNS_IP}
no-resolv
no-hosts
no-poll
domain-needed
bogus-priv
server=1.1.1.1
server=8.8.8.8
cache-size=10000
conf-file=/var/lib/nago-dns/block.conf
conf-file=/etc/nago-dns/allow.conf
EOF

cat > /usr/local/sbin/nago-dns-update <<'SH'
#!/bin/bash
# 차단 목록을 새로 받아 dnsmasq 형식(local=/도메인/)으로 만든다. 실패하면 이전 목록을 그대로 둔다.
set -u
D=/var/lib/nago-dns
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
: > "$T/all"
curl -fsSL --max-time 90 https://big.oisd.nl/dnsmasq2 -o "$T/oisd" \
  && grep -E '^local=/[A-Za-z0-9._-]+/$' "$T/oisd" >> "$T/all"
curl -fsSL --max-time 30 https://raw.githubusercontent.com/yous/YousList/master/hosts.txt -o "$T/yous" \
  && awk '($1=="0.0.0.0"||$1=="127.0.0.1") && $2 ~ /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$/ {print "local=/"$2"/"}' "$T/yous" >> "$T/all"
sort -u "$T/all" > "$T/block.conf"
n=$(wc -l < "$T/block.conf")
if [ "$n" -lt 10000 ]; then
  logger -t nago-dns "update: only $n domains, keeping the old list"; exit 1
fi
cp "$D/block.conf" "$T/old.conf"
install -m 644 "$T/block.conf" "$D/block.conf"
if ! dnsmasq --test -C /etc/nago-dns/dnsmasq.conf >/dev/null 2>&1; then
  install -m 644 "$T/old.conf" "$D/block.conf"
  logger -t nago-dns "update: config test failed, restored the old list"; exit 1
fi
echo "$n" > "$D/count"
systemctl restart nago-dns
logger -t nago-dns "update: $n domains"
SH
chmod 755 /usr/local/sbin/nago-dns-update

cat > /etc/systemd/system/nago-dns.service <<EOF
[Unit]
Description=NAGO VPN ad-blocking DNS (${DNS_IP}, VPN clients only)
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=-/usr/sbin/ip link add nago-dns type dummy
ExecStartPre=-/usr/sbin/ip addr add ${DNS_IP}/32 dev nago-dns
ExecStartPre=/usr/sbin/ip link set nago-dns up
ExecStart=/usr/sbin/dnsmasq -k -C /etc/nago-dns/dnsmasq.conf --pid-file=/run/nago-dns.pid
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/nago-dns-update.service <<'EOF'
[Unit]
Description=NAGO VPN ad-blocking list update
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nago-dns-update
EOF
cat > /etc/systemd/system/nago-dns-update.timer <<'EOF'
[Unit]
Description=NAGO VPN ad-blocking list update (daily)
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now nago-dns.service nago-dns-update.timer
echo ">> 차단 목록 받기"
/usr/local/sbin/nago-dns-update || true
echo "domains: $(cat /var/lib/nago-dns/count 2>/dev/null || echo 0)"

echo ">> strongSwan: adblock.nago 연결 추가"
if ! grep -q '^conn ikev2-adblock' /etc/ipsec.conf; then
  cat >> /etc/ipsec.conf <<EOF

# 앱의 --adblock: IKE ID가 adblock.nago면 이 연결이 골라지고 광고 차단 DNS를 받는다.
# 비밀번호 확인용 EAP 아이디는 따로 물어서(사용자 이름) 기존 비밀번호로 인증한다.
conn ikev2-adblock
    also=ikev2-vpn
    rightid=@adblock.nago
    rightdns=${DNS_IP}
    eap_identity=%any
EOF
fi
# 클라이언트가 EAP 아이디로 adblock.nago를 보내는 경우까지 같은 비밀번호로 받는다
if ! grep -q '^adblock.nago : EAP ' /etc/ipsec.secrets; then
  grep -m1 ' : EAP ' /etc/ipsec.secrets | sed 's/^[^ ]* : EAP /adblock.nago : EAP /' >> /etc/ipsec.secrets
fi
ipsec reload >/dev/null
ipsec rereadsecrets
sleep 1
ipsec statusall | grep -E '^ +ikev2-(vpn|adblock):' | head -4 || true

echo ">> 확인"
systemctl is-active nago-dns
dig +short +time=2 @${DNS_IP} doubleclick.net A | head -2; echo "(doubleclick.net 위가 비어 있으면 차단됨)"
dig +short +time=2 @${DNS_IP} www.naver.com A | head -2
