NAGO VPN iOS 2.1.1

**2.1.1**
- 엔진 이름이 **nagotun**이 됐다. NordVPN의 NepTUN을 저장소(`NagoTun/engine/`)로 가져와 우리 서버·폰에 맞게 고친 우리 엔진
- 이벤트 루프 기본 1개(전엔 2개). 리눅스 벤치에서 같은 속도에 1GB당 CPU가 25~32% 적었다 — 배터리·발열이 덜하다.
  관리자용 settings → loops에서 2로 바꿔 speed test로 비교할 수 있다
- 설정 꼬리표·speed test 기록에 `wg/nagotun ×1`로 나온다(설정 값은 그대로라 다시 고를 필요 없음)

**2.1.0**
- 유저용에도 임시 서버 나라 9곳, dash에 임시 서버 나라(가동 시간·이번 달 비용, delete now)
