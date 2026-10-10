# WifiScan VPN 서버 (AWS)

아이폰 앱의 **VPN 탭**이 붙는 IKEv2/EAP-MSCHAPv2 VPN 서버입니다.
iOS 내장 Personal VPN(NEVPNManager)이 그대로 쓸 수 있도록 **strongSwan**으로 구성했고,
별도의 Packet Tunnel 확장이나 서드파티 라이브러리가 필요 없습니다.

```
아이폰(VPN 탭, NEVPNManager/IKEv2)  ──UDP 500/4500──▶  EC2(strongSwan) ──NAT──▶ 인터넷
```

## 현재 운영 중인 서버

| 항목 | 값 |
|---|---|
| 리전 | `ap-northeast-2` (서울) |
| 공인 IP (EIP) | `3.38.243.135` |
| 프로토콜 | IKEv2 + EAP-MSCHAPv2 |
| 사용자 이름 | `wifiscan` |
| 비밀번호 | 레포에 올리지 않음(채팅으로 별도 전달) |
| 인스턴스 | Ubuntu 22.04, `t3.micro` |
| 가상 IP 풀 | `10.10.10.0/24` |
| DNS | `1.1.1.1`, `8.8.8.8` |

> 보안상 **CA 개인키**와 **VPN 비밀번호**는 이 저장소에 두지 않습니다.
> 공개해도 안전한 **CA 인증서**(`ca-cert.pem`)와 이를 신뢰시키는 프로파일
> (`WifiScanVPN.mobileconfig`)만 포함돼 있습니다.

## 아이폰에서 연결하기

1. **`WifiScanVPN.mobileconfig`를 아이폰으로 전송**(에어드롭/메일/메시지)해서 열고,
   **설정 → 일반 → VPN 및 기기 관리**에서 프로파일을 설치합니다.
2. **설정 → 일반 → 정보 → 인증서 신뢰 설정**에서
   **"WifiScan VPN Root CA"** 스위치를 켭니다. (자체 서명 CA라 이 단계가 꼭 필요합니다.)
3. 앱의 **VPN 탭**에서
   - 서버 주소: `3.38.243.135`
   - 사용자 이름: `wifiscan`
   - 비밀번호: (전달받은 값)
   을 넣고 **연결**을 누릅니다. 최초 1회 "VPN 구성 추가" 허용 창이 뜹니다.

## 국가 선택용 해외 서버

앱 VPN 탭에서 국가를 고르면 그 나라 리전의 IKEv2 서버로 붙습니다. 서울 서버(위)와 WireGuard 사용자는 그대로입니다.

| 국가 | 리전 | 인스턴스 | 서버 ID (인증서 SAN) |
|---|---|---|---|
| 🇯🇵 일본 | `ap-northeast-1` (도쿄) | `c7g.medium` | `jp.nago.vpn` |
| 🇺🇸 미국 | `us-west-2` (오리건) | `c7g.medium` | `us.nago.vpn` |
| 🇬🇧 영국 | `eu-west-2` (런던) | `c7g.medium` | `uk.nago.vpn` |

- 고정 IP(EIP)를 쓰지 않습니다. 켤 때마다 IP가 바뀌므로 인증서 ID를 FQDN으로 두고,
  앱은 국가 API(Lambda + API Gateway, `GET /region?r=jp`, 헤더 `x-nago-key`=VPN 비밀번호)로
  서버를 켜고 현재 IP를 받아 접속합니다. 서버 인증서는 서울과 같은 CA로 서명해서 CA 재설치가 필요 없습니다.
- **30분 유휴 자동 중지**: 서버 안의 `nago-idle.timer`가 매분 송신량을 보고, 분당 300KB 미만이 30분 이어지면 스스로 `poweroff` 합니다(EC2 종료 동작 = 중지). 카운터가 부팅마다 0부터라 다시 켠 직후 바로 꺼지는 일이 없습니다. CloudWatch 경보(3시간)는 백업으로 남겨 둡니다.
- 구성: `setup-region.sh <번들 디렉터리>` — strongSwan(AES-256-GCM, PFS 선택), MTU 1500, BBR,
  원거리용 TCP 버퍼, haproxy TCP 분할 가속까지 한 번에 설정합니다. 번들에는 미리 서명한
  `server-cert.pem`/`server-key.pem`, `ca-cert.pem`, `ipsec.secrets`, `id`가 들어갑니다(레포에 넣지 않음).

