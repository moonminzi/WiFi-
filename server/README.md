# NAGO VPN 서버 (Vultr)

앱의 **vpn 탭**이 붙는 IKEv2/EAP-MSCHAPv2(strongSwan) + WireGuard 서버 4대와,
국가 API·대시보드·피어 관리를 맡는 **컨트롤 서버**(서울 서버 안)로 되어 있습니다.
2026-11에 AWS(EC2 + Lambda + API Gateway + SSM + CloudWatch)에서 Vultr로 옮겼습니다.

```
앱 ──HTTPS──▶ 서울 컨트롤 서버(Caddy → app.py) ──SSH──▶ jp/us/uk
 │              /region, /?format=json, POST /
 └─UDP 500/4500(IKEv2), UDP 443(WireGuard)──▶ 고른 나라 서버 ──NAT──▶ 인터넷
```

| AWS 때 | 지금 |
|---|---|
| EC2 4대, 해외는 30분 유휴 시 자동 중지 | Vultr 4대, **항상 켜 둠**(Vultr는 꺼 둬도 요금이 나감) |
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
| us | 🇺🇸 시애틀 | `sea` | `us.nago.vpn` |
| uk | 🇬🇧 런던 | `lhr` | `uk.nago.vpn` |

- 프로토콜: IKEv2 + EAP-MSCHAPv2(사용자 `wifiscan`), WireGuard 10.9.0.0/24(udp 443 → 51820)
- 인증서는 **NAGO VPN Root CA**(`ca-cert.pem`, 2026-11 새로 만듦)로 서명. 예전 WifiScan VPN Root CA의 키는
  AWS 서버와 함께 사라져서, 아이폰은 새 `WifiScanVPN.mobileconfig` 설치 + 신뢰가 한 번 필요하다
  (안드로이드·윈도우는 앱에 들어 있음). CA 개인키는 레포 밖에 두고 따로 백업한다
- **CA 개인키와 VPN 비밀번호는 이 저장소에 두지 않습니다.** 공개해도 되는 CA 인증서와 mobileconfig만 있음

## 처음부터 세우기

### 1. Vultr 서버 4대 + 방화벽 그룹

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
./server/make-bundle.sh ca-cert.pem ca-key.pem us.nago.vpn
./server/make-bundle.sh ca-cert.pem ca-key.pem uk.nago.vpn
```

해외 서버는 예전 AWS 서버의 번들(같은 FQDN)을 그대로 써도 된다.

### 3. 서버마다 (4대 모두)

```bash
scp -r server bundle-<id> root@<서버 IP>:/root/
ssh root@<서버 IP>
cd /root/server
./setup-region.sh /root/bundle-<id>     # strongSwan, BBR, 가속, 송신량 기록
./wireguard/setup-wg.sh                 # WireGuard (마지막 줄 WGPUB = 서버 공개키)
./adblock/setup-adblock.sh              # 광고 차단 DNS (--adblock)
rm -rf /root/bundle-<id>                # 번들엔 비밀번호와 서버 개인키가 있음
```

- 옛 서버의 WireGuard 키를 그대로 쓰고 싶으면 `setup-wg.sh` 전에 옛 `/etc/wireguard/wg0.conf`를 복사해 둔다.
  그러면 친구들 WireGuard 앱 `.conf`는 `Endpoint`만 바꾸면 된다(안 그러면 새 `.conf`를 다시 보내야 함)

### 4. 서울에 컨트롤 서버

```bash
cd /root/server/control
NAGO_KEY='<VPN 비밀번호>' ./setup-control.sh          # IP 주소로 HTTPS
# 도메인이 있으면: NAGO_KEY=... DOMAIN=vpn.example.com ./setup-control.sh
```

1. `/etc/nago/control.json`의 jp/us/uk `addr`(서버 IP)를 채운다. 아직 안 만든 서버는 nodes에서 빼 둔다
   (자리표시 주소가 앱에 그대로 나감). `vultr_id`, `vultr_api_key`를 넣으면 대시보드에서 켜기/끄기/재부팅과
   정확한 상태·생성 시각을 쓴다(없어도 동작. API 키를 쓰면 서울 IP를 Vultr API Access Control에 추가).
   API 키 없이 쓸 때는 서버마다 `"created": "2026-11-22T14:20:25+00:00"`(Vultr의 date_created)를 넣어야
   첫 달 비용이 1일부터로 부풀지 않는다. `monthly_usd`, `bandwidth_gb`는 Vultr 가격표 값으로
2. 마지막에 출력된 SSH 공개키를 jp/us/uk의 `/root/.ssh/authorized_keys`에 넣는다
3. `systemctl restart nago-control` 후 확인:
   ```bash
   curl -s -H "x-nago-key: <VPN 비밀번호>" https://<서울 IP>/region?r=jp
   curl -s -H "x-nago-key: <VPN 비밀번호>" "https://<서울 IP>/?format=json" | head -c 400
   ```

### 5. AWS에서 피어 목록 옮기기 (한 번)

AWS가 아직 살아 있을 때 피어 목록(공개키·이름)을 받아 서울에 넣는다.

```bash
aws ssm get-parameter --region ap-northeast-2 --name /nago/wg/peers \
  --query Parameter.Value --output text > wg-peers.json
