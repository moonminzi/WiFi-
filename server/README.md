# NAGO VPN 서버 (Vultr)

앱의 **vpn 탭**이 붙는 IKEv2/EAP-MSCHAPv2(strongSwan) + WireGuard 고정 서버 2대(서울·도쿄)와 임시 서버 나라들,
국가 API·대시보드·피어 관리를 맡는 **컨트롤 서버**(서울 서버 안)로 되어 있습니다.
2026-11에 AWS(EC2 + Lambda + API Gateway + SSM + CloudWatch)에서 Vultr로 옮겼습니다.

```
앱 ──HTTPS──▶ 서울 컨트롤 서버(Caddy → app.py) ──SSH──▶ jp (+ 임시 서버)
 │              /region, /?format=json, POST /
 └─UDP 500/4500(IKEv2), UDP 443(WireGuard)──▶ 고른 나라 서버 ──NAT──▶ 인터넷
```

| AWS 때 | 지금 |
|---|---|
| EC2 4대, 해외는 30분 유휴 시 자동 중지 | Vultr 고정 2대(kr/jp) **항상 켜 둠**(Vultr는 꺼 둬도 요금이 나감). us/uk 등 나머지는 고를 때 만드는 임시 서버 |
| 국가 API Lambda(`region-api`) + 대시보드 Lambda(`dashboard`) | 서울 서버의 `control/app.py` 하나(응답 모양은 같음) |
| SSM RunCommand | SSH(서울 → 다른 서버, `/etc/nago/id_ed25519`) |
| SSM 파라미터 `/nago/wg/peers`, `/nago/wg/servers` | `/var/lib/nago/wg-peers.json`, `wg-servers.json` |
| CloudWatch NetworkOut | 서버마다 `nago-netout` 타이머(5분)가 남기는 `/var/lib/nago/netout` |
| API Gateway HTTPS | Caddy + Let's Encrypt **IP 주소 인증서**(도메인 없어도 됨, 약 6일마다 자동 갱신) |

## 서버

| 코드 | 지역 | Vultr region | 서버 ID (인증서 SAN) |
|---|---|---|---|
| kr | 🇰🇷 서울 | `icn` | 서울 공인 IP (앱·윈도우가 IP로 붙음) |
| jp | 🇯🇵 도쿄 | `nrt` | `jp.nago.vpn` |

미국(`sea`)·영국(`lhr`)은 2026-11부터 고정 서버 대신 임시 서버 나라다(아래 "임시 서버 나라").

- 프로토콜: IKEv2 + EAP-MSCHAPv2(사용자 `wifiscan`), WireGuard 10.9.0.0/24(udp 443 → 51820)
- 인증서는 **NAGO VPN Root CA**(`ca-cert.pem`, 2026-11 새로 만듦)로 서명. 예전 WifiScan VPN Root CA의 키는
  AWS 서버와 함께 사라져서, 아이폰은 새 `WifiScanVPN.mobileconfig` 설치 + 신뢰가 한 번 필요하다
  (안드로이드·윈도우는 앱에 들어 있음). CA 개인키는 레포 밖에 두고 따로 백업한다
- **CA 개인키와 VPN 비밀번호는 이 저장소에 두지 않습니다.** 공개해도 되는 CA 인증서와 mobileconfig만 있음

## 처음부터 세우기

### 1. Vultr 서버 2대 + 방화벽 그룹

윈도우 PowerShell에서(`server/vultr/provision.ps1`):

```powershell
$env:VULTR_API_KEY = '<Vultr API 키>'   # Account → API. 내 IP를 Access Control에 추가해야 API가 됨
.\server\vultr\provision.ps1 -SshPublicKey "$HOME\.ssh\id_ed25519.pub" -WhatIf   # 먼저 확인만
.\server\vultr\provision.ps1 -SshPublicKey "$HOME\.ssh\id_ed25519.pub"
```

