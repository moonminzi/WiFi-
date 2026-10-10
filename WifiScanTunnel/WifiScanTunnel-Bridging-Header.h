// WifiScanTunnel(Swift)에서 쓰는 C 선언
#include <sys/types.h>
#include "nago_tun.h"   // NepTUN 엔진(NagoTun/include)

// iOS가 만든 utun의 fd를 찾을 때 쓴다(<sys/kern_control.h>는 iOS SDK에 공개돼 있지 않음).
// WireGuardKit(MIT)과 같은 정의, 이름만 nago_ 접두어.
#define NAGO_CTLIOCGINFO 0xc0644e03UL
struct nago_ctl_info {
    u_int32_t ctl_id;
    char ctl_name[96];
};
struct nago_sockaddr_ctl {
    u_char sc_len;
    u_char sc_family;
    u_int16_t ss_sysaddr;
    u_int32_t sc_id;
    u_int32_t sc_unit;
    u_int32_t sc_reserved[5];
};
