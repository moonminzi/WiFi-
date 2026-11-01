package com.nago.vpn

import android.net.VpnService

/**
 * nagoing(막힌 망 우회) JNI. 함수는 NagoTun/src/android.rs에 있다(설계: 저장소 루트 NAGOING.md).
 * WireGuard는 그대로 두고 그 아래 전송만 바꾼다: QUIC 모양 UDP(51821)를 먼저, 막히면 진짜 TLS 1.3(TCP 443).
 */
object NagoingNative {
    init {
        System.loadLibrary("nago_tun")
    }

    /**
     * 클라이언트 시작. 실패하면 0(이유는 NeptunNative.lastError). 서버로 가는 소켓은 [service]로 protect한다.
     * prefer: 0 auto(UDP→TCP), 1 udp, 2 tcp
     */
    @JvmStatic external fun start(
        service: VpnService, serverIp: String, udpPort: Int, tcpPort: Int, localPort: Int,
        fecK: Int, fecGroups: Int, fecOn: Int, prefer: Int, sni: String, privateKey: String, serverPub: String,
    ): Long

    /** 엔진(NeptunNative 손잡이)에 바로 붙인다 — 로컬 UDP 홉 없이. 0이면 성공 */
    @JvmStatic external fun attach(client: Long, tun: Long): Int

    /** 와이파이↔모바일 데이터 전환 때 전송을 다시 세운다 */
    @JvmStatic external fun networkChanged(client: Long)

    /** "udp · tx .. · rx .. · fec+.." */
    @JvmStatic external fun stats(client: Long): String?

    /** 멈추고 해제한다(연결 수립 중이면 몇 초 걸릴 수 있다 — 메인 스레드에서 부르지 않는다) */
    @JvmStatic external fun stop(client: Long)
}

/** nagoing 설정(settings 탭 · iOS NagoingSettings와 같은 기본값) */
data class NagoingSettings(
    val prefer: String = "auto",
    val fec: Boolean = true,
    val fecK: Int = 8,
    val fecGroups: Int = 8,
    /** 서버 프록시 포트. TCP는 443(HTTPS, 막힌 망의 핵심). UDP는 전용 51821 */
    val udpPort: Int = 51821,
    val tcpPort: Int = 443,
    /** 엔진이 붙기 전·못 붙을 때 WG 패킷을 보낼 로컬 포트(기기 안, 127.0.0.1) */
    val localPort: Int = 51822,
    val sni: String = "www.cloudflare.com",
) {
    val preferCode get() = when (prefer) {
        "udp" -> 1
        "tcp" -> 2
        else -> 0
    }

    /** `auto · fec 8/8` */
    val summary get() = "$prefer · " + if (fec) "fec $fecK/$fecGroups" else "fec off"
}