- Ubuntu 22.04, 라벨 `nago-kr` 등. 같은 라벨이 있으면 건너뛴다. 플랜/지역은 스크립트 위쪽 `$Nodes`
- 방화벽 그룹 `nago-vpn`: udp 500/4500/51820/443, tcp 22/80/443, icmp
- 콘솔에서 직접 만들어도 된다(위 포트를 연 방화벽 그룹을 붙이면 됨)
- Vultr 우분투 이미지는 **ufw가 켜져 있어서** VPN이 막힌다. `setup-region.sh`가 알아서 끈다

### 2. 서버 인증서 번들 (내 PC, CA 키가 있는 곳)

Git Bash에서(`server/make-bundle.sh`). 서울은 ID가 IP라 서버를 만든 뒤에 한다.

```bash
export VPN_EAP_USER=wifiscan VPN_EAP_PASS='<VPN 비밀번호>'
./server/make-bundle.sh ca-cert.pem ca-key.pem 141.164.x.x      # 서울: ID = 서울 공인 IP
./server/make-bundle.sh ca-cert.pem ca-key.pem jp.nago.vpn
```

해외 서버는 예전 AWS 서버의 번들(같은 FQDN)을 그대로 써도 된다.

### 3. 서버마다 (kr/jp)

```bash
scp -r server bundle-<id> root@<서버 IP>:/root/
ssh root@<서버 IP>
cd /root/server
./setup-region.sh /root/bundle-<id>     # strongSwan, BBR, 가속, 송신량 기록
./wireguard/setup-wg.sh                 # WireGuard (마지막 줄 WGPUB = 서버 공개키)
./adblock/setup-adblock.sh              # 광고 차단 DNS (--adblock)
./agent/setup-agent.sh                  # nago-agent(사람별 광고 차단·통계·집 출구), adblock 다음에
./nagoing/setup-nagoing.sh              # nagoing 프록시(TCP 443 TLS · UDP 51821), Rust 빌드라 몇 분 걸림
rm -rf /root/bundle-<id>                # 번들엔 비밀번호와 서버 개인키가 있음
```

- 옛 서버의 WireGuard 키를 그대로 쓰고 싶으면 `setup-wg.sh` 전에 옛 `/etc/wireguard/wg0.conf`를 복사해 둔다.
  그러면 친구들 WireGuard 앱 `.conf`는 `Endpoint`만 바꾸면 된다(안 그러면 새 `.conf`를 다시 보내야 함)

### 4. 서울에 컨트롤 서버

```bash
cd /root/server/control
NAGO_KEY='<VPN 비밀번호>' ./setup-control.sh          # IP 주소로 HTTPS, 포트 8443
# 도메인이 있으면: NAGO_KEY=... DOMAIN=vpn.example.com ./setup-control.sh
```

API는 **TCP 8443**이다(443은 nagoing 프록시). 인증서는 Let's Encrypt IP 인증서를 80번(http-01)으로 받는다.

1. `/etc/nago/control.json`의 jp `addr`(서버 IP)를 채운다. 아직 안 만든 서버는 nodes에서 빼 둔다
   (자리표시 주소가 앱에 그대로 나감). `vultr_id`, `vultr_api_key`를 넣으면 대시보드에서 켜기/끄기/재부팅과
   정확한 상태·생성 시각을 쓴다. **임시 서버 나라는 `vultr_api_key`가 있어야 된다**(서울 IP를 Vultr API
   Access Control에 추가). `ondemand.firewall_group_id`에 `nago-vpn` 그룹 ID를 넣는다.
   API 키 없이 쓸 때는 서버마다 `"created": "2026-11-22T14:20:25+00:00"`(Vultr의 date_created)를 넣어야
   첫 달 비용이 1일부터로 부풀지 않는다. `monthly_usd`, `bandwidth_gb`는 Vultr 가격표 값으로
2. 마지막에 출력된 SSH 공개키를 jp의 `/root/.ssh/authorized_keys`에 넣는다
3. `systemctl restart nago-control` 후 확인:
   ```bash
   curl -s -H "x-nago-key: <VPN 비밀번호>" https://<서울 IP>:8443/region?r=jp
   curl -s -H "x-nago-key: <VPN 비밀번호>" "https://<서울 IP>:8443/?format=json" | head -c 400
   ```

