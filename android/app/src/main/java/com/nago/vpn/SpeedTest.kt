package com.nago.vpn

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * 지금 회선(VPN이 켜져 있으면 터널)의 실제 속도. 설정(loops 1·2, NagoTun·go, 나라)을 바꿔 가며 비교한다(iOS SpeedTest와 같음).
 * - 받기·올리기: Cloudflare 속도 측정 서버(speed.cloudflare.com)에 연결 4개로 동시에 7초씩.
 *   처음 1.5초(TCP가 속도를 올리는 동안)는 빼고 잰다
 * - 핑: 쉬는 동안 5번(중간값), 받는 동안 0.4초마다(대기열이 쌓이면 이 값이 커진다)
 * - 결과는 어떤 설정이었는지(via)와 함께 최근 8개까지 남긴다
 */
class SpeedTest(private val context: Context) {
    enum class Phase { Idle, Ping, Download, Upload, Done, Failed }

    data class Result(
        val at: Long,
        /** "wg/NagoTun ×2 · jp", "ikev2 · us", "direct" … */
        val via: String,
        val downMbps: Double,
        val upMbps: Double,
        val idleMs: Double?,
        val loadedMs: Double?,
    )

    var phase by mutableStateOf(Phase.Idle)
        private set
    /** 지금 단계에서 흐르는 속도(Mbps) */
    var liveMbps by mutableDoubleStateOf(0.0)
        private set
    /** 지금 단계가 얼마나 지났는지(0…1) */
    var progress by mutableDoubleStateOf(0.0)
        private set
    var history by mutableStateOf(load())
        private set
    var errorText by mutableStateOf<String?>(null)
        private set

    val last get() = history.firstOrNull()
    val running get() = phase == Phase.Ping || phase == Phase.Download || phase == Phase.Upload

    suspend fun run(via: String) {
        if (running) return
        errorText = null
        phase = Phase.Ping
        progress = 0.0
        liveMbps = 0.0
        val idle = withContext(Dispatchers.IO) { Cloudflare.pingMedian(5) }
        if (idle == null) {
            fail("speed.cloudflare.com unreachable")
            return
        }

        phase = Phase.Download
        val loaded = mutableListOf<Double>()
        val pinger = CoroutineScope(Dispatchers.IO).launch {
            Cloudflare.ping()   // TLS 핸드셰이크
            while (isActive) {
                Cloudflare.ping()?.let { synchronized(loaded) { loaded += it } }
                delay(400)
            }
        }
        val down = transfer(upload = false)
        pinger.cancel()
        val loadedMs = synchronized(loaded) { loaded.sorted().getOrNull(loaded.size / 2) }

        phase = Phase.Upload
        val up = transfer(upload = true)
        if (down == null || up == null) {
            fail("transfer failed")
            return
        }
        history = (listOf(Result(System.currentTimeMillis(), via, down, up, idle, loadedMs)) + history).take(8)
        save()
        liveMbps = 0.0
        progress = 1.0
        phase = Phase.Done
    }

    /** 스크린샷용(저장하지 않는다) */
    fun showDemo() {
        history = Demo.speedHistory()
        phase = Phase.Done
        progress = 1.0
    }

    private fun fail(message: String) {
        errorText = message
        liveMbps = 0.0
        phase = Phase.Failed
    }

    /** 연결 4개로 정해진 시간 동안 받거나 올리고, 처음 1.5초를 뺀 평균 속도(Mbps)를 돌려준다. */
    private suspend fun transfer(upload: Boolean): Double? {
        val bytes = AtomicLong()
        val failures = AtomicInteger()
        val done = AtomicInteger()
        val scope = CoroutineScope(Dispatchers.IO)
        val jobs: List<Job> = List(STREAMS) {
            scope.launch {
                runCatching { if (upload) Cloudflare.upload(UP_BYTES, bytes) else Cloudflare.download(DOWN_BYTES, bytes) }
                    .onFailure { failures.incrementAndGet() }
                done.incrementAndGet()
            }
        }
        try {
            val start = System.nanoTime()
            var mark: Pair<Double, Long>? = null
            var previous = 0.0 to 0L
            var finished = 0.0 to 0L
            while (true) {
                delay(200)
                val t = (System.nanoTime() - start) / 1e9
                val total = bytes.get()
                liveMbps = (total - previous.second) * 8 / maxOf(t - previous.first, 0.001) / 1e6
                previous = t to total
                progress = minOf(t / SECONDS, 1.0)
                if (mark == null && t >= WARMUP) mark = t to total
                finished = t to total
                if (t >= SECONDS || done.get() >= STREAMS || failures.get() >= STREAMS) break
            }
            if (finished.second <= 0) return null
            // 1.5초 뒤부터 잰다. 그 뒤로 1초도 안 돼서 끝났으면(아주 빠른 회선) 처음부터
            val from = mark?.takeIf { finished.first - it.first > 1 } ?: (0.0 to 0L)
            val seconds = maxOf(finished.first - from.first, 0.1)
            return (finished.second - from.second) * 8 / seconds / 1e6
        } finally {
            jobs.forEach { it.cancel() }
            Cloudflare.abort(jobs)
        }
    }

