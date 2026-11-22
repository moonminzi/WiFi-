package com.nago.vpn

import android.net.VpnService

/** NepTUN 엔진(NagoTun, Rust) JNI. 함수는 NagoTun/src/android.rs에 있다. */
object NeptunNative {
    init {
        System.loadLibrary("nago_tun")
    }

    /**
     * 터널 시작. 실패하면 0(이유는 lastError). tunFd는 엔진이 닫는다.
     * 엔진이 서버로 가는 UDP 소켓을 만들 때마다 [service]의 protect()로 터널 밖으로 뺀다(앱은 VPN 안에 있다).
     */
    @JvmStatic external fun start(service: VpnService, tunFd: Int, uapi: String, threads: Int): Long

    /** 지금까지 protect가 실패한 횟수(실패한 소켓은 터널로 돌아 들어가 연결이 안 된다) */
    @JvmStatic external fun protectFailures(): Int

    /** 설정 변경. 0이면 성공, 아니면 UAPI errno. */
    @JvmStatic external fun set(handle: Long, uapi: String): Int

    /** UAPI get=1 응답(last_handshake_time_sec, rx_bytes, tx_bytes …) */
    @JvmStatic external fun get(handle: Long): String?

    /** 와이파이↔모바일 데이터 전환 때 UDP 소켓을 새로 만든다. */
    @JvmStatic external fun networkChanged(handle: Long)

    @JvmStatic external fun stop(handle: Long)

    @JvmStatic external fun lastError(): String?
}