### 5. AWS에서 피어 목록 옮기기 (한 번)

AWS가 아직 살아 있을 때 피어 목록(공개키·이름)을 받아 서울에 넣는다.

```bash
aws ssm get-parameter --region ap-northeast-2 --name /nago/wg/peers \
  --query Parameter.Value --output text > wg-peers.json
scp wg-peers.json root@<서울 IP>:/var/lib/nago/wg-peers.json
ssh root@<서울 IP> 'chmod 600 /var/lib/nago/wg-peers.json && systemctl restart nago-control'
```

국가 API로 서버에 한 번씩 붙거나(5분에 한 번 sync), dash 탭에서 피어 하나를 바꾸면 고정 서버 모두에 반영된다(임시 서버는 만들 때 피어 목록을 받는다).

### 6. 앱 주소 바꾸기

| 파일 | 바꿀 것 |
|---|---|
| `WifiScan/VPNRegion.swift` | `RegionAPI.endpoint` → `https://<서울 IP>:8443/region`, kr `fallback` IP |
| `WifiScan/DashView.swift` | `DashAPI.endpoint` → `https://<서울 IP>:8443/?format=json` |
| `android/.../Regions.kt` | `ENDPOINT`, kr `fallback` IP |
| `android/.../WgVpn.kt` | `DASH` |
| `windows/NagoVpn.ps1` | `$Server` |
| `server/home/nago-home.sh` | `DASH` |

### 7. AWS 정리 (새 앱이 다 깔린 뒤)

EC2 인스턴스 4대 종료, EIP 해제(`3.38.243.135`), Lambda `nago-dash`·국가 API 함수와 API Gateway,
SSM 파라미터 `/nago/wg/*`, CloudWatch 경보, (CloudFormation으로 만들었다면) 스택 삭제.
AWS 시절 파일(`cloudformation.yaml`, `dashboard/index.py`, `region-api/index.py`)은 git 기록에 남아 있다.

## 상태 확인 / 문제 해결

```bash
# 아무 서버에서
sudo ipsec statusall                   # IKEv2 데몬/연결
sudo wg show                           # WireGuard
journalctl -u strongswan-starter -f    # 핸드셰이크 로그
tail -3 /var/lib/nago/netout           # 송신량 기록(시각 바이트)

# 서울(컨트롤 서버)
journalctl -u nago-control -f          # API 요청·SSH 실패
journalctl -u caddy -f                 # 인증서 발급·갱신
```

연결이 안 될 때 자주 보는 원인
- 기기에서 **CA 신뢰**를 안 켬 → "서버 인증서를 신뢰할 수 없음"
- ufw가 켜져 있음(`ufw status`) 또는 Vultr 방화벽 그룹에서 **UDP 500/4500/443**이 막힘
- 대시보드에서 서버가 `ssh: no answer` → 그 서버의 `authorized_keys`에 컨트롤 서버 키가 없음

## 임시 서버 나라 (만들고 지우기)

가끔만 필요한 나라는 서버를 미리 두지 않고, 고를 때 만들어서 안 쓰면 지운다. 안 쓰는 동안 드는 돈이 없다.

| 코드 | 나라 | Vultr 지역 |
|---|---|---|
| `us` | 미국(시애틀) | `sea` |
| `uk` | 영국(런던) | `lhr` |
| `sg` | 싱가포르 | `sgp` |
| `de` | 독일(프랑크푸르트) | `fra` |
| `fr` | 프랑스(파리) | `cdg` |
| `se` | 스웨덴(스톡홀름) | `sto` |
| `ca` | 캐나다(**토론토**, AWS 때는 몬트리올) | `yto` |
| `br` | 브라질(상파울루) | `sao` |
| `au` | 호주(시드니) | `syd` |
| `in` | 인도(뭄바이) | `bom` |