    private fun load(): List<Result> = runCatching {
        val array = JSONArray(prefs().getString(KEY, "[]"))
        List(array.length()) { i ->
            val o = array.getJSONObject(i)
            Result(
                at = o.getLong("at"), via = o.getString("via"),
                downMbps = o.getDouble("down"), upMbps = o.getDouble("up"),
                idleMs = o.optDouble("idle").takeIf { !it.isNaN() },
                loadedMs = o.optDouble("loaded").takeIf { !it.isNaN() },
            )
        }
    }.getOrDefault(emptyList())

    private fun save() {
        val array = JSONArray()
        history.forEach { r ->
            array.put(JSONObject().put("at", r.at).put("via", r.via).put("down", r.downMbps).put("up", r.upMbps)
                .apply {
                    r.idleMs?.let { put("idle", it) }
                    r.loadedMs?.let { put("loaded", it) }
                })
        }
        prefs().edit().putString(KEY, array.toString()).apply()
    }

    private fun prefs() = context.getSharedPreferences("nago", Context.MODE_PRIVATE)

    companion object {
        private const val KEY = "speedHistory"
        private const val STREAMS = 4
        private const val SECONDS = 7.0
        private const val WARMUP = 1.5
        /** 연결 하나가 받을 최대 양. 7초 안에 다 받으면(아주 빠른 회선) 그때까지로 잰다 */
        private const val DOWN_BYTES = 50_000_000
        /** 연결 하나가 올릴 양 */
        private const val UP_BYTES = 25_000_000
        /** 화면에 적어 두는 최대 사용량(받기 4×50MB + 올리기 4×25MB) */
        const val MAX_USAGE_MB = STREAMS * (DOWN_BYTES + UP_BYTES) / 1_000_000

        fun mbps(value: Double) = if (value >= 100) "%.0f".format(value) else "%.1f".format(value)
    }
}

/** Cloudflare 속도 측정 서버(연결마다 따로 — 다 쓰면 닫아서 다음 측정이 예전 회선의 연결을 다시 쓰지 않게) */
private object Cloudflare {
    private const val HOST = "https://speed.cloudflare.com"
    private val open = java.util.concurrent.ConcurrentHashMap<Job, HttpURLConnection>()

    private fun connect(url: String): HttpURLConnection = (URL(url).openConnection() as HttpURLConnection).apply {
        connectTimeout = 15_000
        readTimeout = 15_000
        useCaches = false
        setRequestProperty("Connection", "close")
    }

    /** 0바이트 요청의 왕복 시간(ms). 실패하면 null */
    fun ping(): Double? = runCatching {
        val start = System.nanoTime()
        val conn = connect("$HOST/__down?bytes=0")
        try {
            conn.inputStream.use { it.readBytes() }
        } finally {
            conn.disconnect()
        }
        (System.nanoTime() - start) / 1e6
    }.getOrNull()

    /** 0바이트 요청의 왕복 시간 중간값(ms). 첫 요청은 TLS 핸드셰이크가 섞여서 버린다 */
    fun pingMedian(count: Int): Double? {
        ping() ?: return null
        val samples = List(count) { ping() }.filterNotNull().sorted()
        return samples.getOrNull(samples.size / 2)
    }

    suspend fun download(size: Int, counter: AtomicLong) {
        val conn = connect("$HOST/__down?bytes=$size")
        track(conn)
        try {
            conn.inputStream.use { input ->
                val buf = ByteArray(64 * 1024)
                while (kotlin.coroutines.coroutineContext.isActive) {
                    val n = input.read(buf)
                    if (n < 0) break
                    counter.addAndGet(n.toLong())
                }
            }
        } finally {
            untrack()
            conn.disconnect()
        }
    }

    suspend fun upload(size: Int, counter: AtomicLong) {
        val conn = connect("$HOST/__up")
        track(conn)
        try {
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setFixedLengthStreamingMode(size)
            conn.setRequestProperty("Content-Type", "application/octet-stream")
            val chunk = ByteArray(64 * 1024)
            conn.outputStream.use { out ->
                var left = size
                while (left > 0 && kotlin.coroutines.coroutineContext.isActive) {
                    val n = minOf(left, chunk.size)
                    out.write(chunk, 0, n)
                    counter.addAndGet(n.toLong())
                    left -= n
                }
            }
            conn.responseCode
        } finally {
            untrack()
            conn.disconnect()
        }
    }

    private suspend fun track(conn: HttpURLConnection) {
        kotlin.coroutines.coroutineContext[Job]?.let { open[it] = conn }
    }

    private suspend fun untrack() {
        kotlin.coroutines.coroutineContext[Job]?.let { open.remove(it) }
    }

    /** 시간이 다 되면 아직 받는(올리는) 연결을 끊는다 — 막혀 있는 read/write를 풀어 준다 */
    fun abort(jobs: List<Job>) {
        jobs.forEach { job -> open.remove(job)?.let { runCatching { it.disconnect() } } }
    }
}
