// NAGO VPN — NepTUN(WireGuard) 엔진 C 인터페이스 (NagoTun/src/lib.rs)
#ifndef NAGO_TUN_H
#define NAGO_TUN_H

#include <stddef.h>
#include <stdint.h>

typedef struct NagoTun NagoTun;

NagoTun *nago_tun_start(int tun_fd, const char *uapi, uint32_t threads);
int nago_tun_set(NagoTun *tun, const char *uapi);
size_t nago_tun_get(NagoTun *tun, char *buf, size_t len);
void nago_tun_network_changed(NagoTun *tun);
void nago_tun_stop(NagoTun *tun);
size_t nago_tun_last_error(char *buf, size_t len);

#endif
