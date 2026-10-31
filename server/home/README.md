# 집 출구 노드(home exit)

친구 집 리눅스 PC·라즈베리파이를 VPN 출구로 쓴다. 앱에서 `home · 이름`을 고른 사람은 그 집 회선 IP로 보인다
(넷플릭스·은행·쇼핑몰처럼 데이터센터 IP를 막는 사이트용).

```sh
sudo NAGO_KEY='VPN 비밀번호' bash nago-home.sh minji-pc   # 켜기
sudo bash nago-home.sh --off                               # 끄기
```

- 집 공유기 포트를 열 필요 없음(이 PC가 서울 서버로 먼저 붙는다, wg udp 443)
- VPN 쪽에서 들어온 트래픽은 집 내부망(192.168.x 등)과 이 PC 자체로는 못 간다 — 인터넷으로만
- 이 PC의 인터넷을 친구들이 같이 쓰는 것이라 그 트래픽은 이 집 IP로 나간다(누가 쓰는지 알고 켤 것)
- 리눅스만(커널 WireGuard·ipip). 데비안·우분투·라즈베리파이 OS
