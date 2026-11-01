package com.nago.vpn

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/** 설정 값 "neptun"(예전 이름 그대로 저장)은 화면에 우리 엔진 이름 NagoTun으로 */
fun engineName(value: String): String = if (value == "neptun") "NagoTun" else value

/** 출구 IP가 이 나라로 보여야 하는 국가 코드 */
val VpnRegion.countryCode: String
    get() = if (this == VpnRegion.uk) "GB" else name.uppercase()

/**
 * 밖에서 보이는 내 IP와 나라. Cloudflare의 `/cdn-cgi/trace`(ip=…, loc=JP, colo=NRT 같은 줄)를 읽는다(iOS와 같음).
 * 앱도 터널 안에 있어서(엔진 소켓만 protect) 연결되면 나가는 서버 것이 보여야 한다 — 나라가 다르면 새는 것.
 */
data class ExitInfo(val ip: String, val country: String, val colo: String) {
    companion object {
        /**
         * 화면에서 IP 뒷부분을 가린다(스크린샷을 남에게 보여 줄 때, iOS와 같음). `210.182.248.204` → `210.182.•••.•••`,
         * IPv6는 앞 두 묶음만 남긴다. 회선·지역 정도는 알아볼 수 있고 집 주소는 안 보인다.
         */
        fun masked(ip: String): String {
            if (':' in ip) return ip.split(':').take(2).joinToString(":") + ":••••"
            val parts = ip.split('.')
            return if (parts.size == 4) "${parts[0]}.${parts[1]}.•••.•••" else "•••"
        }

        /** 글 안의 IPv4를 모두 가린다(net scan 결과 줄) */
        fun maskIPs(text: String): String =
            Regex("""(\d{1,3}\.\d{1,3})\.\d{1,3}\.\d{1,3}""").replace(text) { "${it.groupValues[1]}.•••.•••" }

        suspend fun fetch(): ExitInfo? = if (Demo.on) Demo.exit else withContext(Dispatchers.IO) {
            runCatching {
                val conn = URL("https://1.1.1.1/cdn-cgi/trace").openConnection() as HttpURLConnection
                try {
                    conn.connectTimeout = 6_000
                    conn.readTimeout = 6_000
                    conn.useCaches = false
                    // 잴 때마다 새 연결. 연결 전에 열어 둔 1.1.1.1 연결을 다시 쓰면 터널이 생긴 뒤에도
                    // 예전 회선으로 나가서 제대로 연결됐는데 KR이 보인다(iOS에서 겪음)
                    conn.setRequestProperty("Connection", "close")
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
    suspend fun measure(): Map<VpnRegion, Int> = if (Demo.on) Demo.rtt else coroutineScope {
        VpnRegion.entries.map { region -> async(Dispatchers.IO) { region to ping(region) } }
            .awaitAll()
            .mapNotNull { (region, ms) -> ms?.let { region to it } }
            .toMap()
    }

    private fun ping(region: VpnRegion): Int? = samples(region, 2).filterNotNull().minOrNull()?.let { Math.round(it).toInt() }

    /** 한 번 데워(TLS 핸드셰이크) 둔 연결로 [count]번 잰 왕복 시간(ms). 실패한 회는 null. */
    fun samples(region: VpnRegion, count: Int): List<Double?> {
        val url = URL("https://dynamodb.${region.awsRegion}.amazonaws.com/ping")
        if (get(url) == null) return List(count) { null }
        return List(count) { get(url) }
    }

    /** 한 번 묻고 걸린 시간(ms). 실패하면 null. 연결은 기본 풀에 남아 다음 번에 다시 쓴다. */
    private fun get(url: URL): Double? = runCatching {
        val start = System.nanoTime()
        val conn = url.openConnection() as HttpURLConnection
        conn.connectTimeout = 4_000
        conn.readTimeout = 4_000
        conn.useCaches = false
        val ok = conn.responseCode == 200
        conn.inputStream.use { it.readBytes() }
        if (ok) (System.nanoTime() - start) / 1e6 else null
    }.getOrNull()
}

/** 터널을 실제로 오가는지: 받은·보낸 바이트와 마지막 핸드셰이크 시각(epoch ms, 아직 없으면 0) */
data class LinkStats(val rx: Long, val tx: Long, val handshakeMs: Long)

/**
 * 연결돼 있는 동안 1초마다 엔진에 바이트 수·핸드셰이크를 물어 최근 1분 속도를 쌓는다.
 * 화면이 아니라 프로세스에서 돈다(엔진이 켜질 때 시작, 꺼질 때 멈춤) — 탭을 오가거나 화면을 나갔다 와도 그래프가 이어진다.
 * VPN이 켜져 있는 동안은 시스템이 앱 프로세스를 살려 둔다(VpnService).
 */
object LinkMonitor {
    val meter = TrafficMeter()
    /** 마지막 핸드셰이크(epoch ms, 아직 없으면 0) */
    var handshakeMs by mutableLongStateOf(0L)
        private set
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null

    @Synchronized
    fun start(read: suspend () -> LinkStats?) {
        job?.cancel()
        meter.reset()
        handshakeMs = 0L
        job = scope.launch {
            while (isActive) {
                read()?.let {
                    meter.add(it.rx, it.tx)
                    handshakeMs = it.handshakeMs
                }
                delay(1_000)
            }
        }
    }

    @Synchronized
    fun stop() {
        job?.cancel()
        job = null
        meter.reset()
        handshakeMs = 0L
    }
}

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
