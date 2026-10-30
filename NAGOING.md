# nagoing — WireGuard 아래에 끼우는 전송 층

WireGuard는 **하나도 바꾸지 않는다.** 그 아래에 작은 층(nagoing)을 하나 끼워, 평소에는 WG가 쓰던 UDP를
그대로 나르되 필요할 때 세 가지를 더 한다. 코어는 Rust(`NagoTun/`)라 iOS·안드로이드·리눅스가 같은 코드를 쓴다.

```
[폰]
  NepTUN(WG 엔진) ──WG UDP──▶ 127.0.0.1:local   ← nagoing 클라이언트 프록시
                                   │  ① 세션 AEAD(ChaCha20-Poly1305)   ② 인터리브 FEC
                                   ▼  자동 선택: UDP 51821(QUIC 모양) → 막히면 진짜 TLS 1.3/TCP 443
                            nagoing 서버 프록시 ──▶ 127.0.0.1:51820 (wg0)
[서버(AWS)]                        ③ session_id로 세션을 묶어 망이 바뀌어도 wg0 소켓은 그대로
```

NepTUN의 endpoint를 서버 대신 **로컬 포트(127.0.0.1:local)**로 돌려 주면 끝이다. WG는 자기 패킷이
로컬로 가는지 서버로 가는지 모른다. 그 패킷을 nagoing이 받아 서버로 날라 준다.

## 세 기능

### ① 막힌 망 우회 (가장 차별화)

학교·회사·호텔 와이파이는 WireGuard(UDP)를 DPI로 알아보고 끊는다. nagoing은 WG 데이터그램을 두 가지 모양으로 감싼다.

- **UDP(QUIC 모양)**: 데이터그램 첫 바이트를 QUIC short-header 꼴로, 뒤에 connection id. UDP 443이 열린 망에서 가장 가볍다.
- **TCP(진짜 TLS 1.3, v2)**: rustls로 **실제 TLS 1.3 핸드셰이크**를 한다(SNI·ALPN `h2,http/1.1` 제안). TLS 1.3이라 서버
  인증서도 암호화돼 선 위에선 평범한 HTTPS와 같다. 서버는 nagoing이 아닌 접속(능동 탐침·브라우저)에 **HTTP 404**를 준다.
  TCP 443은 거의 안 막혀서 폴백에 쓴다.
- **자동 선택**: UDP로 HELLO를 던져 1.5초 안에 답이 없으면(=막힘) TCP로 내려간다. 사용자는 아무것도 안 고른다.

페이로드는 모두 세션 키로 봉인돼(AEAD) 선 위에서 WG의 고정 헤더가 안 보인다. UDP 핸드셰이크는 QUIC long header
(Initial처럼 1200바이트), 데이터는 short header 모양이다.

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

## 선 프로토콜 (v3)

메시지는 두 종류다. 전송별 바깥 포장만 다르다(UDP: QUIC long/short header, TCP: TLS 1.3 안의 `[len u16][kind][body]`).

**핸드셰이크** — `[nonce 12][AEAD_psk(평문)]`. PSK는 내용을 가리는 데만 쓰고, 인증은 안의 MAC이 한다.

| 메시지 | 평문 |
|---|---|
| `HELLO` (클라→서버) | 버전 2 · session_id · 시각 · 난수 16 · **클라 WG 공개키** · MAC |
| `HELLO_ACK` (서버→클라) | 버전 2 · session_id · 서버 난수 16 · MAC |

- MAC 키 = HKDF(X25519(**클라 WG 개인키**, **서버 WG 공개키**)) — 새 키 배포 없이 WG 설정의 키를 그대로 쓴다
  (서버는 wg0 개인키). PSK를 알아도 남의 WG 개인키 없이는 그 세션을 가로챌 수 없고, 가짜 서버는 ACK를 못 만든다.
- 서버는 같은 session_id를 **처음 붙은 WG 키로만** 다시 붙게 하고, HELLO 시각이 ±180초 밖이거나 이미 본 난수면
  답하지 않는다(재전송 공격 방어).

**데이터** — `[가린 카운터 5][봉인한 앞부분][나머지 그대로][태그 16]`(v3: 큰 프레임은 앞 64바이트만 봉인, 320바이트 이하는 통째로). 세션 키 = HKDF(같은 고정 비밀, 클라 난수 ‖ 서버 난수)로
HELLO마다 새로 뽑는다. nonce는 64비트 카운터(절대 안 겹침, 선에는 아래 40비트만), 받는 쪽은 **2048칸 리플레이 창**으로 재전송을 버린다.
카운터는 태그를 표본으로 한 마스크로 가린다(ring의 QUIC 헤더 보호 — 증가하는 숫자가 지문이 되지 않게).
서버는 **인증된** 패킷이 온 주소로만 반환 경로를 옮긴다(위조 패킷으로 경로를 못 돌림).

