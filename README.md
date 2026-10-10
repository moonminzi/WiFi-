# NAGO VPN (iOS)

앱 이름은 **NAGO VPN**. 탭 두 개짜리 앱입니다. 화면은 대시보드 사이트와 같은 터미널 스타일(초록빛 다크 팔레트, JetBrains Mono, `~/vpn $▌` 머리줄)이고 아이콘은 `>_`.

- **vpn** 탭: AWS에 띄운 IKEv2 서버로 연결(공용 와이파이에서 트래픽 보호). 한국·일본·미국·영국 중 나갈 국가를 고를 수 있음
- **dash** 탭: 모든 서버(kr/jp/us/uk)의 상태·IP·가동 시간·유휴 카운터·IKEv2 접속, 서울 WireGuard 피어, 시간별 송신량, 이번 달 송신량/비용 추정을 한 화면에

## VPN 탭

- iOS 내장 Personal VPN(`NEVPNManager`)으로 **IKEv2 + EAP-MSCHAPv2** 연결 — 별도 확장/라이브러리 없음
- 서버는 AWS EC2의 **strongSwan**. 구축·재현 방법과 접속 안내는 [`server/README.md`](server/README.md) 참고
- **국가 선택**: 🇰🇷 서울 · 🇯🇵 도쿄 · 🇺🇸 오리건 · 🇬🇧 런던. 연결을 누르면 API(`VPNRegion.swift`)가 그 나라 서버를 켜고(꺼져 있으면 1~2분) 지금 IP를 받아 접속한다. 서버는 거의 안 쓰면 알아서 꺼진다(서울 3시간, 해외 30분)
- 자체 서명 CA라서 최초 1회 `server/WifiScanVPN.mobileconfig` 설치 + 인증서 신뢰가 필요
  (설정 → 일반 → 정보 → 인증서 신뢰 설정)
- 비밀번호는 기기 **키체인**에만 저장(소스/저장소에 없음)
- **비밀번호 내장(선택)**: 레포가 공개라 소스에는 넣지 않는다. 전달용 IPA에만 빌드 후 `Info.plist`에 `NAGOPresetPassword`를 넣으면 입력 칸 없이 연결된다(없으면 입력 칸이 보이고 키체인에 저장)
- **빠른 모드** 토글(기본 켜짐): 서버 제안(`aes256gcm16`/`ecp256`)에 맞춘 AES-256-GCM + PFS, 터널 MTU 1400(iOS 기본 1280)으로 연결. 하드웨어 AES로 처리돼 iOS 기본값(AES-CBC + HMAC)보다 가볍다. 연결이 안 되면 끄면 기본값으로 돌아감

## protocol (auto / ikev2 / wg / unicorn)

- **ikev2**: 폰 내장 IKEv2(아이폰 NEVPNManager, 안드로이드 VpnManager). 폰에서 제일 빠름
- **wg**: 앱 안 WireGuard(iOS는 WifiScanTunnel 확장 + WireGuardKit, 안드로이드는 wireguard-android). udp 443이라 IKEv2가 막힌 와이파이에서도 붙음
- **auto**: IKEv2를 12초 기다려 안 붙으면 WireGuard로
- **unicorn**(iOS): 서버로 안 나간다. SNI 차단만 우회한다 — 아래 참고
- WireGuard 키는 폰에서 처음 한 번 만들고 공개키만 피어 목록(SSM 파라미터 `/nago/wg/peers`)에 등록. 서버 4대 모두 같은 목록으로 맞춰짐(`server/wireguard/setup-wg.sh`, `nago-peer sync`)
- **wg engine**(iOS): `neptun`(기본) — NordVPN이 쓰는 Rust 엔진 NepTUN(BSD-3)을 `NagoTun/`(C 인터페이스)으로 감쌈. utun fd를 엔진 스레드가 직접 읽고 씀 / `go` — WireGuardKit(공식 WireGuard 앱과 같은 wireguard-go)
  - 리눅스 검증(서울→도쿄): NepTUN 다운 약 250~290Mbps, 커널 WireGuard 약 270Mbps로 같은 급. `NagoTun/examples/linux_tun.rs`로 서버에서 재현 가능
  - iOS 빌드 때 `NagoTunRust` 타깃이 `NagoTun/build-ios.sh`로 `cargo build --target aarch64-apple-ios`(Rust 필요)
