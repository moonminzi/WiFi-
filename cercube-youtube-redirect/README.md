# Cercube 유튜브 앱 리다이렉트

유튜브 링크(`youtube.com` / `youtu.be` / `m.youtube.com`)를 **브라우저에서 눌렀을 때 바로 유튜브(Cercube) 앱으로** 넘겨주는 확장입니다.

Safari에서 유튜브 링크를 열면 보통 모바일 웹페이지가 뜨죠. 이 확장을 깔면 그 링크가 **열리기 시작하는 순간**(`document_start`) `youtube://` URL 스킴으로 바꿔서, 설치돼 있는 유튜브(Cercube) 앱으로 바로 보냅니다.

- 📱 **iOS/iPadOS Safari 확장**으로 쓰는 게 주 용도 (Cercube = 사이드로드/탈옥 유튜브 앱)
- 💻 Chrome · Edge · Firefox 에서도 그대로 동작하는 **크로스 브라우저 Manifest V3** 확장
- 🔀 켜고/끄는 **토글** 팝업 제공 (끄면 평소처럼 웹으로 열림)

> **왜 필요하냐면:** 정식 유튜브 앱은 유니버설 링크로 Safari 링크를 가로채지만, Cercube처럼 재서명한 앱은 그 권한(associated domains)이 빠져서 링크가 계속 Safari에서 열립니다. 이 확장이 그 자리를 대신합니다.
>
> Cercube는 유튜브 앱을 바꿔치기한 거라 OS에는 여전히 "유튜브 앱"으로 등록됩니다. 그래서 `youtube://` 스킴이 그대로 Cercube에서 열립니다. (정식 유튜브 앱이 깔려 있어도 동일하게 동작)

---

## 작동 원리

유튜브 iOS 앱은 `youtube://` URL 스킴을 처리합니다. 이 확장은 웹 URL을 앱 URL로 이렇게 바꿉니다:

| 눌린 링크 | 앱으로 보내는 주소 |
|---|---|
| `https://www.youtube.com/watch?v=ABC&t=30` | `youtube://www.youtube.com/watch?v=ABC&t=30` |
| `https://m.youtube.com/watch?v=ABC` | `youtube://www.youtube.com/watch?v=ABC` |
| `https://youtu.be/ABC?t=30` | `youtube://www.youtube.com/watch?v=ABC&t=30` |
| `https://www.youtube.com/shorts/ABC` | `youtube://www.youtube.com/shorts/ABC` |
| `https://www.youtube.com/@handle` | `youtube://www.youtube.com/@handle` |
| `https://www.youtube.com/playlist?list=XYZ` | `youtube://www.youtube.com/playlist?list=XYZ` |

즉 watch / shorts / 채널 / @핸들 / 재생목록 / 검색 결과 다 넘어갑니다. `youtu.be` 단축 링크는 정식 watch 주소로 정규화해서 보냅니다(타임스탬프 `t`도 유지).

**앱이 없으면?** 스킴 이동이 그냥 무시되고 원래 웹페이지가 계속 뜹니다. 깨지지 않습니다.

---

## 설치 방법

### A. iOS / iPadOS — IPA로 설치 ⭐ 추천

Cercube를 깔 때처럼 **IPA를 사이드로드**하면 됩니다. 안에 껍데기 앱 + Safari 확장(`YTRedirectExtension.appex`)이 들어 있습니다. **iOS/iPadOS 17 이상.**

1. 레포의 **Releases**에서 최신 `ytredirect-N`의 `YTRedirect.ipa`를 받기
   (GitHub Actions `Build YT Redirect IPA`가 `cercube-youtube-redirect/` 를 고칠 때마다 자동으로 빌드·게시)
2. AltStore / Sideloadly / TrollStore / ESign 등으로 설치 — ad-hoc 서명이라 **본인 인증서로 재서명**됩니다
3. **설정 → 앱 → Safari → 확장 프로그램 → YT 리다이렉트** 켜기
   (iOS 17 이하: 설정 → Safari → 확장 프로그램)
4. 권한에서 `youtube.com`, `youtu.be` **허용** (또는 "모든 웹사이트 → 허용")
5. 홈 화면의 **YT 리다이렉트** 앱을 열면 위 과정 안내 + "유튜브 앱 깔려 있는지 확인" / "Safari로 시험 링크 열기" 버튼이 있습니다

> 재서명 도구가 확장(appex) 번들 ID를 바꾸지 않게 두세요. 앱 번들 ID가 `X`면 확장은 `X.extension` 이어야 iOS가 같이 인식합니다(대부분 도구가 자동 처리).
>
> 무료 Apple ID로 재서명하면 7일마다 다시 서명해야 합니다(Cercube와 같음).