| 프레임(봉인된 평문) | 뜻 |
|---|---|
| `DATA` | WG 데이터그램 한 개 + FEC 메타(group·gen·index·k) |
| `PARITY` | 그룹의 패리티(= 조각들의 길이프리픽스+패딩 XOR) |
| `PING` / `PONG` | keepalive, 경로 갱신 |

> 안쪽 WireGuard가 따로 기밀성·무결성을 지키므로 nagoing의 암호는 이중 보호다. v2가 새로 막는 것은 nagoing 층 자체의
> 위조·재전송·세션 가로채기(=서비스 방해)와 DPI가 고정된 모양으로 알아보는 것이다.
> 남은 지문: rustls의 ClientHello는 브라우저와 다르다(uTLS 같은 브라우저 흉내는 rustls에 없음).

## 리눅스에서 바로 돌려 보기 (PoC)

서버·클라이언트·가짜 wg0(에코)를 한 프로세스에 띄우고 손실을 주입해 세 기능을 눈으로 확인한다.

```bash
cd NagoTun
cargo run --example nagoing_loopback
cargo test --lib                 # 27개 테스트(ChaCha20 RFC 벡터, FEC 버스트 복구, 왕복, 자동 폴백)
```

예시 출력:

```
A. 손실 없음 (UDP/QUIC 모양): 100/100 왕복
B. 버스트 손실 FEC 끔 : 85/100 왕복  ·  떨군 조각=15  ·  서버 복구=0
B. 버스트 손실 FEC 켬 : 100/100 왕복  ·  떨군 조각=18  ·  서버 복구=18
C. UDP 막힘 → 폴백 전송=tls 1.3 (tcp): 100/100 왕복
```

버스트 손실에서 FEC가 85%→100%로 끌어올리고(서버가 18조각 복구), UDP가 막히면 알아서 TLS 1.3/TCP로 붙는다.

## 실제 중계기

서버(AWS, wg0 앞단)와 클라이언트(수동 시험)로 띄울 수 있다.

```bash
# 서버: UDP 51821·TLS 443을 듣고 wg0(51820)로 넘김. wg.key = wg0 개인키(base64), 인증서는 자체서명
cargo run --release --example nagoing_proxy -- server <psk> 0.0.0.0:51821 0.0.0.0:443 127.0.0.1:51820 wg.key tls.crt tls.key

# 클라: NepTUN endpoint를 local_bind로 돌려 두고(server_pub = 서버 wg0 공개키, 키 파일 생략 시 무작위 키)
cargo run --release --example nagoing_proxy -- client <psk> <server_ip> 51821 443 127.0.0.1:51822 auto <server_pub> [client.key]
```

## 통합 상태

- **리눅스 코어·PoC** — 완료. `NagoTun/src/nagoing/`, 테스트 29개, `examples/nagoing_loopback`.
- **iOS 앱** — 연결됨. protocol `nagoing`을 고르면 터널 확장이 `nago_nagoing_client_*`(C FFI)로 프록시를
  띄우고 NepTUN의 endpoint를 로컬 포트(127.0.0.1:51822)로 돌린다. `NWPathMonitor`가 경로 변화 때
  `nago_nagoing_network_changed`를 부르고, 서버가 꺼졌다 켜져 IP(또는 WG 키)가 바뀌면 watchdog이 프록시만 다시 띄운다.
  v2 HELLO 인증에 쓰도록 WG 설정의 privateKey·serverPub를 FFI로 넘긴다.
  settings 탭에 `nagoing` 블록(`prefer`·`--fec`). 나갈 국가·adblock·auto-connect는 wg와 같다.
  - 앱 쪽: `WifiScan/NagoingSettings.swift`, `VPNManager.saveNagoing`, `VPNView`, `SettingsView`
  - 확장: `WifiScanTunnel/NagoingProxy.swift`, `PacketTunnelProvider`(mode `nagoing`)

- **서버 nagoing 프록시** — 준비됨. `server/nagoing/setup-nagoing.sh`를 각 서버에서 돌리면 TCP 443(TLS 1.3)·
  UDP 51821(QUIC 모양)에서 듣고 wg0(127.0.0.1:51820)로 넘긴다. 빌드할 때 crates.io에서 의존 크레이트를 받으므로
  서버에 외부 접속이 필요하다. WireGuard는 그대로.
  - **포트**: TCP는 443(막힌 망의 핵심). UDP는 51821 — udp 443은 기존 WG REDIRECT가 먼저 가로채서 전용 포트.
  - **★ AWS 보안그룹**: inbound `tcp 443`·`udp 51821`을 열어야 바깥에서 닿는다(호스트 iptables INPUT은 ACCEPT).
  - 설치·운영: [`server/nagoing/README.md`](server/nagoing/README.md).