- iOS 빌드: `Vendor/WireGuardKit`(wireguard-apple 1.0.16-27, MIT, Xcode 16용 두 줄 수정) + Go 1.24로 libwg-go.a를 만드는 `WireGuardGoBridgeiOS` 타깃
- 재서명할 때 확장(`.tunnel`)도 같이 서명돼야 하고, 두 App ID 모두 Network Extensions(packet tunnel) 권한이 필요

## unicorn (SNI 차단 우회, iOS)

HTTPS 접속 차단을 지나간다. 다른 프로토콜과 달리 **서버로 나가지 않는다**. 기기 안에서만 도는 터널을
하나 만들고, 지나가는 트래픽 중 TLS 첫 패킷만 손봐서 평소 회선으로 그대로 내보낸다. 중계 서버가
없으니 속도가 거의 그대로고, 트래픽이 어디에 남지도 않는다. 같은 터널 확장(`WifiScanTunnel`)을 쓰고
`providerConfiguration["mode"]`가 `unicorn`이면 WireGuard 대신 이 스택이 뜬다.

하는 일은 세 가지다.

- **ClientHello 분할**: HTTPS 접속의 첫 패킷에는 접속할 도메인 이름(SNI)이 평문으로 들어 있고,
  차단 장비는 이걸 읽고 연결을 끊는다. 그 이름 **글자 사이**를 끊어 여러 조각으로 나눠 보내면
  한 덩어리로 보이지 않아 검사를 통과한다.
  - `record`: TLS 레코드를 여러 개로 나눔(핸드셰이크 메시지가 여러 레코드에 걸쳐도 되는 건
    TLS 규격에 있어서 서버가 그대로 받아 준다). 호환성이 가장 좋다
  - `segment`: 레코드는 하나로 두고 TCP 패킷을 나눔(Nagle을 끄고 `send()` 사이를 4ms 띄운다)
  - `both`(기본): 둘 다. `pieces`로 2~5조각까지
- **암호화 DNS(DoH)**: SNI 차단은 DNS 변조와 같이 오는 경우가 많다. 질의를 Cloudflare/Google/Quad9에
  HTTPS로 보내 응답이 바뀌는 걸 막는다(`doh` 선택, `off`면 settings의 custom dns로 평문 질의).
  DoH가 막히면 두 번 시도한 뒤 평문 DNS로 떨어진다
- **QUIC 차단**: HTTP/3(QUIC, UDP 443)은 암호화 방식이 달라 같은 수법을 쓸 수 없다. 기본으로 버리면
  앱이 알아서 TLS over TCP로 내려오고, 그때 분할이 걸린다

구현은 `WifiScanTunnel/Unicorn*.swift`. tun으로 들어온 IP 패킷을 직접 읽고
([`UnicornPacket.swift`](WifiScanTunnel/UnicornPacket.swift)), TCP는 기기 안에서 끝낸 뒤
([`UnicornTCPFlow.swift`](WifiScanTunnel/UnicornTCPFlow.swift)) 실제 목적지로는 `NWConnection`으로
다시 연결한다. 내보내기 직전에 ClientHello를 쪼개는 건
[`UnicornClientHello.swift`](WifiScanTunnel/UnicornClientHello.swift)가 한다.
터널 반대쪽은 같은 기기의 TCP 스택이라 패킷이 사라지지 않으니, 재전송 큐 없이 순서가 맞는 세그먼트만
받아 바로 ACK하고 윈도만 지킨다. 확장이 만드는 연결은 모두 `prohibitedInterfaceTypes = [.other]`로
자기 터널을 피하고, DoH 서버 IP는 경로에서 빼 둔다(안 그러면 서로를 기다리며 멈춘다).

- 설정은 settings 탭의 `unicorn https` 블록. 분할 방식·조각 수·`--sni-cut`(이름 안쪽에서 끊기)·
  `--all-ports`(443 외 포트도)·`--block-quic`·`--ipv6`·`doh`
- 나갈 국가(exit node)·사용자 이름·비밀번호가 필요 없다
- **킬 스위치와 같이 못 쓴다**: 확장이 DoH로 직접 나가야 하는데 `includeAllNetworks`가 모든 통신을
  터널로 밀어 넣으면 멈출 수 있어서, 킬 스위치를 켜면 프로토콜이 wg로 고정된다. 자동 연결은 된다
- 공용 와이파이 로그인 창(캡티브 포털)이 떠야 할 때는 잠깐 꺼야 한다
- 쪼갠 횟수·DNS 질의 수는 settings → logs에서 볼 수 있다(`split 12 · tcp 31 · open 7 · dns 40`)

## settings 탭

