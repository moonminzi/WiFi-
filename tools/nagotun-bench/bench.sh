#!/bin/bash
# NagoTun 엔진 벤치(리눅스, root). 클라이언트 엔진이 얼마나 빨리, 얼마나 적은 CPU로 터널을 지나가게 하는지 잰다.
#
#   [nagoc: NagoTun 클라이언트 + iperf3] --veth-- [기본 ns: relay(지연·대역폭)] --veth-- [nagos: wireguard-go 서버 + iperf3]
#
# 한국 → AWS 리전 왕복 시간은 relay가 흉내 낸다(커널 netem 없이). 서버는 wireguard-go(실제 서버는 커널 WireGuard).
#
#   bench.sh <클라이언트 바이너리> [왕복ms=0] [대역폭Mbit=0(무제한)] [초=10] [스레드=4] [스트림=4] [대기열=0]
# 대기열: 0이면 이벤트 루프에서 바로 처리(NagoTun 기본), 1 이상이면 NepTUN처럼 작업 스레드로 넘김
# 결과: 받기/올리기 Mbit/s, 받는 중 핑(중간값·90%), 클라이언트 CPU(1GB당 CPU초) — 한 줄 JSON
set -eu
CLIENT=$(readlink -f "$1"); RTT=${2:-0}; RATE=${3:-0}; SECS=${4:-10}; THREADS=${5:-4}; STREAMS=${6:-4}; QUEUE=${7:-0}
HERE=$(cd "$(dirname "$0")" && pwd)
WG=${WG:-$HOME/go/bin/wireguard}
RELAY=$HERE/relay/relay
OUT=$(mktemp -d)
PIDS=()

cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  sleep 0.3
  ip netns del nagoc 2>/dev/null || true
  ip netns del nagos 2>/dev/null || true
  ip link del vrc 2>/dev/null || true
  ip link del vrs 2>/dev/null || true
  rm -f /var/run/wireguard/wg0.sock
}
trap cleanup EXIT
cleanup

ip netns add nagoc; ip netns add nagos
ip link add vrc type veth peer name vc netns nagoc
ip link add vrs type veth peer name vs netns nagos
ip addr add 10.201.0.1/24 dev vrc; ip link set vrc up
ip addr add 10.202.0.1/24 dev vrs; ip link set vrs up
ip -n nagoc addr add 10.201.0.2/24 dev vc; ip -n nagoc link set vc up; ip -n nagoc link set lo up
ip -n nagos addr add 10.202.0.2/24 dev vs; ip -n nagos link set vs up; ip -n nagos link set lo up
# 소켓 버퍼 상한은 네임스페이스마다가 아니라 커널 전체 값이다(안 되면 그대로 둔다)
sysctl -qw net.core.rmem_max=67108864 net.core.wmem_max=67108864 2>/dev/null || true
for ns in nagoc nagos; do
  ip netns exec $ns sysctl -qw net.ipv4.tcp_rmem="4096 131072 67108864" net.ipv4.tcp_wmem="4096 65536 67108864" 2>/dev/null || true
done

SKEY=$(wg genkey); SPUB=$(echo "$SKEY" | wg pubkey)
CKEY=$(wg genkey); CPUB=$(echo "$CKEY" | wg pubkey)

# 서버(wireguard-go)
${OTHER_CPUS:+taskset -c $OTHER_CPUS} ip netns exec nagos "$WG" -f wg0 >"$OUT/wg.log" 2>&1 & PIDS+=($!)
for _ in $(seq 50); do [ -S /var/run/wireguard/wg0.sock ] && break; sleep 0.1; done
ip netns exec nagos wg set wg0 private-key <(echo "$SKEY") listen-port 51820 peer "$CPUB" allowed-ips 10.9.0.2/32
ip -n nagos addr add 10.9.0.1/24 dev wg0; ip -n nagos link set wg0 mtu 1420 up

