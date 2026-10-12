# NAGO DL (iOS)

IDM 같은 다운로드 매니저. NAGO VPN과 따로 설치하는 앱이고, 화면은 같은 터미널 테마(`WifiScan/Theme.swift`,
JetBrains Mono)를 쓴다. 아이콘은 VPN의 `>_`를 아래 화살표로 바꾼 `↓_`.

## 기능

- **나눠 받기**: 파일 하나를 연결 여러 개(기본 8, 1~32)로 나눠 동시에 받는다. 연결마다 `URLSession`을
  따로 둬서 HTTP/2 서버여도 TCP 연결이 하나로 합쳐지지 않는다(연결당 속도 제한이 있는 서버에서 빨라지는 이유)
- **동적 분할(IDM 방식)**: 자기 구간을 먼저 끝낸 연결은 가장 많이 남은 구간의 뒤쪽 절반을 가져간다.
  느린 연결 하나 때문에 끝이 늘어지지 않는다
- **이어 받기**: 받은 구간을 기록해 두고 앱을 껐다 켜도 이어서 받는다. `If-Range`로 서버 파일이 바뀌었으면
  처음부터 다시 받는다. 링크가 만료되면 상세 화면에서 새 링크를 넣어 받던 곳부터 이어 받는다
- **오류 처리**: 끊기면 그 구간만 다시(0.5초부터 두 배씩, 30초 상한). 서버가 연결이 많다고(429/503/403)
  하면 연결 수를 줄인다. Range를 안 받는 서버는 연결 하나로
- **m3u8(HLS) 동영상**: 화질을 고르면 조각을 여러 개 동시에 받아 **MP4 하나로 합친다**. 다시 인코딩하지 않아서
  화질 그대로. MPEG-TS(H.264 + AAC), fMP4(CMAF), 오디오만 따로 있는 재생 목록, ADTS(.aac) 조각을 지원.
  광고 등으로 시각이 끊긴 곳(`#EXT-X-DISCONTINUITY`)은 앞 조각 끝에 이어 붙인다.
  모르는 코덱(HEVC TS 등)이면 조각을 이어 붙인 `.ts`로 남긴다(VLC에서 재생). **DRM/암호화(AES-128 포함)와
  라이브 방송은 받지 않는다**
- **앱 안 브라우저**: 다운로드 링크를 누르면 가로채서 여러 연결로 받는다(그 사이트 쿠키·User-Agent·Referer를
  그대로 실어서 로그인이 필요한 파일도 된다). 페이지가 재생하는 동영상(mp4/m3u8)을 찾아 `film` 단추에 모아 두고,
  `link` 단추로 페이지의 파일 링크를 골라 한꺼번에 받는다. blob:/POST 다운로드는 WebKit이 직접 받는다
- **백그라운드**: 앱이 화면에서 내려가기 직전(비활성 상태)에 남은 구간을 32MB 안팎으로 잘라 백그라운드
  `URLSession`에 넘긴다. 앱이 꺼져 있어도 시스템이 받고, 끝나면 앱을 깨워 파일에 채워 넣는다. 앱으로 돌아오면
  아직 시작 안 한 작업은 취소하고 그 구간을 다시 여러 연결로 받는다(시작한 작업은 끝까지 둔다).
  다 받으면 알림
- **공유 메뉴 → NAGO DL**: 사파리 등에서 공유 → NAGO DL을 누르면 앱이 열리며 바로 받는다.
  웹 페이지 주소면 브라우저로 열어 동영상을 찾는다
- **클립보드**: 링크를 복사하고 앱을 열면 붙여넣기 단추가 뜬다(내용은 단추를 누를 때만 읽어서 허용 창이 안 뜬다)
- 받은 파일은 **파일 앱 → 나의 iPhone → NAGO DL**. 목록에서 길게 눌러 열기·공유·사진 앱에 저장

## 구조

| 경로 | 내용 |
| --- | --- |
| `Core/` | 엔진(SwiftPM `NagoDLCore`, UI 없음). 리눅스/맥에서 `swift test` |
| `Core/.../FileRunner.swift` | 파일 하나: 첫 연결로 크기·Range 확인, 구간 나누기, 재시도 |
| `Core/.../SegmentPlanner.swift` | 동적 분할, 구간 합치기, 백그라운드용 자르기 |
| `Core/.../HTTPChannel.swift` | 연결 하나 = URLSession 하나 |
| `Core/.../DownloadManager.swift` | 목록·대기열·저장(JSON)·백그라운드 넘기기 API |
| `Core/.../M3U8.swift`, `HLSRunner.swift` | 재생 목록 해석, 조각 병렬 다운로드 |
| `Core/.../TSDemuxer.swift`, `TSRemuxer.swift`, `MP4Writer.swift`, `FMP4Remuxer.swift` | TS/fMP4 → MP4 |
| `App/` | SwiftUI 화면, 브라우저(WKWebView), 백그라운드 세션 |
| `Share/` | 공유 확장 |
| `tools/testserver.py` | 시험 서버(Range, 연결당 속도 제한, 끊기, 503, 리다이렉트, chunked, ETag 변경, 정적 파일) |

## 시험

```sh
python3 NagoDL/tools/testserver.py --port 8711 --root /tmp/srv &
NAGODL_TEST_SERVER=http://127.0.0.1:8711 NAGODL_TEST_ROOT=/tmp/srv swift test --package-path NagoDL/Core
```

시험 서버가 없으면 통합 시험은 건너뛰고, ffmpeg가 없으면 변환 시험도 건너뛴다(CI는 단위 시험만).
변환 시험은 ffmpeg로 HLS를 만들어 MP4로 옮긴 뒤 **디코딩한 프레임 해시가 원본과 같은지**, 영상/음성 시작 시각
차이(싱크)가 같은지 본다.

## 빌드

```sh
cd NagoDL && xcodegen
xcodebuild -project NagoDL.xcodeproj -scheme NagoDL -configuration Release -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO build
```

CI는 `.github/workflows/build-dl-ipa.yml`(이 폴더가 바뀌면 돈다) → 서명 안 된 IPA를 `nagodl-N` 프리릴리스로
올린다. 재서명할 때 공유 확장(`.share`)도 같이 서명돼야 한다. 특별한 권한(entitlement)은 필요 없다.
