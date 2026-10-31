#!/bin/bash
# nago-agent(VPN 안쪽 10.53.53.53): 사람별 광고 차단 DNS(강도 · 내 규칙) · 통계 · 실시간 도메인 · 친구 집 출구.
# 광고 차단 DNS(setup-adblock.sh)가 먼저 깔려 있어야 한다(같은 10.53.53.53 주소 · nago-dns 장치를 쓴다). 여러 번 실행해도 안전.
#
# 바뀌는 구조:
#   폰 → 10.53.53.53:53 nago-agent(사람마다 강도·내 규칙으로 판단, 막으면 NXDOMAIN)
#                         └ 통과 → 127.0.0.1:5354 dnsmasq(nago-dns, 차단 목록 없는 캐시·전달) → 1.1.1.1 · 8.8.8.8
#   nago-dns-guard(20초마다): 에이전트 DNS가 1분 동안 답이 없으면 에이전트를 멈추고 예전 dnsmasq(nago-dns-fallback,
#   normal 목록, 10.53.53.53)를 띄운다 — 광고 차단 쓰는 사람의 인터넷이 멈추지 않게. 되돌리기: 이 스크립트를 다시 실행
#
# - 목록(매일): light = OISD small · normal = OISD big + YousList(한국 광고) · strict = normal + HaGeZi Pro++
# - 숫자·도메인 흐름은 에이전트 메모리에만(디스크·journald에 안 남음). 저장하는 건 집 출구와 wg 사람의 강도·규칙뿐
# - 사용: sudo bash setup-agent.sh   (같은 폴더의 nago-agent.py를 깐다)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DNS_IP=10.53.53.53
[ -f /etc/nago-dns/dnsmasq.conf ] || { echo "nago-dns가 없다 — setup-adblock.sh 먼저" >&2; exit 1; }
mkdir -p /var/lib/nago-dns /var/lib/nago-agent /etc/nago-dns
touch /var/lib/nago-dns/block.conf

echo ">> 목록 받기(light · normal · strict)"
cat > /usr/local/sbin/nago-dns-update <<'SH'
#!/bin/bash
# 차단 목록을 새로 받는다. 받은 게 이상하면(너무 적음) 그 단계는 이전 목록을 그대로 둔다.
#   normal.txt · light.txt · strict.txt(도메인 한 줄씩, nago-agent가 다시 읽음) + block.conf(dnsmasq 형식, 비상용 nago-dns-fallback)
set -u
D=/var/lib/nago-dns
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
local_of() { sed -n 's#^local=/\([A-Za-z0-9._-]*\)/$#\1#p'; }
keep() {   # keep <받은 파일> <목록 이름> <최소 줄 수>
  n=$(wc -l < "$1")
  if [ "$n" -lt "$3" ]; then logger -t nago-dns "update: $2 only $n domains, keeping the old list"; return 1; fi
  install -m 644 "$1" "$D/$2.txt"; echo "$2 $n"
}
# 받다가 끊기면(시간 초과 등) curl이 실패를 돌려준다 — 그 목록은 반쪽이니 쓰지 않는다
# OISD는 깃허브 공식 미러(sjhgvr/oisd)가 먼저 — oisd.nl은 AWS에서 아주 느릴 때가 있다(15KB/s)
get() { curl -fsSL --compressed --retry 2 --max-time "$2" -o "$3" "$1"; }
oisd() { get "https://raw.githubusercontent.com/sjhgvr/oisd/main/dnsmasq2_$1.txt" 120 "$2" \
  || get "https://$1.oisd.nl/dnsmasq2" 600 "$2"; }
big=0; yous=0
oisd big "$T/big" && big=1 || logger -t nago-dns "update: oisd big download failed"
get https://raw.githubusercontent.com/yous/YousList/master/hosts.txt 120 "$T/yous" && yous=1 \
  || logger -t nago-dns "update: youslist download failed"
# normal = OISD big + YousList. OISD가 안 받아졌으면 그대로 두고, YousList만 실패면 이전 목록이 없을 때만 OISD만으로
if [ $big = 1 ] && { [ $yous = 1 ] || [ ! -s "$D/normal.txt" ]; }; then
  { local_of < "$T/big"
    [ $yous = 1 ] && awk '($1=="0.0.0.0"||$1=="127.0.0.1") && $2 ~ /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$/ {print $2}' "$T/yous"
  } | tr 'A-Z' 'a-z' | sort -u > "$T/normal.txt"
  keep "$T/normal.txt" normal 100000 && sed 's#.*#local=/&/#' "$T/normal.txt" > "$D/block.conf" \
    && wc -l < "$T/normal.txt" > "$D/count"
fi
oisd small "$T/small" \
  && local_of < "$T/small" | tr 'A-Z' 'a-z' | sort -u > "$T/light.txt" && keep "$T/light.txt" light 20000
get https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.plus-onlydomains.txt 180 "$T/pro" \
  && grep -E '^[A-Za-z0-9_.-]+$' "$T/pro" | tr 'A-Z' 'a-z' | sort -u > "$T/strict.txt" && keep "$T/strict.txt" strict 100000
