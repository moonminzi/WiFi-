# 스캔툴 (iOS)

탭 세 개짜리 아이폰 앱.

| 탭 | 하는 일 |
|---|---|
| **와이파이** | 와이파이 안내 종이를 찍으면 ID/PW를 읽어서 바로 연결. 손글씨에서 헷갈리는 글자(0/O/D, 1/l/I, 5/S…)는 눌러서 고칠 수 있음 |
| **계좌번호** | 단톡방 캡처·공지 사진·복사한 글에서 은행과 계좌번호(+예금주)를 찾아 복사, QR, 토스·카카오뱅크로 열기 |
| **QR 공유** | 파일·사진·동영상을 내 Cloudflare에 올려 링크를 QR로 / 와이파이 QR(카메라로 찍으면 바로 연결) / 텍스트·링크 QR |

- 글자 인식은 Apple Vision으로 기기 안에서 처리 (사진이 밖으로 안 나감)
- 와이파이 연결은 `NEHotspotConfiguration` → "연결하시겠습니까?" 한 번이면 접속, 실제로 붙었는지 확인까지 함

## IPA 받기

`main`에 푸시하면 GitHub Actions(macOS)가 **서명 안 된 IPA**를 만들어 [Releases](../../releases)에 올림.
설치하려면 본인 인증서로 다시 서명해야 함:

1. developer.apple.com → Identifiers에서 App ID 만들기. **Hotspot**과 **Access Wi-Fi Information**을 꼭 체크
2. Devices에 아이폰 UDID 등록
3. Profiles에서 그 App ID + 아이폰으로 Development 또는 Ad Hoc 프로파일 만들기
4. `.p12` + 프로파일로 IPA 서명 후 설치 (Feather·ESign·KSign, 또는 `zsign`)

Xcode로 직접 빌드하려면: `brew install xcodegen && xcodegen && open WifiScan.xcodeproj`
(project.yml의 `DEVELOPMENT_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER` 수정)

## 파일 공유 서버 (Cloudflare Worker)

`worker/` 폴더. 파일은 Workers KV에 20MB 조각으로 저장되고, 고른 기간(1시간 / 1일 / 7일)이 지나면 KV가 알아서 지움.
카드 등록이 필요 없는 무료 플랜으로 됨 (파일당 100MB까지, KV 무료 한도: 저장 1GB, 쓰기 하루 1,000번).

### 배포 (처음 한 번)

1. Cloudflare 대시보드 → **Workers & Pages** → **Create** → **Import a repository**
2. GitHub에서 `moonminzi/WiFi-` 선택
3. 프로젝트 이름은 반드시 **`qr-share`** (wrangler.jsonc의 `name`과 같아야 함)
4. **Advanced settings → Root directory**에 **`worker`** 입력 후 배포
5. 배포가 끝나면 Worker의 **Settings → Variables and Secrets → Add**
   - Type: **Secret**, Name: **`UPLOAD_TOKEN`**, Value: 아무 긴 비밀번호
6. 앱의 **QR 공유 → 오른쪽 위 톱니바퀴**에
   - Worker 주소: `qr-share.<내 서브도메인>.workers.dev`
   - 업로드 비밀번호: 5번에서 넣은 값
   - **연결 테스트**가 초록색이면 끝

이후 `worker/`를 고쳐서 `main`에 푸시하면 Cloudflare가 자동으로 다시 배포함.

### API

| 요청 | 설명 |
|---|---|
| `GET /ping` | 비밀번호 확인 (Authorization: Bearer) |
| `PUT /upload?name=&hours=` | 파일 올리기 → `{ id, url, expiresAt, size }` |
| `GET /f/:id` | 받는 사람용 안내 페이지 (이미지는 미리보기) |
| `GET /f/:id/download` | 파일 내려받기 |
| `DELETE /f/:id` | 공유 중지 (Authorization 필요) |
