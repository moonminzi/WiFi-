package com.nago.vpn

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/** 출구 IP가 이 나라로 보여야 하는 국가 코드 */
val VpnRegion.countryCode: String
    get() = when (this) {
        VpnRegion.kr -> "KR"
        VpnRegion.jp -> "JP"
        VpnRegion.us -> "US"
        VpnRegion.uk -> "GB"
    }

/** 그 나라 서버가 있는 AWS 리전(detail의 뒷부분) */
val VpnRegion.awsRegion: String get() = detail.substringAfterLast(' ')

/**
 * 밖에서 보이는 내 IP와 나라. Cloudflare의 `/cdn-cgi/trace`(ip=…, loc=JP, colo=NRT 같은 줄)를 읽는다(iOS와 같음).
 * 앱 안 wg(neptun/go)는 앱 자신을 터널에서 빼 두므로 그때는 연결 전 회선만 보인다 — 연결 후에는 ikev2에서만 쓴다.
 */
data class ExitInfo(val ip: String, val country: String, val colo: String) {
    companion object {
        suspend fun fetch(): ExitInfo? = withContext(Dispatchers.IO) {
            runCatching {
                val conn = URL("https://1.1.1.1/cdn-cgi/trace").openConnection() as HttpURLConnection
                try {
                    conn.connectTimeout = 6_000
                    conn.readTimeout = 6_000
                    conn.useCaches = false
                    val fields = conn.inputStream.bufferedReader().use { it.readLines() }
                        .mapNotNull { line -> line.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] } }
                        .toMap()
                    fields["ip"]?.let { ExitInfo(it, fields["loc"] ?: "??", fields["colo"] ?: "") }
                } finally {
                    conn.disconnect()
                }
            }.getOrNull()
        }
    }
}

/**
 * 나라별 실제 왕복 시간(ms). 각 AWS 리전의 DynamoDB `/ping`(인증 없음, 아주 작은 응답)에 한 번 물어 연결을 데우고
 * (TLS 핸드셰이크가 섞여서 버린다) 같은 연결로 두 번 더 재서 빠른 쪽을 쓴다(iOS LatencyProbe와 같음).
 */
object LatencyProbe {
    suspend fun measure(): Map<VpnRegion, Int> = coroutineScope {
        VpnRegion.entries.map { region -> async(Dispatchers.IO) { region to ping(region) } }
            .awaitAll()
            .mapNotNull { (region, ms) -> ms?.let { region to it } }
            .toMap()
    }

    private fun ping(region: VpnRegion): Int? {
        val url = URL("https://dynamodb.${region.awsRegion}.amazonaws.com/ping")
        if (get(url) == null) return null
        return (0 until 2).mapNotNull { get(url) }.minOrNull()?.toInt()
    }

    /** 한 번 묻고 걸린 시간(ms). 실패하면 null. 연결은 기본 풀에 남아 다음 번에 다시 쓴다. */
    private fun get(url: URL): Long? = runCatching {
        val start = System.nanoTime()
        val conn = url.openConnection() as HttpURLConnection
        conn.connectTimeout = 4_000
        conn.readTimeout = 4_000
        conn.useCaches = false
        val ok = conn.responseCode == 200
        conn.inputStream.use { it.readBytes() }
        if (ok) (System.nanoTime() - start) / 1_000_000 else null
    }.getOrNull()
}

/** 터널을 실제로 오가는지: 받은·보낸 바이트와 마지막 핸드셰이크 시각(epoch ms, 아직 없으면 0) */
data class LinkStats(val rx: Long, val tx: Long, val handshakeMs: Long)

/** 1초마다 받은 바이트 수로 속도(바이트/초)를 낸다. 최근 60초를 남긴다(iOS TrafficMeter와 같음). */
class TrafficMeter {
    data class Rate(val down: Double, val up: Double)

    var history by mutableStateOf(emptyList<Rate>())
        private set
    var totalDown by mutableLongStateOf(0L)
        private set
    var totalUp by mutableLongStateOf(0L)
        private set
    private var last: Triple<Long, Long, Long>? = null

    val current get() = history.lastOrNull()
    val hasData get() = last != null

    fun reset() {
        history = emptyList()
        totalDown = 0
        totalUp = 0
        last = null
    }

    fun add(rx: Long, tx: Long, now: Long = System.nanoTime()) {
        totalDown = rx
        totalUp = tx
        val previous = last
        last = Triple(now, rx, tx)
        // 터널이 다시 뜨면 숫자가 0부터 다시 센다 — 그 한 번은 건너뛴다
        if (previous == null || now <= previous.first || rx < previous.second || tx < previous.third) return
        val dt = (now - previous.first) / 1e9
        history = (history + Rate((rx - previous.second) / dt, (tx - previous.third) / dt)).takeLast(WINDOW)
    }

    companion object {
        const val WINDOW = 60

        /** 2400000 → "2.4 MB/s" */
        fun speed(bytesPerSecond: Double): String {
            val v = maxOf(0.0, bytesPerSecond)
            return when {
                v >= 1e6 -> "%.1f MB/s".format(v / 1e6)
                v >= 1e3 -> "%.0f KB/s".format(v / 1e3)
                else -> "%.0f B/s".format(v)
            }
        }

        fun bytes(n: Long): String {
            val v = n.toDouble()
            return when {
                v >= 1e9 -> "%.2f GB".format(v / 1e9)
                v >= 1e6 -> "%.1f MB".format(v / 1e6)
                v >= 1e3 -> "%.0f KB".format(v / 1e3)
                else -> "$n B"
            }
        }
    }
}
