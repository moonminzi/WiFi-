# nago-agent

VPN 안쪽에서만 닿는 작은 HTTP 서버(`10.53.53.53:8053`, 표준 라이브러리 파이썬 하나). 앱이 터널 안에서 묻고,
서버는 요청의 출발 주소(터널 주소)로 누구인지 안다 — 로그인이 없고 남의 기록은 볼 수 없다.

| 경로 | 하는 일 |
|---|---|
| `GET /v1/me` | 오늘(KST) DNS 조회·차단 수, 많이 막힌 도메인, 지금 출구, 집 출구 목록 |
| `GET /v1/feed?after=N` | 실시간 도메인 흐름(최근 300개) |
| `POST /v1/exit {"via": "server" \| "h240"}` | 출구 바꾸기(wg 주소만 — IKEv2 주소는 연결마다 바뀜) |
| `POST /v1/home {"name": "…"}` / `{"off": true}` | 집 노드가 자기를 출구로 알림 / 내림 |

- **DNS**: 광고 차단 dnsmasq가 질의 기록을 `/run/nago-dns/queries.log`(tmpfs)에만 쓰고, 에이전트가 읽으며 비운다.
  사람별 숫자는 메모리에만(재시작하면 0). 디스크·journald에 도메인이 남지 않는다.
- **집 출구**: 집 노드(`server/home/nago-home.sh`)는 이 서버의 보통 wg 피어다. 에이전트가 그 피어와 wg 안쪽
  IP-in-IP(`nagoh<n>`)를 만들고, 그 집을 고른 사람의 출발 주소만 정책 라우팅(`ip rule … priority 5000`, 표 2000+n)으로
  넘긴다. TCP 가속(NAGO_ACCEL)은 그 사람만 건너뛴다(서버 프록시가 대신 연결하면 서버 IP로 나가서). 핸드셰이크가 3분 넘게
  없으면 규칙을 빼서 서버로 나가게 하고, 다시 붙으면 다시 건다(15초마다 맞춤). 새 포트는 열지 않는다.
- 상태(집 목록·출구 선택): `/var/lib/nago-agent/state.json`

설치: 광고 차단(`server/adblock/setup-adblock.sh`) 다음에 `sudo bash setup-agent.sh`(같은 폴더의 nago-agent.py를 깖).
