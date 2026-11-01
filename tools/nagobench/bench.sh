#!/bin/bash
# nagoing 실험실: 한 리눅스 안에 cli/srv 네트워크 네임스페이스 두 개와 netem으로 만든 "나쁜 회선"을 두고,
# 같은 조건에서 커널 WireGuard(시중 VPN 대부분이 이것)와 nagoing(WG + FEC 중계)을 iperf3로 잰다.
#   sudo bash bench.sh <nagoing_proxy 바이너리> [mode...]   (mode: wg xor rs — 기본 셋 다)
#     wg = 커널 WireGuard 그대로 · xor = nagoing 예전 FEC(XOR) · rs = nagoing Reed-Solomon(손실 따라 패리티 조절)
# 결과: /root/bench.csv (mode,rtt_ms,loss,profile,cc,mbps,retrans)
#   RUNS="40:0 150:1" 처럼 조건만 바꿔 돌릴 수 있다(rtt:loss, loss가 'ge'면 버스트 손실)
set -u
NP=${1:?nagoing_proxy path}; shift
MODES=${*:-"wg xor rs"}
RUNS=${RUNS:-"40:0 40:1 40:3 150:0 150:0.5 150:1 150:2 150:5 150:ge"}
CCS=${CCS:-"cubic bbr"}
SECS=${SECS:-15}
RATE=${RATE:-200mbit}
OUT=/root/bench.csv
D=$(mktemp -d)
cleanup() { pkill -x iperf3; pkill -x nagoing_proxy; ip netns del cli 2>/dev/null; ip netns del srv 2>/dev/null; }
trap cleanup EXIT
cleanup; sleep 0.5

modprobe tcp_bbr 2>/dev/null; modprobe wireguard 2>/dev/null
ip netns add cli; ip netns add srv
ip link add vc type veth peer name vs
ip link set vc netns cli; ip link set vs netns srv
ip -n cli addr add 192.168.100.2/24 dev vc; ip -n srv addr add 192.168.100.1/24 dev vs
for n in cli srv; do ip -n $n link set lo up; done
ip -n cli link set vc up; ip -n srv link set vs up
for n in cli srv; do ip netns exec $n sysctl -qw net.core.rmem_max=67108864 net.core.wmem_max=67108864 \
  net.ipv4.tcp_rmem="4096 131072 67108864" net.ipv4.tcp_wmem="4096 65536 67108864"; done

umask 077
wg genkey > $D/srv.key; wg pubkey < $D/srv.key > $D/srv.pub
wg genkey > $D/cli.key; wg pubkey < $D/cli.key > $D/cli.pub
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout $D/tls.key -out $D/tls.crt \
  -days 2 -subj /CN=bench >/dev/null 2>&1

ip -n srv link add wg0 type wireguard
ip netns exec srv wg set wg0 private-key $D/srv.key listen-port 51820 peer "$(cat $D/cli.pub)" allowed-ips 10.77.0.2/32
ip -n srv addr add 10.77.0.1/24 dev wg0; ip -n srv link set wg0 mtu 1420 up
start_nago() {   # start_nago <xor|rs>
  pkill -x nagoing_proxy; sleep 0.5
  ip netns exec srv env NAGO_FEC=$1 "$NP" server benchpsk 0.0.0.0:51821 0.0.0.0:8443 127.0.0.1:51820 \
    $D/srv.key $D/tls.crt $D/tls.key > $D/nago-srv-$1.log 2>&1 &
  ip netns exec cli env NAGO_FEC=$1 "$NP" client benchpsk 192.168.100.1 51821 8443 127.0.0.1:40000 udp \
    "$(cat $D/srv.pub)" $D/cli.key > $D/nago-cli-$1.log 2>&1 &
  sleep 1
}
ip netns exec srv iperf3 -s -B 10.77.0.1 -D

wgc() {   # wgc <endpoint> <mtu>
  ip -n cli link del wgc 2>/dev/null
  ip -n cli link add wgc type wireguard
  ip netns exec cli wg set wgc private-key $D/cli.key peer "$(cat $D/srv.pub)" allowed-ips 10.77.0.1/32 \
    endpoint "$1" persistent-keepalive 5
  ip -n cli addr add 10.77.0.2/24 dev wgc; ip -n cli link set wgc mtu "$2" up
  for i in $(seq 40); do ip netns exec cli ping -c1 -W1 10.77.0.1 >/dev/null 2>&1 && return 0; done
  echo "tunnel did not come up ($1)" >&2; return 1
}

netem() {   # netem <rtt_ms> <loss|ge>
  local half=$(( $1 / 2 )) lossarg
  if [ "$2" = ge ]; then
    # 버스트 손실(Gilbert-Elliott): 좋은 상태에서 1%로 나쁜 상태로, 나쁜 상태에선 30% 손실, 70%로 회복 → 평균 ~1.4%
    lossarg="loss gemodel 1% 70% 30% 0%"
  else
    lossarg="loss $2%"
  fi
  for x in "cli vc" "srv vs"; do set -- $x
    ip netns exec $1 tc qdisc del dev $2 root 2>/dev/null
    ip netns exec $1 tc qdisc add dev $2 root netem delay ${half}ms 1ms $lossarg rate $RATE limit 20000
  done
}

[ -f $OUT ] || echo "mode,rtt_ms,loss,cc,mbps,retrans" > $OUT
for mode in $MODES; do
  if [ $mode = wg ]; then wgc 192.168.100.1:51820 1420 || continue
  else start_nago $mode; wgc 127.0.0.1:40000 1380 || continue; fi
  for run in $RUNS; do
    rtt=${run%%:*}; loss=${run#*:}
    netem $rtt $loss
    for cc in $CCS; do
      sleep 1
      j=$(ip netns exec cli iperf3 -c 10.77.0.1 -R -t $SECS -O 3 -C $cc -J 2>/dev/null)
      mbps=$(echo "$j" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(round(d["end"]["sum_received"]["bits_per_second"]/1e6,1))' 2>/dev/null || echo ERR)
      re=$(echo "$j" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["end"]["sum_sent"].get("retransmits",""))' 2>/dev/null)
      echo "$mode,$rtt,$loss,$cc,$mbps,$re" | tee -a $OUT
    done
  done
done
for f in $D/nago-cli-*.log; do echo "--- $f"; tail -2 $f; done