아일랜드(`ie`)는 Vultr에 지역이 없어 빠졌다. 앱은 칸을 숨긴다(지도 점 번호가 밀리지 않게 목록에는 남김).

- 컨트롤 서버(`control/app.py`)가 `GET /region?r=sg`에 떠 있는 서버가 없으면 Vultr API로 새로 만든다.
  Ubuntu 24.04 x64, `vc2-1c-1gb`, 라벨 `nago-od-<코드>`, 방화벽 그룹 `nago-vpn`(`ondemand.firewall_group_id`).
  만들 때 `state: "creating"`, WireGuard가 올라오면 `ready: true` — 서버가 `/var/log/nago-ondemand.log`에 남기는
  `NAGO_WG_READY`를 SSH로 본다(못 읽어도 만든 지 4분이 지나면 준비로). Vultr는 만드는 데 1~2분 걸린다.
- **WireGuard를 먼저** 올린다. 패키지 없이 커널 wireguard + systemd-networkd로(user-data 한 번). 서버 키는 컨트롤 서버가
  만들어 user-data로 넘기고 공개키는 `/var/lib/nago/ondemand.json`에 둔다. 피어는 만들 때의 `wg-peers.json`
  (만든 뒤 새로 등록한 기기는 다음 서버부터). user-data가 Vultr 이미지의 ufw를 끄고 컨트롤 서버 SSH 키를 넣는다.
- **TCP 분할 가속**·**광고 차단 DNS + nago-agent**는 그 뒤에 백그라운드로 깐다(고정 서버와 같은 방식). 에이전트 파일은
  깃허브 대신 컨트롤 서버(`https://<서울 IP>:8443/agent/…`)에서 받는다. 다 깔릴 때까지 10.53.53.53은 1.1.1.1로 넘겨 둔다.
- **지우기**: AWS처럼 "꺼지면 지워짐"이 Vultr에는 없고, 꺼 둬도 요금이 나간다. 그래서 컨트롤 서버의 정리 스레드가 1분마다
  임시 서버의 유휴 카운터(분당 송신 300KB 미만인 분, 서버의 `nago-idle` 타이머)를 SSH로 읽어 **30분 유휴면 지운다**.
  **24시간**이 지나도 지우고, 30분이 지났는데 SSH가 10번 연달아 안 되면(멎은 서버) 지운다.
  컨트롤 서버가 멈춰 있으면 안 지워지니 주의(대시보드에 떠 있는 게 보인다).
- **대시보드**: 지금 떠 있거나 이번 달에 쓴 임시 서버 나라가 `onDemand: true`로 붙는다. 이번 달 사용량은
  `/var/lib/nago/ondemand-usage.json`(만든 때·지운 때·송신 바이트)에서 센다. `POST {op: "drop", node: "sg"}`로 바로 지운다.
- **동시에 2대까지**(`ondemand.max`). 넘으면 409.
- 비용: `vc2-1c-1gb` 시간당 $0.007 + 송신(계정 대역폭 풀 안이면 0). 안 쓰면 0원.
- 나라 추가: `control.json`의 `ondemand.regions`(`{"sg": {"region": "sgp", "city": "singapore"}}`)와 앱 `VPNRegion`에 넣는다.

## NAGO signer (IPA 서명 → Safari에서 바로 설치)

컴퓨터 없이 아이폰·아이패드 Safari만으로 IPA를 내 인증서로 서명해서 설치한다. 2026-11에 AWS
(Lambda `nago-sign` + S3 + Secrets Manager + CloudFront)에서 서울 서버로 옮겼다.

- 주소: `https://<서울 IP>:8443/sign/?t=<대시보드 토큰>` (토큰은 `/etc/nago/control.json`의 `token`)
- 페이지: 인증서·프로파일 요약(여러 개면 골라서), 저장소들(`GH_REPO`, 기본 WiFi- · Nintendo-2)의 최근 릴리스 IPA,
  IPA 주소, 파일 올리기. `sign`을 누르면 서버에서 백그라운드로 서명하고(창을 닫아도 됨) **설치** 버튼(itms-services)이 생긴다
