// NAGO VPN — NepTUN(WireGuard) 엔진 C 인터페이스 (NagoTun/src/lib.rs)
#ifndef NAGO_TUN_H
#define NAGO_TUN_H

#include <stddef.h>
#include <stdint.h>

typedef struct NagoTun NagoTun;

// queue: 스레드 사이 대기열 묶음 수(0이면 8, 최대 64)
NagoTun *nago_tun_start(int tun_fd, const char *uapi, uint32_t threads, uint32_t queue);
int nago_tun_set(NagoTun *tun, const char *uapi);
size_t nago_tun_get(NagoTun *tun, char *buf, size_t len);
void nago_tun_network_changed(NagoTun *tun);
void nago_tun_stop(NagoTun *tun);
size_t nago_tun_last_error(char *buf, size_t len);

// ── nagoing: WireGuard 아래에 끼우는 난독화·손실보정·빠른전환 전송 층 ──────────────
// NepTUN의 endpoint를 local(127.0.0.1:local_port)로 돌리면, 이 프록시가 WG 패킷을 받아
// 난독화·FEC해 server로 보낸다(UDP 443→막히면 TCP 443). 서버엔 nagoing 서버 프록시가 떠 있어야 한다.
typedef struct NagoingClient NagoingClient;

// prefer: 0 auto(UDP→TCP), 1 udp, 2 tcp. fec_on: 0이면 끔. sni가 NULL이면 기본값.
NagoingClient *nago_nagoing_client_start(const char *psk,
                                         const char *server_ip, uint16_t udp_port, uint16_t tcp_port,
                                         const char *local_ip, uint16_t local_port,
                                         uint8_t fec_k, uint16_t fec_groups, int fec_on,
                                         int prefer, const char *sni);
// 와이파이↔셀룰러 전환 등 경로가 바뀌면 호출(전송을 빠르게 다시 수립).
void nago_nagoing_network_changed(NagoingClient *client);
// 상태 한 줄("udp · tx .. · rx .. · fec+..")을 buf에 쓴다. 돌려주는 값은 전체 길이.
size_t nago_nagoing_stats(NagoingClient *client, char *buf, size_t len);
void nago_nagoing_client_stop(NagoingClient *client);

#endif