### 코드 리뷰 반영(하드닝)

- **재접속(#1)**: 클라이언트는 PONG/데이터가 15초 안 오면 전송을 다시 세운다(서버 재부팅·NAT 포트 변경 복구).
  서버는 주소뿐 아니라 **cid로도** 세션을 찾아 NAT 리바인드를 따라간다. iOS watchdog은 IP가 같아도 재수립을 알린다.
  검증: 서버 재시작 뒤 왕복 10/10 복구(전엔 0).
- **한 클라가 서버 전체를 멈추던 것(#2)**: 서버·클라 TCP에 쓰기 제한(5초), 세션 표 잠금을 쥔 채 ret 잠금을 안 기다림.
- **MTU(#3)**: nagoing 터널 MTU 1380(오버헤드 포함 바깥 UDP가 1500을 안 넘게 — 조각화 방지).
- **지문(#4)**: 패킷 nonce를 매번 OS 난수로(키스트림 재사용·평문 카운터 제거), QUIC 첫 바이트 하위 비트 무작위,
  작은/컨트롤 프레임에 무작위 패딩(WG 핸드셰이크 148/92 크기 가림).
- **자원 누수(#5)**: 유휴 세션(5분) 정리 스레드. TCP 연결은 30초 동안 프레임이 없으면 서버가 끊는다(망 전환으로
  FIN 없이 버려진 옛 연결, PSK 없이 레코드 하나만 보내고 붙어 있는 연결). 동시 TCP 연결 1024개·세션 4096개 상한,
  스레드 생성 실패는 panic(=abort) 대신 연결/세션 거절.
- **연결 지연(#6)**: TCP connect 제한(3초).
- 난수: `getrandom`(OS 난수)으로 교체 — 스레드 경합·예측 가능성 제거.
- **UDP 루프 멈춤**: 세션 반환 경로(ret) 잠금은 경로를 복제하는 동안만 쥐고 전송은 밖에서 한다. HELLO_ACK·PONG은
  요청이 온 그 경로로 바로 답한다 → 한 클라의 멈춘 TCP 쓰기가 모든 UDP 클라를 세우지 않는다.
- **FEC 리셋**: 상대 인코더가 새로 시작해 세대가 0으로 돌아가면(서버 재시작·세션 재생성) 디코더가 그 그룹을 새로 시작한다.
  예전엔 새 세대를 전부 '오래된 것'으로 지워 다운로드 FEC가 사실상 꺼졌다.
- **TCP 어긋남**: 쓰기가 레코드 중간에 끊기면 연결을 닫는다. 클라의 살아 있음(stale) 판단은 제대로 풀린 프레임으로만.
- **빠른 stop**: 수립(HELLO·ServerHello 대기) 중에도 stop을 확인 → 확장의 stopTunnel·watchdog이 오래 안 멈춘다.
- **auto 기억**: 붙었던 UDP가 조용해지면(도중에 막힘) 5분간 TCP 먼저. 망이 바뀌면 다시 UDP부터.
- **덜 찬 FEC 그룹**: 200ms 넘게 안 찬 그룹은 그 개수로 닫아 패리티를 낸다(디코더는 패리티의 k로 그룹을 줄임).
  드문 트래픽(핸드셰이크·DNS·통화)도 복구되고, 대용량은 그룹이 먼저 차서 추가 비용이 없다. 옛 버전과 섞여도 무해.
- **로컬 포트 보호**: 클라는 루프백에서 온 WG 모양 패킷만 받아 내려받기 대상으로 삼는다(같은 기기의 다른 앱이
  51822로 보내도 안 샘).
- **기타**: 서버 주소·cid 표는 세션당 최신 하나만(오래 붙은 세션에서 계속 커지던 것), HELLO 버전 확인,
  모양이 이상한 UDP 패킷 하나로 재접속하지 않음, iOS stop·watchdog의 프록시 종료는 백그라운드(메인 안 막음),
  settings에서 `--nagoing`을 끄면 저장된 프로필도 일반 WG로 되돌림.

### v2 (2.1.6): 진짜 TLS + 재전송 공격 방어

- **#7 리플레이/무결성** — 완료. WG 키로 인증한 HELLO(시각 ±180초 + 난수 캐시), HELLO마다 새 세션 키, 데이터 AEAD
  (ChaCha20-Poly1305, ring) + 2048칸 리플레이 창, 같은 session_id는 처음 붙은 WG 키로만. 인증된 패킷만 경로를 옮김.
- **#8 진짜 TLS** — 완료. TCP 443은 rustls TLS 1.3(인증서는 서버마다 자체서명, 클라는 안쪽 HELLO_ACK로 서버 인증).
  nagoing이 아닌 TLS 접속엔 HTTP 404. UDP 핸드셰이크도 QUIC Initial 모양(long header, 1200바이트).
- **v1과 호환 안 됨**: 서버를 v2로 올리면 2.1.5 앱의 nagoing은 붙지 않는다 → 2.1.6으로 같이 올린다.

### v3 (2.1.7): NagoTun 직결 + 부분 봉인 — 폰 CPU 줄이기

- **엔진 직결** (`nago_nagoing_attach`): NagoTun 엔진에 바깥 전송 자리(`DeviceConfig::external_net`)를 만들어, 엔진이
  암호화한 WG 데이터그램을 127.0.0.1 UDP 대신 nagoing이 바로 받아 보내고, 받은 건 `receive_external`로 바로 복호화→tun.
  패킷마다 sendto/recvfrom 둘과 스레드 넘김이 빠진다. 비어 있으면(nagoing 끔) 엔진은 원래 UDP 그대로.
  엔진→nagoing은 강한 참조, nagoing→엔진은 약한 참조라 어느 쪽을 먼저 멈춰도 소켓이 남지 않고, 붙기 전·뗀 뒤엔 로컬 UDP로 폴백.
- **부분 봉인(v3)**: 큰 프레임은 앞 64바이트(nagoing 헤더 + WG 헤더)만 봉인하고 나머지(이미 WG 암호문)는 그대로 싣는다.
  320바이트 이하 프레임(컨트롤·작은 DATA, 패딩 포함)은 통째로. 카운터·헤더는 인증되므로 재전송·위조 방어는 같다.
  카운터는 아래 40비트만 싣고(QUIC 패킷 번호처럼 복원) ring의 QUIC 헤더 보호로 가린다.
- **FEC 디코더**: 받은 조각을 저장하지 않고 그룹마다 XOR 누적 하나만(패킷마다 할당·복사 없음), 표 정리는 세대가 바뀔 때만,
  XOR은 8바이트씩.
- **버그 수정**: 로컬 포트 보호가 WG 데이터 길이를 16의 배수로 봐서 NepTUN(패딩 안 함)의 데이터 패킷 대부분을 버렸다
  (2.1.5 build 36 ~ 2.1.6). 데이터는 32바이트 이상이면 받는다.
- v2와 호환 안 됨 → 서버와 앱(2.1.7)을 같이 올린다.

**클라 CPU (리눅스 벤치 `examples/nagoing_attach_bench.rs`, 클라·서버 다른 프로세스·다른 코어, MTU 1380 왕복, FEC 켬)**

| | 처리량(각 방향) | 클라 1GB당 CPU초 |
|---|---|---|
| WG만(nagoing 없음, 바닥) | ~890 Mbps | ~5.3 |
| 2.1.6 방식(로컬 홉 + 전체 재암호화 + 옛 FEC) | ~350 Mbps | ~15.0 |
| **2.1.7 (직결 + 부분 봉인 + 새 FEC)** | **~555 Mbps** | **~8.6 (−43%)** |

남은 차이(WG만 대비)는 받는 쪽이 엔진 루프가 아니라 nagoing 스레드에서 돌아 생기는 깨움·넘김이다. callgrind로 보면 사용자 공간
명령의 대부분은 이제 WG 자신의 암호화(ChaCha20-Poly1305)다.

### 아직 남은 것

- PSK(`nago-obfs-v1`)가 공개 소스에 있다 — v2에선 HELLO를 가리는 용도뿐이라 보안 영향은 작지만, DPI가 HELLO를 풀어
  모양을 확인할 수는 있다 → 빌드 주입 + 서버 동시 교체.
- rustls ClientHello는 브라우저 지문과 다르다(uTLS 같은 흉내는 rustls에 없음). 진짜 QUIC(Initial 암호화 규칙)도 아님.
- **🟡**: TCP에서 FEC 끄기, HELLO로 FEC 설정 전달, auto의 UDP/TCP 동시 시도, 할당 줄이기, UDP 수신 스레드 분할.

### 남은 단계

- **서버에 실제 롤아웃** — 위 스크립트를 kr/jp/us/uk 4대에 적용 + SG 열기. **이게 돼야 iOS의 nagoing이 실제로 붙는다**
  (지금은 앱에서 고를 수 있고 양쪽 다 빌드·검증되지만, 서버에 프록시가 떠 있어야 연결된다).
- ~~안드로이드~~ — 2.1.7에서 됨: `NagoingNative.kt` → `src/android.rs`, 엔진에 바로 붙이고 소켓은 `VpnService.protect()`로 터널 밖에.
- **운영 강화** — 브라우저 지문(uTLS)/진짜 QUIC, r>1 Reed–Solomon(2개 이상 동시 손실), 혼잡 제어.

코드: `NagoTun/src/nagoing/`(`crypto`·`frame`·`fec`·`transport`·`proxy`), 예제 `NagoTun/examples/nagoing_*.rs`.