# 중계(한쪽 지연 = 왕복/2)
${OTHER_CPUS:+taskset -c $OTHER_CPUS} "$RELAY" -listen 10.201.0.1:51820 -upstream 10.202.0.2:51820 -delay "$((RTT / 2))ms" -rate "$RATE" >"$OUT/relay.log" 2>&1 & PIDS+=($!)

# 클라이언트(NagoTun)
# CLIENT_CPUS=0,1 이면 엔진을 그 코어에만 묶는다(폰의 큰 코어 두 개처럼). 나머지(서버·중계·iperf3)는 OTHER_CPUS
${CLIENT_CPUS:+taskset -c $CLIENT_CPUS} ip netns exec nagoc "$CLIENT" tnago 10.9.0.2 "$CKEY" "$SPUB" 10.201.0.1:51820 "$THREADS" 1420 "$QUEUE" >"$OUT/client.log" 2>&1 & CPID=$!; PIDS+=($CPID)
sleep 1.5
ip netns exec nagoc ping -c 2 -W 3 10.9.0.1 >/dev/null || { echo '{"error":"tunnel down"}'; cat "$OUT"/*.log >&2; exit 1; }
${OTHER_CPUS:+taskset -c $OTHER_CPUS} ip netns exec nagos iperf3 -s -B 10.9.0.1 >/dev/null 2>&1 & PIDS+=($!)
sleep 0.5

# 클라이언트 엔진 프로세스의 CPU 시간(초): /proc/<pid>/stat utime+stime
ENGINE=$(pgrep -f "$(basename "$CLIENT") tnago" | head -1)
cpu() { awk '{print ($14+$15)/100}' "/proc/$ENGINE/stat"; }

run() {  # 이름, iperf3 추가 인자
  local name=$1; shift
  local c0; c0=$(cpu)
  ip netns exec nagoc ping -i 0.2 -w "$SECS" 10.9.0.1 >"$OUT/ping-$name.txt" 2>&1 &
  local pp=$!
  local sp=
  # STRACE=1이면 엔진의 시스템 호출 수를 센다(CPU 숫자는 strace 때문에 부풀어서 같이 보지 않는다)
  if [ "${STRACE:-}" = 1 ]; then
    (sleep 2; timeout $((SECS - 4)) strace -c -f -p "$ENGINE" -o "$OUT/strace-$name.txt" 2>/dev/null) &
    sp=$!
  fi
  ${OTHER_CPUS:+taskset -c $OTHER_CPUS} ip netns exec nagoc iperf3 -c 10.9.0.1 -t "$SECS" -P "$STREAMS" -J "$@" >"$OUT/$name.json"
  wait $pp || true
  if [ -n "$sp" ]; then wait $sp || true; echo "== strace $name" >&2; head -14 "$OUT/strace-$name.txt" >&2; fi
  local c1; c1=$(cpu)
  python3 - "$OUT/$name.json" "$OUT/ping-$name.txt" "$c0" "$c1" "$name" <<'PY'
import json, sys, re, statistics
d = json.load(open(sys.argv[1]))
end = d["end"]
bps = end["sum_received"]["bits_per_second"]
gb = end["sum_received"]["bytes"] / 1e9
retr = end.get("sum_sent", {}).get("retransmits")
rtts = [float(x) for x in re.findall(r"time=([\d.]+)", open(sys.argv[2]).read())]
rtts.sort()
cpu = float(sys.argv[4]) - float(sys.argv[3])
print(json.dumps({sys.argv[5]: {"mbps": round(bps / 1e6, 1), "retrans": retr,
      "ping_ms": {"p50": round(statistics.median(rtts), 1) if rtts else None,
                  "p90": round(rtts[int(len(rtts) * 0.9) - 1], 1) if rtts else None},
      "cpu_s_per_gb": round(cpu / gb, 2) if gb else None}}))
PY
}
echo "{\"rtt_ms\": $RTT, \"rate_mbit\": $RATE, \"threads\": $THREADS, \"streams\": $STREAMS, \"queue\": $QUEUE}"
run down -R
run up
grep -h "drops" "$OUT/relay.log" | tail -1 >&2 || true
grep -h "stats" "$OUT/client.log" >&2 || true
