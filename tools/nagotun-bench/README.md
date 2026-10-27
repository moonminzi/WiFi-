# nagotun-bench

NagoTun 엔진(안드로이드·리눅스 경로)을 리눅스에서 재는 벤치. 결과와 해석은 `NagoTun/engine/README.md`.

```
[nagoc: NagoTun 클라이언트 + iperf3] --veth-- [기본 ns: relay(지연·대역폭)] --veth-- [nagos: wireguard-go + iperf3]
```

준비(root, 우분투): `apt install iproute2 iperf3 iputils-ping wireguard-tools`,
`go install golang.zx2c4.com/wireguard@latest`(서버 wireguard-go → `~/go/bin/wireguard`, 경로는 `WG=`로 바꿈),
`(cd relay && go build -o relay .)`, `(cd client && cargo build --release)`.

```
CLIENT_CPUS=0,1 OTHER_CPUS=2,3 ./bench.sh client/target/release/nagotun-bench-client 130 300 10 1 4 0
#                                         왕복ms 대역폭Mbit 초 루프 스트림 대기열(0=바로 처리, 8=NepTUN 작업 스레드)
STRACE=1 ./bench.sh ...   # 엔진 시스템 호출 수(이때 CPU 숫자는 부풂)
```

- `relay/` — 왕복 시간·대역폭·병목 대기열(기본 BDP)을 흉내 내는 UDP 중계(Go). 커널에 netem이 없어도 된다
- `client/` — 리눅스 TUN을 만들어 `nago_tun_start`에 넘기는 클라이언트(안드로이드 VpnService와 같은 모양)
- 출력: 받기/올리기 Mbit/s, TCP 재전송, 받는 중 핑(중간값·90%), 엔진 프로세스의 1GB당 CPU초