vpn 탭은 상태·국가·연결 버튼만 두고, 나머지 설정은 settings 탭에 있다(연결 중에는 잠김, 다음 연결부터 적용).

- **account / protocol / --fast / --adblock**: 예전 vpn 탭에 있던 것
- **auto-connect** (iOS: `off / always / wi-fi`): On Demand 규칙. wi-fi는 와이파이에서만 붙고 셀룰러에선 끊음. 앱에서 disconnect를 누르면 자동 연결도 같이 꺼진다
- **--kill-switch** (iOS): `includeAllNetworks`. 터널이 끊긴 동안 다른 트래픽을 막는다. `--allow-lan`을 켜면 같은 망 기기(프린터·AirPlay)는 터널 밖(`excludeLocalNetworks`). 켠 채 앱을 다시 설치하면 iOS가 모든 통신을 막아 버리는 문제가 있어서 업데이트 전에 끈다
- **unicorn https**: 프로토콜이 `unicorn`일 때만 보인다(위 unicorn 절 참고)
- kill-switch를 켜면 프로토콜이 wg로 고정된다. auto-connect는 우리 터널 확장이어야 하므로 ikev2/auto에서 켜면 wg로 바뀐다(unicorn은 그대로 쓸 수 있다). 서버를 깨우고 바뀐 IP를 따라가는 건 우리 터널 확장만 할 수 있어서다
  - 터널 확장은 핸드셰이크가 170초 넘게 없으면(서버 유휴 종료, 재부팅으로 IP 변경) 국가 API로 서버를 켜고 주소가 바뀌었으면 피어를 바꾼다. 확장 자신의 통신은 킬 스위치에도 막히지 않는다
- **custom dns** (wg만): `1.1.1.1, 8.8.8.8`처럼. --adblock이 켜져 있으면 광고 차단 DNS가 우선. IKEv2 DNS는 서버가 준다
- **안드로이드**: `--allow-lan`(IKEv2 `setLocalRoutesExcluded`, wg는 사설망·멀티캐스트 대역을 AllowedIPs에서 뺌), 항상 켜기·킬 스위치는 시스템 VPN 설정(`system ›`)에서
- **안드로이드 wg engine**: `neptun`(기본) — iOS와 같은 NepTUN을 `NagoTun/build-android.sh`(NDK)로 libnago_tun.so로 빌드해 JNI(`NagoTun/src/android.rs`, `NeptunNative.kt`)로 부른다. `NeptunVpnService`가 TUN을 만들고 엔진에 넘김. NordVPN과 같게 이벤트 루프 4개 + 서버마다 connect한 UDP 소켓. 앱 자신은 VPN에서 빼서(`addDisallowedApplication`) 엔진 소켓과 국가 API 요청이 터널 밖으로 나간다. 핸드셰이크가 끊기면 iOS처럼 서버를 깨우고 새 주소로 바꾼다 / `go` — wireguard-android GoBackend
  - 빌드에 Rust와 Android NDK가 필요(Gradle `preBuild` 앞에 `buildNagoTun`이 돈다. NDK는 `ANDROID_NDK_HOME` 또는 `<SDK>/ndk/<버전>`)
- **logs**: 진행 단계·오류·VPN 상태 변화(끊긴 이유 포함). iOS는 터널 확장이 켜져 있으면 확장의 로그와 상태(wg는 핸드셰이크·주고받은 양, unicorn은 쪼갠 횟수·DNS 질의 수)도 같이 보여 준다
- **server**: 가속(TCP 분할)은 4대 모두 IKEv2·WireGuard TCP에 켜져 있음

## --adblock (광고·추적 차단, 앱 전용)

- vpn 탭(iOS)·안드로이드 앱의 `--adblock`을 켜고 연결하면 서버 DNS(10.53.53.53)가 광고·추적 도메인을 막는다
- 서버: `server/adblock/setup-adblock.sh` (dnsmasq + OISD big + YousList, 매일 갱신). 모든 서버(kr/jp/us/uk)에 설치됨
- 구분 방법: IKE ID를 `adblock.nago`로 보내면 strongSwan이 `ikev2-adblock` 연결을 골라 차단 DNS를 준다. 비밀번호 확인(EAP)은 그대로 사용자 이름
- 앱 안 WireGuard는 DNS를 10.53.53.53으로 바꾼다. WireGuard 앱(친구 .conf)과 보통 연결은 그대로 1.1.1.1. 잘못 막힌 사이트는 서버의 `/etc/nago-dns/allow.conf`에 `server=/도메인/1.1.1.1`

## dash 탭 (통합 대시보드)

