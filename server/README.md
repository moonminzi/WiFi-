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
| `signer/index.py` | NAGO signer Lambda — IPA를 내 인증서로 서명해서 Safari에서 바로 설치(아래) |

## NAGO signer (IPA 서명 → 바로 설치)

컴퓨터 없이 아이패드 Safari만으로 IPA를 서명해서 설치한다. 대시보드처럼 토큰이 붙은 주소로 연다.

- 페이지(`GET /?t=<TOKEN>`): 인증서·프로파일 요약(팀, ad-hoc/기기 수, 만료일, 앱 ID — 여러 개면 골라서 서명), 이 레포의 최근 릴리스 IPA(`build-N`, `nagodl-N`),
  IPA 주소 붙여 넣기, 파일 올리기(브라우저 → S3 직접, 6MB 제한 없음). `sign`을 누르면 몇 초 뒤 **설치** 버튼(itms-services)이 생긴다
- 서명: `rcodesign`(apple-codesign, musl 정적 빌드 — `tools/build-rcodesign-lambda.sh`)을 Lambda 패키지 `bin/`에 같이 넣어 부른다.
  앱이 원래 요청한 엔타이틀먼트 중 프로파일이 허락하는 것만 남기고, 앱 ID·팀·키체인 그룹은 프로파일에 맞춘다. 확장(PlugIns 등)도 같이 서명
- 번들 ID: `profile`(기본) — 프로파일의 앱 ID로 바꾼다. 확장은 `<앱 ID>.<원래 끝 이름>`. 프로파일이 앱 ID 하나라 다른 앱을 이 모드로 깔면 덮어쓴다.
  `keep` — 원래 ID 그대로(여러 앱을 같이 둘 때). NAGO VPN은 터널 확장 ID를 실행 중에 읽어서 어느 쪽이든 동작한다
- 링크는 1시간(`LINK_TTL`) 유효. 서명본(`signed/`)·올린 파일(`uploads/`)은 버킷 수명 주기 규칙으로 하루 뒤 지워진다

| 리소스 (ap-northeast-2) | 내용 |
|---|---|
| Lambda `nago-sign` | python3.12 x86_64, 메모리 2048MB, 제한 10분, /tmp 4GB. 환경변수 `TOKEN`, `BUCKET`, `SECRET_ID`(쉼표로 여러 개), `GH_REPO`, `LINK_TTL` |
| 함수 URL | 인증 없음(토큰은 코드가 확인), `InvokeFunctionUrl`·`InvokeFunction`(함수 URL 경유) 공개 허용 |
| Secrets Manager `nago/sign/cert`, `nago/sign/cert-2` | 인증서마다 하나씩 `{"p12": base64, "password": "…", "profile": base64}` — 레포에 넣지 않는다 |
| IAM 역할 `nago-sign` | 로그, 버킷 `uploads/*`·`signed/*` 읽기/쓰기, 위 시크릿들 읽기 |
| S3 `nago-ota-<계정>-apne2` | 퍼블릭 액세스 전부 차단, 하루 뒤 삭제 규칙, 함수 URL에서 PUT 허용(CORS) |

코드 갱신:

```bash
tools/build-rcodesign-lambda.sh build/rcodesign
mkdir -p build/signer/bin && cp server/signer/index.py build/signer/ && cp build/rcodesign/bin/rcodesign build/signer/bin/
(cd build/signer && zip -qr ../nago-sign.zip index.py bin)
aws lambda update-function-code --region ap-northeast-2 --function-name nago-sign --zip-file fileb://build/nago-sign.zip
```

인증서를 바꾸면 시크릿 값만 바꾸면 된다(`aws secretsmanager put-secret-value --secret-id nago/sign/cert --secret-string file://cert.json`).
인증서를 더 넣으려면 시크릿을 새로 만들고(`nago/sign/cert-3` …) IAM 역할에 그 ARN 읽기를 더한 뒤 `SECRET_ID`에 쉼표로 붙인다(앞쪽이 기본 선택).
토큰을 바꾸려면 Lambda 환경변수 `TOKEN`.

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