### B. iOS / iPadOS — 유저스크립트 (사이드로드 없이)

IPA 설치가 귀찮으면 App Store의 무료 앱 **[Userscripts](https://apps.apple.com/app/userscripts/id1463298887)** 로도 됩니다.

1. App Store에서 **Userscripts** 설치
2. **설정 → (앱 →) Safari → 확장 프로그램 → Userscripts** 켜기 (모든 웹사이트 권한 "허용")
3. Userscripts 앱을 한 번 열어 스크립트 저장 폴더를 지정
4. [`userscript/cercube-youtube-redirect.user.js`](userscript/cercube-youtube-redirect.user.js) 파일 내용을 그 폴더에 넣기
   - 가장 간단: Safari에서 이 레포의 raw 파일을 열면 Userscripts가 "설치" 버튼을 띄워줍니다
   - 또는 Userscripts 앱에서 새 스크립트를 만들어 파일 내용을 붙여넣기
5. 끝. (이 방법은 켜고/끄는 팝업 토글이 없습니다)

### C. IPA를 직접 빌드 (Mac + Xcode)

```bash
brew install xcodegen
cd cercube-youtube-redirect/ios && xcodegen   # YTRedirect.xcodeproj 생성
open YTRedirect.xcodeproj                     # 서명 팀 지정 후 기기로 실행
```

`ios/project.yml` 이 앱 타깃(`YTRedirect`)과 Safari 확장 타깃(`YTRedirectExtension`)을 만들고, 확장에는 이 폴더의 `manifest.json` · `content.js` · `popup.*` · `icons/` 를 **그대로** 묶습니다(크롬/파이어폭스용과 같은 파일).

### D. 데스크톱 Chrome / Edge

1. `chrome://extensions` (Edge는 `edge://extensions`) 열기
2. 우측 상단 **개발자 모드** 켜기
3. **압축해제된 확장 프로그램을 로드합니다** → 이 `cercube-youtube-redirect` 폴더 선택
4. 유튜브 링크를 열면 "유튜브 앱으로 열겠습니까?" 식의 외부 앱 열기 확인이 뜹니다

### E. Firefox (임시 로드)

1. `about:debugging#/runtime/this-firefox` 열기
2. **임시 부가 기능 로드** → 이 폴더의 `manifest.json` 선택

---

## 팝업(툴바 아이콘) 사용법

- **앱으로 바로 열기** 토글: 끄면 리다이렉트를 멈추고 평소대로 웹에서 봅니다. 다시 켜면 복구.
- **지금 이 탭을 앱에서 열기** 버튼: 현재 보고 있는 유튜브 페이지를 수동으로 앱에서 엽니다.
- 설정은 브라우저에 저장돼서 다음에도 유지됩니다.

---

## 리다이렉트하지 않는 것 (일부러 제외)

- `music.youtube.com` — 유튜브 뮤직(별도 앱)이라 제외
- `youtube.com/embed/...` — 다른 사이트에 끼워진 임베드 플레이어는 건드리지 않음
- 라이브 채팅 팝업(`/live_chat`) 등 부가 페이지
- iframe 안에서 열린 유튜브(임베드)는 절대 리다이렉트하지 않음

---

## 파일 구조

```
cercube-youtube-redirect/
├─ manifest.json         # 확장 설정 (Manifest V3, 크로스 브라우저)
├─ content.js            # 핵심: document_start에 youtube:// 로 리다이렉트
├─ popup.html/.css/.js   # 툴바 팝업 (on/off 토글 + 현재 탭 열기)
├─ icons/                # 16/32/48/128 아이콘
├─ userscript/
│  └─ cercube-youtube-redirect.user.js   # iOS Userscripts 앱용 단독 버전
├─ ios/                 # IPA: xcodegen 스펙 + 껍데기 앱(설치 안내) + Safari 확장 핸들러
│  ├─ project.yml
│  ├─ App/              # SwiftUI 안내 화면, 앱 아이콘
│  └─ Extension/        # SafariWebExtensionHandler.swift
└─ README.md
```

---

## 참고 / 한계

- `youtube://` 스킴은 **유튜브 앱이 설치돼 있어야** 동작합니다. 없으면 웹으로 그대로 열립니다.
- Safari는 외부 앱으로 넘어갈 때 한 번 확인창을 띄울 수 있습니다(iOS 정책). "열기"를 누르면 됩니다.
- Chrome 웹스토어 / App Store 정식 등록용이 아니라 **개인용 사이드로드/개발자 로드**를 전제로 만든 확장입니다.
- IPA 빌드는 `.github/workflows/build-ytredirect-ipa.yml` (macOS 러너, 서명 없이 빌드 → ad-hoc 서명 → Releases 게시).