## 포함된 파일

| 파일 | 설명 |
|---|---|
| `ca-cert.pem` | 현재 서버의 루트 CA 인증서(공개). 앱/기기가 서버를 신뢰하는 데 사용 |
| `WifiScanVPN.mobileconfig` | 위 CA를 아이폰에 설치·신뢰시키는 구성 프로파일 |
| `setup-strongswan.sh` | Ubuntu 서버에서 strongSwan을 처음부터 구성하는 스크립트 |
| `setup-region.sh` | 국가 선택용 해외 서버(FQDN ID, 가속 포함)를 구성하는 스크립트 |
| `cloudformation.yaml` | EIP·보안그룹·IAM·EC2까지 한 번에 세우는 IaC 템플릿 |

## 처음부터 다시 세우기

### A. CloudFormation (권장)

```bash
aws cloudformation deploy \
  --region ap-northeast-2 \
  --stack-name wifiscan-vpn \
  --capabilities CAPABILITY_IAM \
  --template-file cloudformation.yaml \
  --parameter-overrides \
      VpcId=vpc-xxxxxxxx \
      SubnetId=subnet-xxxxxxxx \
      EapUsername=wifiscan \
      EapPassword='원하는_비밀번호_8자이상'

# 출력값 보기 (서버 IP, CA 받는 명령 등)
aws cloudformation describe-stacks --region ap-northeast-2 \
  --stack-name wifiscan-vpn --query 'Stacks[0].Outputs'

# 새로 만든 서버의 CA 인증서 내려받기(앱/mobileconfig 갱신용)
aws ssm get-parameter --region ap-northeast-2 \
  --name /wifiscan-vpn/wifiscan-vpn/ca-cert \
  --query Parameter.Value --output text > ca-cert.pem
```

- `SubnetId`는 인터넷 게이트웨이로 라우팅되는 **퍼블릭 서브넷**이어야 합니다.
- 템플릿이 인스턴스의 **source/dest check를 끄고**(NAT 동작에 필요),
  보안그룹에서 **UDP 500/4500**을 엽니다.
- 새 스택은 **새 CA**를 만들므로, 받은 `ca-cert.pem`으로 `WifiScanVPN.mobileconfig`를
  다시 만들어 기기에서 신뢰시켜야 합니다.

### B. 수동 스크립트

이미 떠 있는 Ubuntu 22.04 서버에서:

```bash
sudo VPN_PUBLIC_IP=<서버공인IP> VPN_EAP_USER=wifiscan VPN_EAP_PASS=<비밀번호> \
  ./setup-strongswan.sh
```

끝나면 `/etc/ipsec.d/cacerts/ca-cert.pem`을 받아서 기기에 설치·신뢰시키세요.
보안그룹/방화벽에서 **UDP 500, 4500** 인바운드를 직접 열어야 합니다.

## 상태 확인 / 문제 해결 (서버에서)

```bash
sudo ipsec statusall          # 데몬/커넥션 상태
sudo ipsec listcerts          # 로드된 서버 인증서
journalctl -u strongswan-starter -f   # 실시간 로그(핸드셰이크 디버깅)
```

연결이 안 될 때 자주 보는 원인
- 기기에서 **CA 신뢰(2단계)**를 안 켬 → "서버 인증서를 신뢰할 수 없음"
- 보안그룹에서 **UDP 4500**이 막힘(대부분 NAT-T로 4500 사용)
- 서버 **source/dest check**가 켜져 있어 포워딩된 패킷이 버려짐

## 비용 / 정리

- `t3.micro` + EIP(연결돼 있는 동안 무료) 기준 대략 월 $8~10 수준(리전·사용량 따라 다름).
- 더 안 쓰면 비용이 나가지 않도록 스택을 지웁니다(미사용 EIP는 과금되므로 함께 해제).

```bash
aws cloudformation delete-stack --region ap-northeast-2 --stack-name wifiscan-vpn
```

수동으로 만든 경우에는 EC2 인스턴스 종료 + EIP 해제 + 보안그룹/IAM 역할 삭제를 직접 해주세요.
