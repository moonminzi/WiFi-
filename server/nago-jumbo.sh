#!/bin/bash
# NAGO VPN: 큰 터널 MTU(iOS가 Wi-Fi에서 쓰는 2880·4384) 서버 쪽. wg0.conf의 PostUp/PostDown에서 부른다.
#   nago-jumbo up   — 켬 (여러 번 불러도 같음)
#   nago-jumbo down — 끔 (wg0 MTU 1420, 규칙 제거)
#
# 무엇을 하나:
#   - wg0 장치 MTU는 9000으로 올리되, 기본 경로(10.9.0.0/24)는 MTU 1420으로 묶는다.
#     → 서버가 그냥 넘겨주는 패킷(인터넷→폰 UDP, DNS 응답 등)은 지금처럼 1420에서 나뉜다.
#       예전 앱(엔진 버퍼 1550)과 셀룰러 폰이 그대로 동작한다.
#   - wg0에서 들어온 TCP에 표시(fwmark 0x51)를 하고, tcp_fwmark_accept로 그 표시가 받아들인 소켓
#     (TCP 분할 가속 haproxy 쪽 연결)에 이어지게 한다. 표시된 소켓만 표 51의 MTU 8960 경로를 쓴다.
#     → 폰이 SYN에서 큰 MSS(2840 등)를 알리면 서버도 큰 세그먼트를 보낸다. 예전 앱은 MSS 1380을 알리니 그대로.
#   - 바깥 UDP는 커널 WireGuard가 DF 없이 보내서 IP 조각으로 나뉜다(폰 커널이 다시 합친다).
set -u
MARK=0x51
TABLE=51
NET=10.9.0.0/24
SRC=10.9.0.1

ipt() { iptables -t mangle "$@" -i wg0 -p tcp -j MARK --set-mark $MARK; }

case "${1:-}" in
up)
  ip route replace $NET dev wg0 proto kernel scope link src $SRC mtu 1420
  ip route replace $NET dev wg0 src $SRC mtu 8960 table $TABLE
  ip link set wg0 mtu 9000
  ip rule show | grep -q "fwmark $MARK lookup $TABLE" || ip rule add fwmark $MARK lookup $TABLE pref 1051
  ipt -C PREROUTING 2>/dev/null || ipt -A PREROUTING
  sysctl -q -w net.ipv4.tcp_fwmark_accept=1
  ;;
down)
  while ipt -C PREROUTING 2>/dev/null; do ipt -D PREROUTING; done
  while ip rule show | grep -q "fwmark $MARK lookup $TABLE"; do ip rule del fwmark $MARK lookup $TABLE; done
  ip route flush table $TABLE 2>/dev/null
  if ip link show wg0 >/dev/null 2>&1; then
    ip link set wg0 mtu 1420
    ip route replace $NET dev wg0 proto kernel scope link src $SRC
  fi
  sysctl -q -w net.ipv4.tcp_fwmark_accept=0
  ;;
*)
  echo "usage: $0 up|down" >&2
  exit 2
  ;;
esac
