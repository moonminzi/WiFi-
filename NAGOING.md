# nagoing — WireGuard 아래에 끼우는 전송 층

WireGuard는 **하나도 바꾸지 않는다.** 그 아래에 작은 층(nagoing)을 하나 끼워, 평소에는 WG가 쓰던 UDP를
그대로 나르되 필요할 때 세 가지를 더 한다. 코어는 Rust(`NagoTun/`)라 iOS·안드로이드·리눅스가 같은 코드를 쓴다.

```
[폰]
  NepTUN(WG 엔진) ──WG UDP──▶ 127.0.0.1:local   ← nagoing 클라이언트 프록시
                                   │  ① 난독화(ChaCha20)   ② 인터리브 FEC
                                   ▼  자동 선택: UDP 443(QUIC 모양) → 막히면 TLS/TCP 443
                            nagoing 서버 프록시(:443) ──▶ 127.0.0.1:51820 (wg0)
[서버(AWS)]                        ③ session_id로 세션을 묶어 망이 바뀌어도 wg0 소켓은 그대로
```

NepTUN의 endpoint를 서버 대신 **로컬 포트(127.0.0.1:local)**로 돌려 주면 끝이다. WG는 자기 패킷이
로컬로 가는지 서버로 가는지 모른다. 그 패킷을 nagoing이 받아 서버로 날라 준다.

## 세 기능

### ① 막힌 망 우회 (가장 차별화)

학교·회사·호텔 와이파이는 WireGuard(UDP)를 DPI로 알아보고 끊는다. nagoing은 WG 데이터그램을 두 가지 모양으로 감싼다.

- **UDP(QUIC 모양)**: 데이터그램 첫 바이트를 QUIC short-header 꼴로, 뒤에 connection id. UDP 443이 열린 망에서 가장 가볍다.
- **TCP(TLS 흉내)**: 접속하면 **ClientHello 모양**(SNI 포함) 레코드를 먼저 보내고, 서버는 ServerHello 모양으로 답한 뒤 `application_data` 레코드로 나른다. TCP 443은 거의 안 막혀서 폴백에 쓴다.
- **자동 선택**: UDP로 HELLO를 던져 1.5초 안에 답이 없으면(=막힘) TCP로 내려간다. 사용자는 아무것도 안 고른다.

페이로드는 모두 ChaCha20 keystream으로 가려, 선 위에서 WG의 고정 헤더가 안 보인다.

> **기존 `unicorn`과 다르다.** `unicorn`은 서버로 안 나가고 기기 안에서 TLS 첫 패킷(SNI)만 쪼개는
> 로컬 트릭이다. nagoing은 WG 트래픽을 **서버까지** 날라 주는 진짜 난독화 프록시다(양쪽에 Rust 프록시).

### ② 손실 보정 (FEC)

지하철·엘리베이터처럼 패킷이 **연속으로**(버스트) 빠지는 곳에서, 재전송을 기다리지 않고 메운다.

- **인터리브 XOR 패리티**: 데이터 `k`개마다 패리티 1개. 연속 패킷을 서로 다른 그룹에 번갈아 넣어(인터리브),
  `groups`개 연속 손실이 각 그룹에 하나씩만 떨어지게 한다 → 전부 복구. 비용은 전송량의 `1/k`.
- 기본값 `k=8, groups=8`: 12.5% 더 보내고 최대 8연속 손실을 되살린다.
- 받은 조각은 즉시 위로 넘기고, **빠진 것만** 패리티로 되살려 넘긴다(순서·중복은 WG가 알아서 처리).

### ③ 빠른 망 전환

와이파이↔LTE로 바뀌면 경로가 끊긴다. nagoing은:

- `network_changed()`(FFI: `nago_nagoing_network_changed`)를 받으면 **전송을 즉시 다시 수립**하고 어떤 전송이 되는지 다시 고른다.
- 클라이언트는 세션을 `session_id`로 식별한다. 주소가 바뀌어 재접속해도 서버는 **같은 세션**으로 알아보고
  **같은 wg0 소켓**을 계속 쓴다. 그래서 서버가 보는 WG 피어 엔드포인트가 안 바뀌어 **WG 재핸드셰이크 없이** 이어진다.

## 선 프로토콜

한 "메시지" = `[nonce 8B][ciphertext]`. ciphertext는 아래 프레임을 ChaCha20으로 가린 것. 전송별 바깥 포장만 다르다
(UDP: QUIC 모양 5바이트 헤더, TCP: TLS 레코드 헤더).

| 프레임 | 뜻 |
|---|---|
| `HELLO` / `HELLO_ACK` | 세션 수립(= 자동 선택의 탐침). session_id 포함 |
| `DATA` | WG 데이터그램 한 개 + FEC 메타(seq·group·gen·index·k) |
| `PARITY` | 그룹의 패리티(= 조각들의 길이프리픽스+패딩 XOR) |
| `PING` / `PONG` | keepalive, 경로 갱신 |

