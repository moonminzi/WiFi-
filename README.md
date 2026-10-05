# 스캔툴 (iOS)

탭 세 개짜리 아이폰 앱.

| 탭 | 하는 일 |
|---|---|
| **와이파이** | 와이파이 안내 종이를 찍으면 ID/PW를 읽어서 바로 연결. 손글씨에서 헷갈리는 글자(0/O/D, 1/l/I, 5/S…)는 눌러서 고칠 수 있음 |
| **계좌번호** | 단톡방 캡처·공지 사진·복사한 글에서 은행과 계좌번호(+예금주)를 찾아 복사, QR, 토스·카카오뱅크로 열기 |
| **QR 공유** | 파일·사진·동영상을 tmpfiles.org에 올려 링크를 QR로 / 문서 스캔 → PDF → QR / 와이파이 QR(카메라로 찍으면 바로 연결) / 텍스트·링크 QR |
| **공유 시트** | 카톡·사진·사파리·파일에서 공유 → scantool: 이미지는 와이파이·계좌를 바로 찾고, 파일은 올려서 QR. 텍스트·링크도 QR로 |

- 글자 인식은 Apple Vision으로 기기 안에서 처리 (사진이 밖으로 안 나감)
- 와이파이 연결은 `NEHotspotConfiguration` → "연결하시겠습니까?" 한 번이면 접속, 실제로 붙었는지 확인까지 함

## IPA 받기

`main`에 푸시하면 GitHub Actions(macOS)가 **서명 안 된 IPA**를 만들어 [Releases](../../releases)에 올림.
설치하려면 본인 인증서로 다시 서명해야 함:

1. developer.apple.com → Identifiers에서 App ID 만들기. **Hotspot**과 **Access Wi-Fi Information**을 꼭 체크
2. Devices에 아이폰 UDID 등록
3. Profiles에서 그 App ID + 아이폰으로 Development 또는 Ad Hoc 프로파일 만들기
4. `.p12` + 프로파일로 IPA 서명 후 설치 (Feather·ESign·KSign, 또는 `zsign`)

공유 시트 확장(`PlugIns/ShareExtension.appex`)은 번들 ID가 `<앱 번들 ID>.share`라서 프로파일이 하나 더 필요함.
확장에는 특별한 권한이 없으니 그 ID로 App ID(기능 체크 없음) + 프로파일을 하나 더 만들거나, 와일드카드 App ID 프로파일을 써도 됨.

```bash
zsign -k cert.p12 -p 비번 -m app.mobileprovision -m share.mobileprovision -o signed.ipa WifiScan.ipa
```

서명 도구가 확장을 처리하지 못하면 "플러그인 제거" 옵션으로 빼고 설치해도 앱 자체는 그대로 동작함.

Xcode로 직접 빌드하려면: `brew install xcodegen && xcodegen && open WifiScan.xcodeproj`
(project.yml의 `DEVELOPMENT_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER` 수정)

## 파일 공유

[tmpfiles.org](https://tmpfiles.org) API를 써서 따로 설정할 것이 없음.

- 파일당 100MB까지, 공유 기간 1시간 / 6시간 / 1일 / 2일 (기간이 지나면 서버에서 지워짐)
- 링크를 아는 사람은 누구나 받을 수 있으니 민감한 파일은 올리지 말 것
- tmpfiles가 파일 이름의 한글을 지워서, 받는 쪽 파일 이름은 영문·숫자만 남을 수 있음 (앱 목록에는 원래 이름으로 보임)
- 아이폰 HEIC 사진은 안드로이드·PC에서도 열리게 JPEG로 바꿔서 올림
