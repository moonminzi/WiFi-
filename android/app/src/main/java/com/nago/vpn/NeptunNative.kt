package com.nago.vpn

/** NepTUN 엔진(NagoTun, Rust) JNI. 함수는 NagoTun/src/android.rs에 있다. */
object NeptunNative {
    init {
        System.loadLibrary("nago_tun")
    }

    /** 터널 시작. 실패하면 0(이유는 lastError). tunFd는 엔진이 닫는다. */
    @JvmStatic external fun start(tunFd: Int, uapi: String, threads: Int): Long

    /** 설정 변경. 0이면 성공, 아니면 UAPI errno. */
    @JvmStatic external fun set(handle: Long, uapi: String): Int

    /** UAPI get=1 응답(last_handshake_time_sec, rx_bytes, tx_bytes …) */
    @JvmStatic external fun get(handle: Long): String?

    /** 와이파이↔모바일 데이터 전환 때 UDP 소켓을 새로 만든다. */
    @JvmStatic external fun networkChanged(handle: Long)

    @JvmStatic external fun stop(handle: Long)

    @JvmStatic external fun lastError(): String?
}