scp wg-peers.json root@<서울 IP>:/var/lib/nago/wg-peers.json
ssh root@<서울 IP> 'chmod 600 /var/lib/nago/wg-peers.json && systemctl restart nago-control'
```

국가 API로 서버에 한 번씩 붙거나(5분에 한 번 sync), dash 탭에서 피어 하나를 바꾸면 4대 모두에 반영된다.

### 6. 앱 주소 바꾸기

| 파일 | 바꿀 것 |
|---|---|
| `WifiScan/VPNRegion.swift` | `RegionAPI.endpoint` → `https://<서울 IP>/region`, kr `fallback` IP |
| `WifiScan/DashView.swift` | `DashAPI.endpoint` → `https://<서울 IP>/?format=json` |
| `android/.../Regions.kt` | `ENDPOINT`, kr `fallback` IP |
| `android/.../WgVpn.kt` | `DASH` |
| `windows/NagoVpn.ps1` | `$Server` |

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

| 코드 | 나라 | 리전 |
|---|---|---|
| `sg` | 싱가포르 | `ap-southeast-1` |
| `de` | 독일 | `eu-central-1` |
| `fr` | 프랑스 | `eu-west-3` |
| `ie` | 아일랜드 | `eu-west-1` |
| `se` | 스웨덴 | `eu-north-1` |
| `ca` | 캐나다 | `ca-central-1` |
| `br` | 브라질 | `sa-east-1` |
| `au` | 호주 | `ap-southeast-2` |
| `in` | 인도 | `ap-south-1` |

- 국가 API(`region-api/index.py`, Lambda `nago-region`)가 `GET /region?r=sg`에 떠 있는 서버가 없으면 새로 만든다.
  Ubuntu 24.04 arm64(`c7g.medium`), 기본 VPC, 보안 그룹 `nago-ondemand`(udp 443/51820만), 태그 `nago:ondemand=<코드>`.
  만들 때 `state: "creating"`, WireGuard가 올라오면 `ready: true`(서버가 콘솔에 남기는 `NAGO_WG_READY`로 판단).
- **WireGuard를 먼저** 올린다. 패키지 없이 커널 wireguard + systemd-networkd로(user-data 한 번), 그래서 연결은 1분 안팎이면 된다.
  서버 키는 Lambda가 만들어 user-data로 넘기고 공개키는 태그 `nago:wgpub`로 돌려준다. 피어는 만들 때의 `/nago/wg/peers`
  (만든 뒤 새로 등록한 기기는 다음 서버부터). IKEv2·광고 차단 DNS는 없다.
- **TCP 분할 가속**은 그 뒤에 백그라운드(`nago-accel-setup`)로 haproxy를 깔아 켠다 — 고정 서버(`setup-region.sh`)와 같은 방식.
  WireGuard가 뜬 뒤 30초쯤이면 콘솔에 `NAGO_ACCEL_READY`가 찍히고, 그 뒤 새로 여는 TCP 연결부터 서버에서 끊어 다시 잇는다
  (먼 구간은 서버의 BBR·큰 버퍼로). 그동안에도 연결은 되고, 설치가 실패해도 가속만 없을 뿐이다. haproxy가 멈추면
  `nago-accel.service`(BindsTo=haproxy)가 리다이렉트 규칙을 같이 내려 TCP가 죽은 포트로 가지 않는다.