> 난독화는 **보안이 아니라 DPI 회피**다. 진짜 기밀성·무결성은 안쪽 WireGuard가 책임진다.
> PSK는 공유 난독화 키일 뿐 인증 수단이 아니다. TLS/QUIC "모양"도 근사이며, 운영용으로는 진짜 uTLS/QUIC가 다음 단계다.

## 리눅스에서 바로 돌려 보기 (PoC)

서버·클라이언트·가짜 wg0(에코)를 한 프로세스에 띄우고 손실을 주입해 세 기능을 눈으로 확인한다.

```bash
cd NagoTun
cargo run --example nagoing_loopback
cargo test --lib                 # 20개 테스트(ChaCha20 RFC 벡터, FEC 버스트 복구, 왕복, 자동 폴백)
```

예시 출력:

```
A. 손실 없음 (UDP/QUIC 모양): 100/100 왕복
B. 버스트 손실 FEC 끔 : 85/100 왕복  ·  떨군 조각=15  ·  서버 복구=0
B. 버스트 손실 FEC 켬 : 100/100 왕복  ·  떨군 조각=18  ·  서버 복구=18
C. UDP 막힘 → 폴백 전송=tcp(TLS 흉내): 100/100 왕복
```

버스트 손실에서 FEC가 85%→100%로 끌어올리고(서버가 18조각 복구), UDP가 막히면 알아서 TCP로 붙는다.

## 실제 중계기

서버(AWS, wg0 앞단)와 클라이언트(수동 시험)로 띄울 수 있다.

```bash
# 서버: UDP 443·TCP 443을 둘 다 듣고 wg0(51820)로 넘김
cargo run --release --example nagoing_proxy -- server <psk> 0.0.0.0:443 0.0.0.0:443 127.0.0.1:51820

# 클라: NepTUN endpoint를 127.0.0.1:51820으로 돌려 두고
cargo run --release --example nagoing_proxy -- client <psk> <server_ip> 443 443 127.0.0.1:51820 auto
```

## 통합 상태

- **리눅스 코어·PoC** — 완료. `NagoTun/src/nagoing/`, 테스트 20개, `examples/nagoing_loopback`.
- **iOS 앱** — 연결됨. protocol `nagoing`을 고르면 터널 확장이 `nago_nagoing_client_*`(C FFI)로 프록시를
  띄우고 NepTUN의 endpoint를 로컬 포트(127.0.0.1:51822)로 돌린다. `NWPathMonitor`가 경로 변화 때
  `nago_nagoing_network_changed`를 부르고, 서버가 꺼졌다 켜져 IP가 바뀌면 watchdog이 프록시만 새 IP로 다시 띄운다.
  settings 탭에 `nagoing` 블록(`prefer`·`--fec`). 나갈 국가·adblock·auto-connect는 wg와 같다.
  - 앱 쪽: `WifiScan/NagoingSettings.swift`, `VPNManager.saveNagoing`, `VPNView`, `SettingsView`
  - 확장: `WifiScanTunnel/NagoingProxy.swift`, `PacketTunnelProvider`(mode `nagoing`)

- **서버 nagoing 프록시** — 준비됨. `server/nagoing/setup-nagoing.sh`를 각 서버에서 돌리면 TCP 443(TLS 흉내)·
  UDP 51821(QUIC 모양)에서 듣고 wg0(127.0.0.1:51820)로 넘긴다. 프록시 바이너리는 neptun 없이 빌드돼
  외부 크레이트가 0개다(rustc만 필요). WireGuard는 그대로.
  - **포트**: TCP는 443(막힌 망의 핵심). UDP는 51821 — udp 443은 기존 WG REDIRECT가 먼저 가로채서 전용 포트.
  - **★ AWS 보안그룹**: inbound `tcp 443`·`udp 51821`을 열어야 바깥에서 닿는다(호스트 iptables INPUT은 ACCEPT).
  - 설치·운영: [`server/nagoing/README.md`](server/nagoing/README.md).

### 남은 단계

- **서버에 실제 롤아웃** — 위 스크립트를 kr/jp/us/uk 4대에 적용 + SG 열기. **이게 돼야 iOS의 nagoing이 실제로 붙는다**
  (지금은 앱에서 고를 수 있고 양쪽 다 빌드·검증되지만, 서버에 프록시가 떠 있어야 연결된다).
- **안드로이드** — iOS와 같은 FFI로 `NeptunVpnService`에 nagoing 경로 추가.
- **운영 강화** — 진짜 uTLS/QUIC, r>1 Reed–Solomon(2개 이상 동시 손실), 혼잡 제어, 리플레이 방지.

코드: `NagoTun/src/nagoing/`(`obfs`·`frame`·`fec`·`transport`·`proxy`), 예제 `NagoTun/examples/nagoing_*.rs`.