# 비상용 dnsmasq가 떠 있으면 새 목록으로(평소엔 꺼져 있다 — 에이전트는 파일이 바뀌면 스스로 다시 읽는다)
systemctl is-active -q nago-dns-fallback && systemctl restart nago-dns-fallback
logger -t nago-dns "update: $(cat "$D/count" 2>/dev/null) normal domains"
SH
chmod 755 /usr/local/sbin/nago-dns-update
/usr/local/sbin/nago-dns-update
for f in light normal strict; do
  [ -s /var/lib/nago-dns/$f.txt ] || { echo "$f 목록을 못 받았다 — 바꾸지 않고 멈춤" >&2; exit 1; }
done

echo ">> dnsmasq: 평소엔 캐시·전달만(127.0.0.1:5354), 비상용은 예전처럼 normal 목록(10.53.53.53)"
cat > /etc/nago-dns/dnsmasq.conf <<'EOF'
# nago-agent 뒤의 캐시·전달(차단은 nago-agent가 사람마다 한다)
bind-interfaces
listen-address=127.0.0.1
port=5354
no-resolv
no-hosts
no-poll
domain-needed
bogus-priv
server=1.1.1.1
server=8.8.8.8
cache-size=10000
EOF
cat > /etc/nago-dns/fallback.conf <<EOF
# 비상용(nago-dns-guard가 에이전트 DNS가 멎었을 때만 띄움): 예전 광고 차단 그대로, 모두 normal
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
[ -f /etc/nago-dns/allow.conf ] || echo "# 잘못 막힌 사이트(모두에게) 풀기: server=/도메인/1.1.1.1" > /etc/nago-dns/allow.conf
rm -f /etc/systemd/system/nago-dns.service.d/agent.conf
cat > /etc/systemd/system/nago-dns-fallback.service <<'EOF'
[Unit]
Description=NAGO VPN ad-blocking DNS fallback (old dnsmasq on 10.53.53.53, only while nago-agent is down)
Conflicts=nago-agent.service
After=nago-dns.service

[Service]
ExecStart=/usr/sbin/dnsmasq -k -C /etc/nago-dns/fallback.conf --pid-file=/run/nago-dns-fallback.pid
Restart=on-failure
EOF

echo ">> nago-agent"
install -m 0755 "$HERE/nago-agent.py" /usr/local/sbin/nago-agent
cat > /etc/systemd/system/nago-agent.service <<'EOF'
[Unit]
Description=NAGO VPN agent (10.53.53.53, VPN clients only: per-person ad-blocking dns, stats, live domains, home exits)
After=nago-dns.service wg-quick@wg0.service network-online.target
Wants=nago-dns.service
Conflicts=nago-dns-fallback.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/sbin/nago-agent
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

echo ">> nago-dns-guard(20초마다)"
cat > /usr/local/sbin/nago-dns-guard <<'SH'
#!/bin/bash
# 에이전트 DNS(10.53.53.53:53)가 3번 연달아(1분) 답이 없으면 에이전트를 멈추고 예전 dnsmasq로 넘긴다
F=/run/nago-dns-guard.fails
systemctl is-active -q nago-dns-fallback && exit 0
if python3 - <<'PY'
import socket, struct, sys
q = struct.pack(">HHHHHH", 4242, 0x0100, 1, 0, 0, 0) + b"\x0bnago-health\x07invalid\x00\x00\x01\x00\x01"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(4)
try:
    s.sendto(q, ("10.53.53.53", 53))
    s.recv(512)
except Exception:
    sys.exit(1)
PY
then
  rm -f "$F"; exit 0
fi
n=$(( $(cat "$F" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$F"
if [ "$n" -ge 3 ]; then
  logger -t nago-dns "guard: agent dns not answering for a minute → fallback dnsmasq"
  systemctl stop nago-agent; systemctl start nago-dns-fallback; rm -f "$F"
fi
SH
chmod 755 /usr/local/sbin/nago-dns-guard
cat > /etc/systemd/system/nago-dns-guard.service <<'EOF'
[Unit]
Description=NAGO VPN: switch to the fallback dnsmasq if nago-agent dns stops answering
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nago-dns-guard
EOF
cat > /etc/systemd/system/nago-dns-guard.timer <<'EOF'
[Unit]
Description=NAGO VPN dns guard (every 20 seconds)
[Timer]
OnBootSec=90s
OnUnitActiveSec=20s
AccuracySec=1s
[Install]
WantedBy=timers.target
EOF

echo ">> 바꾸기(몇 초 동안 새 도메인 조회가 안 될 수 있다)"
systemctl daemon-reload
dnsmasq --test -C /etc/nago-dns/dnsmasq.conf >/dev/null
dnsmasq --test -C /etc/nago-dns/fallback.conf >/dev/null
systemctl stop nago-dns-fallback 2>/dev/null || true
systemctl restart nago-dns
systemctl enable nago-agent >/dev/null 2>&1
systemctl restart nago-agent
systemctl enable --now nago-dns-guard.timer >/dev/null 2>&1
sleep 3
echo "nago-dns: $(systemctl is-active nago-dns) · nago-agent: $(systemctl is-active nago-agent) · guard: $(systemctl is-active nago-dns-guard.timer)"
/usr/local/sbin/nago-dns-guard && echo "dns answers"
curl -s --max-time 3 http://${DNS_IP}:8053/v1/me || true
echo
