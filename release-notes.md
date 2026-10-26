NAGO VPN 안드로이드 2.0.0 — `nago-release` 키로 서명한 release APK(`com.nago.vpn`). 이미 깔린 1.x 앱 위에 지우지 않고 덮어 설치된다.

- 서명 인증서 SHA-256: `39:B6:BC:E6:C6:79:65:34:93:1C:E2:7B:53:5E:2F:C4:52:92:94:CB:96:B7:9D:6D:78:C8:0A:87:FB:CF:3A:DB`
- 비밀번호는 내장돼 있지 않다 → settings → account에서 입력

**바뀐 것**
- iOS와 같은 지도 중심 화면: route 지도(웨이포인트·확대·신호 고리), secured 알약, 콘솔(연결 시간·단계 막대·출구 IP·속도 그래프·핸드셰이크), 지역 카드(실측 왕복 시간·fast), boot log, 갈아타기(hop)
- 다크 / 라이트 / 시스템 (settings → appearance)
- 햅틱: 나라 선택·단계마다·연결됨·실패
- **neptun 강제 종료 고침**: 망 전환 감시에 필요한 권한(ACCESS_NETWORK_STATE)이 빠져 엔진이 뜬 직후 앱이 죽던 것
- 앱이 죽으면 이유가 settings → logs에 남는다
