#!/bin/bash
# nago-agent(VPN 안쪽 10.53.53.53:8053): 광고 차단 통계 · 실시간 도메인 · 친구 집 출구. 여러 번 실행해도 안전.
# 광고 차단 DNS(setup-adblock.sh)가 먼저 깔려 있어야 한다(같은 10.53.53.53 주소를 쓴다).
#
# - dnsmasq 질의 기록을 /run/nago-dns/queries.log(tmpfs)로만 쓴다 — 디스크·journald에 안 남고, 에이전트가 읽고 비운다
# - 에이전트는 사람별 숫자를 메모리에만 들고 있다(재시작하면 오늘 숫자도 0부터). 저장하는 건 집 출구 설정뿐
# - 사용: sudo bash setup-agent.sh   (같은 폴더의 nago-agent.py를 깐다)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CONF=/etc/nago-dns/dnsmasq.conf
[ -f "$CONF" ] || { echo "nago-dns가 없다 — setup-adblock.sh 먼저" >&2; exit 1; }

echo ">> dnsmasq 질의 기록(tmpfs)"
grep -q '^log-queries' "$CONF" || cat >> "$CONF" <<'EOF'
# nago-agent: 질의 기록은 tmpfs에만(에이전트가 읽고 비움). 사람별 숫자는 에이전트 메모리에만
log-queries=extra
log-async=50
log-facility=/run/nago-dns/queries.log
EOF
mkdir -p /etc/systemd/system/nago-dns.service.d
cat > /etc/systemd/system/nago-dns.service.d/agent.conf <<'EOF'
[Service]
ExecStartPre=/bin/mkdir -p /run/nago-dns
ExecStartPre=/bin/chown nobody:nogroup /run/nago-dns
EOF

echo ">> nago-agent"
install -m 0755 "$HERE/nago-agent.py" /usr/local/sbin/nago-agent
mkdir -p /var/lib/nago-agent
cat > /etc/systemd/system/nago-agent.service <<'EOF'
[Unit]
Description=NAGO VPN agent (10.53.53.53:8053, VPN clients only: dns stats, live domains, home exits)
After=nago-dns.service wg-quick@wg0.service network-online.target
Wants=nago-dns.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/sbin/nago-agent
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
dnsmasq --test -C "$CONF" >/dev/null
systemctl restart nago-dns
systemctl enable nago-agent >/dev/null 2>&1
systemctl restart nago-agent
sleep 2
echo "nago-dns: $(systemctl is-active nago-dns) · nago-agent: $(systemctl is-active nago-agent)"
curl -s --max-time 3 http://10.53.53.53:8053/v1/me || true
echo
