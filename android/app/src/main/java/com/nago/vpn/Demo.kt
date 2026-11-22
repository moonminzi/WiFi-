package com.nago.vpn

import android.app.Activity
import android.content.pm.ApplicationInfo

/**
 * 화면 스크린샷용 데모 상태(iOS Demo.swift와 같음). 디버그 빌드에서만 켜진다 — 서버 없이 그 상태를 그린다.
 * `adb shell am start -n com.nago.vpn.debug/com.nago.vpn.MainActivity --es nagoDemo connected`
 * - nagoDemo: idle / connecting / connected / failed / scan
 * - nagoRegion: 고를 나라(없으면 jp) · nagoTab: vpn / settings · nagoUnfold: 접는 패널을 모두 편다 · nagoPeek: 이 임시 나라 칸의 말풍선
 */
object Demo {
    var state: String? = null
        private set
    var region: VpnRegion? = null
        private set
    var tab: String? = null
        private set
    var unfold = false
        private set
    var peek: VpnRegion? = null
        private set

    val on get() = state != null
    val connected get() = state == "connected"

    /** 데모 연결이 붙은 시각(12분 34초 전) */
    val since = System.currentTimeMillis() - 754_000

    fun load(activity: Activity) {
        if (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return
        val extras = activity.intent?.extras ?: return
        state = extras.getString("nagoDemo")
        region = extras.getString("nagoRegion")?.let { runCatching { VpnRegion.valueOf(it) }.getOrNull() }
        tab = extras.getString("nagoTab")
        unfold = extras.getBoolean("nagoUnfold", false)
        peek = extras.getString("nagoPeek")?.let { runCatching { VpnRegion.valueOf(it) }.getOrNull() }
    }

    val rtt = mapOf(
        VpnRegion.kr to 4, VpnRegion.jp to 31, VpnRegion.us to 128, VpnRegion.uk to 247, VpnRegion.sg to 71,
        VpnRegion.de to 238, VpnRegion.fr to 251, VpnRegion.ie to 262, VpnRegion.se to 254, VpnRegion.ca to 178,
        VpnRegion.br to 296, VpnRegion.au to 132, VpnRegion.`in` to 132,
    )

    val exit get() = if (connected) ExitInfo("54.199.12.4", "JP", "NRT") else ExitInfo("211.36.1.9", "KR", "ICN")

    val checks = listOf(
        NetScan.Check("link", "wi-fi · ipv4+ipv6", NetScan.Level.Info),
        NetScan.Check("portal", "no login page · http untouched", NetScan.Level.Pass),
        NetScan.Check("dns", "one.one.one.one → 1.1.1.1 ✓", NetScan.Level.Pass),
        NetScan.Check("nxdomain", "missing names answered → 175.223.10.4 (ad dns)", NetScan.Level.Warn),
        NetScan.Check("doh", "encrypted dns reachable", NetScan.Level.Pass),
        NetScan.Check("tls", "chain ends at a system root", NetScan.Level.Pass),
        NetScan.Check("ipv6", "ipv6 available · rescan with vpn on to test leaks", NetScan.Level.Info),
        NetScan.Check("exit", "211.36.1.9 · KR", NetScan.Level.Info),
        NetScan.Check("quality", "kr 4ms · jitter 1ms · loss 0/6", NetScan.Level.Pass),
    )

    fun speedHistory(): List<SpeedTest.Result> {
        val now = System.currentTimeMillis()
        return listOf(
            SpeedTest.Result(now - 60_000, "wg/NagoTun ×1 · jp", 312.4, 88.1, 31.0, 52.0),
            SpeedTest.Result(now - 420_000, "wg/NagoTun ×2 · jp", 243.9, 86.7, 31.0, 71.0),
            SpeedTest.Result(now - 900_000, "wg/go · jp", 228.0, 80.2, 32.0, 66.0),
            SpeedTest.Result(now - 1_500_000, "direct", 486.5, 121.0, 9.0, 38.0),
        )
    }

    /** 1분치 속도 그래프(iOS TrafficMeter.fillDemo와 같은 모양) */
    fun fill(meter: TrafficMeter) {
        meter.reset()
        var rx = 48_200_000L
        var tx = 3_100_000L
        val start = System.nanoTime() - TrafficMeter.WINDOW * 1_000_000_000L
        for (i in 0..TrafficMeter.WINDOW) {
            val burst = maxOf(0.0, kotlin.math.sin(i / 6.0)) * 2_600_000 + if (i % 17 < 3) 1_800_000 else 0
            rx += (120_000 + burst).toLong()
            tx += (18_000 + burst / 22).toLong()
            meter.add(rx, tx, start + i * 1_000_000_000L)
        }
    }
}
