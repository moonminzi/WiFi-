# nagoing 서버 프록시

WireGuard(wg0, udp 51820)는 그대로 두고 그 앞에 nagoing 프록시를 세운다. 막힌 망에서도 붙게(①)
TCP 443은 TLS 흉내로, 손실 보정·빠른 전환(②③)을 살리는 UDP는 전용 포트로 듣고, 풀어서 wg0로 넘긴다.
설계는 저장소 루트 [`NAGOING.md`](../../NAGOING.md).

## 설치

각 서버(kr/jp/us/uk)에서:

```bash
sudo bash server/nagoing/setup-nagoing.sh
```

- NagoTun 크레이트(엔진 포함)를 그대로 빌드한다. 의존 크레이트를 crates.io에서 받으므로 **서버에 외부 접속이 필요**하다(Rust가 없으면 스크립트가 설치).
- 바이너리는 `/usr/local/sbin/nagoing-proxy`, 설정은 `/etc/nago/nagoing.env`, 서비스는 `nagoing-proxy.service`(systemd, 특권 포트 443만 바인드하도록 `CAP_NET_BIND_SERVICE`로 묶음).
- 여러 번 실행해도 안전. 코어·예제·엔진·Cargo 파일이 바이너리보다 새것이 없으면 빌드를 건너뛴다(`FORCE_BUILD=1`로 강제).

### 포트

| | 포트 | 쓰임 |
|---|---|---|
| TCP | 443 | TLS 흉내(ClientHello). 학교·회사·호텔처럼 VPN 막는 망의 **핵심 경로** |
| UDP | 51821 | QUIC 모양. FEC·빠른 전환이 사는 경로. `udp 443`은 기존 WG REDIRECT가 먼저 가로채서 전용 포트를 쓴다 |

둘 다 풀어서 로컬 `wg0`(127.0.0.1:51820)로 넘긴다. WireGuard 설정·키는 하나도 안 바뀐다(기존 피어 그대로).

## ★ AWS 보안그룹

호스트 iptables의 INPUT은 ACCEPT라 따로 안 건드리지만, **AWS 보안그룹에서 다음을 열어야** 바깥에서 닿는다:

- inbound **TCP 443** `0.0.0.0/0`
- inbound **UDP 51821** `0.0.0.0/0`

```bash
aws ec2 authorize-security-group-ingress --group-id <sg-id> --region <region> \
  --ip-permissions \
    IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=0.0.0.0/0}]' \
    IpProtocol=udp,FromPort=51821,ToPort=51821,IpRanges='[{CidrIp=0.0.0.0/0}]'
```

## 난독화 키(PSK)

`NAGO_PSK`(기본 `nago-obfs-v1`)는 **보안이 아니라 DPI 회피용**이라 모든 클라가 공유한다(진짜 보안은 안쪽 WireGuard).
클라이언트(`NagoingSettings.psk`)와 **같아야** 한다. 바꾸려면 양쪽을 같이 바꾼다:

```bash
sudo NAGO_PSK='...' bash server/nagoing/setup-nagoing.sh   # 서버
# 앱: WifiScan/NagoingSettings.swift 의 psk
```

## 확인·로그

```bash
systemctl status nagoing-proxy
journalctl -u nagoing-proxy -f
```

기존 WG·IKEv2·TCP 가속·adblock DNS와는 포트/경로가 겹치지 않는다(가속은 `-i wg0`/ipsec, adblock DNAT은 `-s 10.9.0.x`만
매칭 — 프록시의 wg0行은 loopback이라 안 걸린다).
