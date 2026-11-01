NAGO VPN iOS 2.1.9

**2.1.9**
- **광고 차단 강도** — settings → `// adblock`(`--adblock`을 켜면 보임)에서 `light` · `normal` · `strict`.
  - light: 광고만(OISD small) — 깨지는 사이트가 가장 적다
  - normal: 광고 + 추적 + 한국 광고(OISD big + YousList) — 지금까지와 같음, 기본값
  - strict: normal + 추적을 더(HaGeZi Pro++) — 몇몇 사이트가 깨질 수 있다
- **내 규칙** — 도메인을 나만 막기(✗) · 나만 풀기(✓). settings에서 넣거나, live 화면에서 도메인을 꾹 눌러
  `block for me` · `allow for me` · `remove my rule`. live에서 내 규칙으로 막힌 줄에는 `mine`이 붙는다
- 강도·규칙은 **이 폰에만** 적용된다 — 같은 서버의 다른 사람은 그대로. 연결 중에 바꿔도 바로(다음 조회부터) 바뀌고,
  폰에 저장돼 있어서 다른 서버에 붙거나 서버가 다시 켜져도 저절로 다시 맞춘다
- `// adblock` 패널 아래에 지금 강도가 보인다(`today kst · strict +3 rules · …`)
- 예전 앱(2.1.8 이하)·안드로이드는 그대로 normal로 막힌다. 피어를 다시 설정할 필요 없다
- **서버가 새 nago-agent여야 한다**(`server/agent/setup-agent.sh` — 서버 DNS를 에이전트가 직접 받는 구조로 바뀜)