- 서명: `rcodesign`(apple-codesign 0.29.0, musl 정적). 앱이 원래 요청한 엔타이틀먼트 중 프로파일이 허락하는 것만 남기고,
  앱 ID·팀·키체인 그룹은 프로파일에 맞춘다. 번들 ID `profile`(프로파일 앱 ID로) / `keep`(그대로)
- 링크(설치·IPA·업로드)는 경로+만료에 HMAC 서명(1시간). 서명본·올린 파일·작업 기록은 `/var/lib/nago-sign`에서 하루 뒤 지운다
- 한 번에 하나씩 서명한다(나머지는 대기). 서명 프로세스는 `Nice=10`이라 VPN 트래픽이 먼저

| 위치 (서울 서버) | 내용 |
|---|---|
| `/opt/nago-sign/signer.py`, `bin/rcodesign` | 서버(127.0.0.1:8090), systemd `nago-sign`. Caddy가 `/sign*`를 넘긴다 |
| `/etc/nago/sign/certs/<번호>-<이름>.json` | 인증서마다 `{"p12": base64, "password": "…", "profile": base64}` (700/600, 레포에 넣지 않음). 번호 순서 = 페이지 순서 |
| `/var/lib/nago-sign/{signed,uploads,jobs}` | 서명본 · 올린 파일 · 진행 상황 |

설치·갱신:

```bash
cd /root/server/control && ./setup-control.sh     # Caddyfile에 /sign 경로(한 번)
cd /root/server/signer && ./setup-signer.sh       # rcodesign이 없으면 cargo로 빌드(몇 분), RCODESIGN_BIN=파일 로 줄 수도 있음
```

인증서 추가·교체는 위 json 파일을 넣거나 바꾸면 끝(서버 재시작 필요 없음).
p12는 **옛(legacy) 형식**이어야 한다(키체인에서 내보낸 Apple p12는 그렇다). OpenSSL 3로 만들면 `-legacy`를 붙인다.

## 포함된 파일

| 파일 | 설명 |
|---|---|
| `ca-cert.pem` / `WifiScanVPN.mobileconfig` | 루트 CA 인증서(공개)와 아이폰에 설치·신뢰시키는 프로파일 |
| `make-bundle.sh` | 기존 CA로 서버 인증서 번들을 만든다(내 PC) |
| `setup-region.sh` | IKEv2 서버 구성(고정 서버 공통) + 송신량 기록 |
| `wireguard/setup-wg.sh` | WireGuard 구성 |
| `adblock/setup-adblock.sh` | 광고 차단 DNS |
| `agent/` | nago-agent(사람별 광고 차단·통계·실시간 도메인·집 출구), `setup-agent.sh` |
| `nagoing/setup-nagoing.sh` | nagoing 프록시(막힌 망 우회, TCP 443 · UDP 51821) |
| `home/nago-home.sh` | 친구 집 PC를 출구로 쓰는 노드 |
| `control/` | 컨트롤 서버: `app.py`(국가 API·임시 서버·대시보드), `nago-peer.py`(서버에서 도는 피어 관리), `setup-control.sh`, `control.example.json` |
| `signer/` | NAGO signer: `signer.py`(IPA 서명·OTA 설치 서버), `setup-signer.sh` |
| `vultr/provision.ps1` | Vultr 서버·방화벽 그룹 만들기 |
| `setup-strongswan.sh` | (옛) CA까지 새로 만드는 단일 서버 스크립트 |

## 비용

- 고정은 서울 vc2-2c-4gb + 도쿄 vc2-1c-2gb, 나머지 나라는 쓸 때만 임시 서버. 정확한 값은 Vultr 가격표 기준이고 대시보드 `cost`가 매달 어림한다
- 포함 대역폭은 계정의 서버들끼리 합쳐 쓰고(풀), 넘으면 GB당 과금
- 서버를 지우면(Destroy) 요금이 멈춘다. 꺼 두기(Stop)는 요금이 그대로 나간다
