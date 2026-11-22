NAGO VPN iOS 2.1.10

**2.1.10**
- **광고 차단 강도 `extreme`** — settings → `// adblock`에서 `light` · `normal` · `strict` · `extreme`.
  extreme = strict + 아래 전부:
  - HaGeZi **Ultimate**(가장 공격적인 광고·추적 목록)
  - **위협 목록**(HaGeZi TIF medium: 악성코드·피싱·사기 사이트)
  - **DNS 우회 차단** — 앱·브라우저가 자기 암호화 DNS(DoH)나 우회 서비스로 빠져나가 차단을 피하는 것
  - **숨은 추적기 잡기(CNAME)** — `metrics.사이트.com`처럼 사이트 하위 이름으로 위장해도, 실제 목적지가 추적기면 막는다.
    live에 `cname`이 붙은 줄이 이것
- **많이 깨진다** — 쇼핑·제휴 링크, 검색 광고 링크, 일부 로그인·결제·앱 기능. 막히면 live에서 꾹 눌러 `allow for me`
- normal 목록에 팝업·리다이렉트 광고(HaGeZi Pop-Up Ads)가 들어갔다(서버만 바뀜, 모든 앱에 적용)
- **서버가 새 nago-agent여야 extreme이 듣는다**(예전 서버는 normal로 막음)