- **지우기**: 서버 안의 유휴 검사(분당 송신 300KB 미만이 30분)가 `poweroff` → 종료 동작이 `terminate`라 서버가 그대로 지워진다.
  24시간이 지나도 꺼진다. AWS 쪽 안전장치로 CloudWatch 경보(`nago-ondemand-<인스턴스>`, 5분 송신 1MB 미만이 1시간이면 terminate)도
  건다 — 서버가 멎어서 스스로 못 끄는 경우용. 지난 경보는 다음에 그 리전에 서버를 만들 때 치운다.
- **대시보드**(`nago-dash`): 지금 떠 있거나 이번 달에 쓴 임시 서버 나라가 서버 목록·지도·비용에 `onDemand: true`로 붙는다.
  지워진 서버는 목록에서 사라지므로 이번 달 사용량은 CloudTrail `RunInstances` 기록(태그 `nago:ondemand`)으로 인스턴스를 찾아
  CloudWatch(CPU 데이터 개수 = 켜져 있던 분, NetworkOut)로 센다(10분 캐시). 떠 있는 서버는 `POST {op: "drop", node: "sg"}`로 바로 지운다.
  대시보드 Lambda 환경 변수 `ONDEMAND`(`{"sg":{"region":"ap-southeast-1","city":"singapore"},...}`), 인라인 정책 `nago-ondemand`
  (cloudtrail:LookupEvents, 태그 붙은 인스턴스만 ec2:TerminateInstances).
- **동시에 2대까지**(`ONDEMAND_MAX`). 넘으면 409. 연결해 둔 채로 두면 터널이 핸드셰이크가 끊길 때 API를 다시 불러 새 서버를 만든다
  (늘 있는 서버를 다시 켜는 것과 같은 동작).
- 비용: 서버 시간당 $0.03~0.06(공인 IPv4 포함, 초 단위) + 송신 GB당 $0.09~0.15(전 리전 합쳐 매달 100GB 무료). 안 쓰면 0원.
- 나라 추가: Lambda 환경 변수 `ONDEMAND`(`{"sg":{"region":"ap-southeast-1"},...}`)와 IAM 인라인 정책 `nago-ondemand`의
  `aws:RequestedRegion` 목록, 앱 `VPNRegion`에 넣는다. 2019년 이후 생긴 리전(홍콩·대만·태국 등)은 계정에서 리전을 먼저 켜야 한다.
- 관리·점검: Lambda를 직접 부르면(IAM 권한 필요) 비밀번호 없이 된다 — `{"nago_internal": "region", "r": "sg"}`.
  API Gateway로 들어온 요청은 이 길로 올 수 없다.
- Lambda 반영: `cd server/region-api && zip -X /tmp/region.zip index.py && aws lambda update-function-code --region ap-northeast-2 --function-name nago-region --zip-file fileb:///tmp/region.zip`
  (제한 시간 25초 — 처음 만드는 요청이 10초 가까이 걸린다)

## 포함된 파일

| 파일 | 설명 |
|---|---|
| `ca-cert.pem` / `WifiScanVPN.mobileconfig` | 루트 CA 인증서(공개)와 아이폰에 설치·신뢰시키는 프로파일 |
| `make-bundle.sh` | 기존 CA로 서버 인증서 번들을 만든다(내 PC) |
| `setup-region.sh` | IKEv2 서버 구성(4대 공통) + 송신량 기록 |
| `wireguard/setup-wg.sh` | WireGuard 구성 |
| `adblock/setup-adblock.sh` | 광고 차단 DNS |
| `control/` | 컨트롤 서버: `app.py`(API·대시보드), `nago-peer.py`(서버에서 도는 피어 관리), `setup-control.sh`, `control.example.json` |
| `vultr/provision.ps1` | Vultr 서버·방화벽 그룹 만들기 |
| `setup-strongswan.sh` | (옛) CA까지 새로 만드는 단일 서버 스크립트 |

## 비용

- 대략 서울 vc2-2c-4gb + 해외 vc2-1c-2gb × 3. 정확한 값은 Vultr 가격표 기준이고 대시보드 `cost`가 매달 어림한다
- 포함 대역폭은 계정의 서버들끼리 합쳐 쓰고(풀), 넘으면 GB당 과금
- 서버를 지우면(Destroy) 요금이 멈춘다. 꺼 두기(Stop)는 요금이 그대로 나간다
