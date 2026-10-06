# NAGO VPN (iOS)

앱 이름은 **NAGO VPN**. 탭 두 개짜리 앱입니다.

- **와이파이 스캔** 탭: 와이파이 안내 종이를 찍거나 사진을 고르면 ID/PW를 읽어서 바로 연결
- **VPN** 탭: AWS에 띄운 IKEv2 서버로 연결(공용 와이파이에서 트래픽 보호). 한국·일본·미국·영국 중 나갈 국가를 고를 수 있음

## 와이파이 스캔 탭

- OCR: Apple Vision (기기 안에서 처리, 네트워크 안 씀)
- 연결: `NEHotspotConfiguration` → "연결하시겠습니까?" 한 번 누르면 접속
- 접속 확인: `NEHotspotNetwork.fetchCurrent()`로 실제로 붙었는지 확인하고, 실패하면 저장된 설정을 지움
- 손글씨에서 헷갈리는 글자(0/O/D, 1/l/I, 5/S, 6/G …)를 색으로 표시하고, 누르면 비슷한 글자로 바뀜

## VPN 탭

- iOS 내장 Personal VPN(`NEVPNManager`)으로 **IKEv2 + EAP-MSCHAPv2** 연결 — 별도 확장/라이브러리 없음
- 서버는 AWS EC2의 **strongSwan**. 구축·재현 방법과 접속 안내는 [`server/README.md`](server/README.md) 참고
- **국가 선택**: 🇰🇷 서울 · 🇯🇵 도쿄 · 🇺🇸 오리건 · 🇬🇧 런던. 연결을 누르면 API(`VPNRegion.swift`)가 그 나라 서버를 켜고(꺼져 있으면 1~2분) 지금 IP를 받아 접속한다. 서버는 3시간 동안 거의 안 쓰면 알아서 꺼진다
- 자체 서명 CA라서 최초 1회 `server/WifiScanVPN.mobileconfig` 설치 + 인증서 신뢰가 필요
  (설정 → 일반 → 정보 → 인증서 신뢰 설정)
- 비밀번호는 기기 **키체인**에만 저장(소스/저장소에 없음)
- **빠른 모드** 토글(기본 켜짐): 서버 제안(`aes256gcm16`/`ecp256`)에 맞춘 AES-256-GCM + PFS, 터널 MTU 1400(iOS 기본 1280)으로 연결. 하드웨어 AES로 처리돼 iOS 기본값(AES-CBC + HMAC)보다 가볍다. 연결이 안 되면 끄면 기본값으로 돌아감

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
2. 템플릿이 만든 `ContentView.swift`, `<이름>App.swift`는 지우고 `WifiScan/` 폴더의 `.swift` 파일 10개를 끌어다 넣기
3. Signing & Capabilities → 본인 Team 선택 → `+ Capability`로 추가:
   - **Hotspot Configuration**
   - **Access Wi-Fi Information**
   - **Personal VPN** (VPN 탭용)
4. Info 탭 → `Privacy - Camera Usage Description` 추가 (예: "와이파이 안내문 촬영")
5. 아이폰에서 실행

## 사용

- **촬영 / 사진 / 붙여넣기** 중 하나로 이미지를 넣음 (카톡이나 메시지로 받은 사진은 길게 눌러 복사 → 붙여넣기가 제일 빠름)
- "인식되면 바로 연결"이 켜져 있으면 ID/PW를 모두 찾았을 때 바로 연결 창이 뜸
- 실패하면 색으로 표시된 글자를 눌러 고치고 다시 **연결**

## 참고

- 앱으로 추가한 네트워크는 앱을 지우면 같이 지워짐
- 무료 계정으로는 Hotspot Configuration을 쓸 수 없음 (유료 개발자 계정 필요)