- 서버 쪽 Lambda(`server/dashboard/index.py`)가 모든 리전을 모아 JSON으로 준다. 브라우저용 HTML 사이트도 같은 Lambda가 만든다(`?t=<토큰>`)
- 앱은 VPN 비밀번호(내장 값 또는 키체인)를 `x-nago-key` 헤더로 보내 인증하고, 보이는 동안 30초마다 새로 받는다(당겨서 새로고침도 됨)
- 비용은 실행 시간(CloudWatch 5분 데이터 개수) × 온디맨드 단가 + 고정 IP/디스크 + 무료 100GB 초과 송신으로 어림한 값
- **서버 관리**: 서버 줄을 누르면 켜기 / 끄기 / 재부팅 / 유휴 타이머 0으로. 켜고 끈 뒤 몇 번 더 새로 받아 상태 변화를 보여 준다
- **피어 관리**: WireGuard 피어 줄을 누르면 kick(60초 끊기) · 사용량 초기화 · 이름 바꾸기 · 삭제. `wg peer add [+ new]`로 새 피어를 만든다
  - 키는 폰에서 만들고(CryptoKit) 공개키만 서버로 보낸다. 개인키는 QR/.conf 화면에만 있고 닫으면 남지 않는다
  - 서버 쪽은 Lambda가 SSM으로 `server/dashboard/nago-peer.py`를 서울 서버에 설치·실행한다. 이름은 `/etc/wireguard/nago-names.json`
  - 바꾸는 요청은 VPN 비밀번호(`x-nago-key`)로만 된다. 사이트 토큰으로는 볼 수만 있다
  - 서울 서버가 꺼져 있으면 관리할 수 없다(kr로 한 번 연결하면 켜짐)

## 안드로이드 앱 (`android/`)

친구용 안드로이드 버전. 화면은 iOS VPN 탭과 같은 터미널 스타일이고 국가 선택(kr/jp/us/uk)도 같다.

- 안드로이드 **내장 IKEv2**(VpnManager + `Ikev2VpnProfile`)를 쓴다. 별도 VPN 엔진이나 라이브러리 없음
- 서버 CA를 앱에 넣어서(`res/raw/nago_ca.pem`) 기기에 인증서를 설치할 필요가 없다
- 해외 서버는 IP가 바뀌므로 `IkeSessionParams`로 "접속은 IP, 인증서 확인은 FQDN(jp.nago.vpn)"을 따로 지정한다 → **Android 13 이상**
- 데이터 암호: AES-256-GCM(재키 때 서버 사정에 따라 AES-CBC+SHA256), MTU 1400
- 빌드: `gradle -p android assembleDebug` (CI: `.github/workflows/build-apk.yml`, 비밀번호 없는 디버그 APK)
- 전달용 APK는 `app/src/main/assets/preset.txt`(커밋 안 함)에 비밀번호를 넣고 `NAGO_KEYSTORE`/`NAGO_KEYSTORE_PASS` 환경변수로 서명해서 만든다
- 설치: APK 파일을 열고 "출처를 알 수 없는 앱" 허용 → 설치 → 처음 연결할 때 "VPN 연결 요청" 허용

## 빌드 방법 A: XcodeGen (추천)

```bash
brew install xcodegen
cd WifiScan
# project.yml에서 DEVELOPMENT_TEAM, PRODUCT_BUNDLE_IDENTIFIER 수정
xcodegen
open WifiScan.xcodeproj
```
아이폰을 연결하고 ▶︎ 실행. 자동 서명이라 App ID 등록과 기능(capability) 추가는 Xcode가 알아서 해 줌.

## 빌드 방법 B: Xcode에서 직접 만들기

1. File → New → Project → iOS App (Interface: SwiftUI), iOS 17 이상
2. 템플릿이 만든 `ContentView.swift`, `<이름>App.swift`는 지우고 `WifiScan/` 폴더의 `.swift` 파일 7개, `Assets.xcassets`(앱 아이콘), `Fonts/`를 끌어다 넣기
3. Info 탭 → `Fonts provided by application`(UIAppFonts)에 `JetBrainsMono-Regular.ttf`, `JetBrainsMono-SemiBold.ttf`, `JetBrainsMono-Bold.ttf` 추가
4. Signing & Capabilities → 본인 Team 선택 → `+ Capability`로 **Personal VPN** 추가
5. 아이폰에서 실행

글꼴: JetBrains Mono (SIL Open Font License 1.1, `WifiScan/Fonts/OFL-JetBrainsMono.txt`)
