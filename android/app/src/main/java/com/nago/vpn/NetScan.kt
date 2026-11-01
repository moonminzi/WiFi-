package com.nago.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.http.X509TrustManagerExtensions
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetAddress
import java.net.URL
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.UUID
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlin.math.abs

/**
 * 지금 붙어 있는 네트워크(공용 와이파이 등)를 검사한다(iOS NetScan과 같은 항목·판정). 하나씩 차례로 돌며 결과가 한 줄씩 쌓인다.
 * - link: 회선 종류·IPv4/IPv6·데이터 절약
 * - portal: captive.apple.com이 그대로 오는지(로그인 창·HTTP 바꿔치기)
 * - dns: one.one.one.one이 1.1.1.1로 오는지(답 바꿔치기)
 * - nxdomain: 없는 이름에 주소를 주는지(광고·포털 DNS)
 * - doh: 암호화 DNS(1.1.1.1 DoH)가 열려 있는지
 * - tls: apple.com 인증서가 시스템 루트로 이어지는지(사용자가 넣은 루트면 엿볼 수 있음)
 * - ipv6: VPN이 켜져 있을 때 IPv6로 새는지
 * - exit: 밖에서 보이는 IP·나라
 * - quality: 가장 가까운 서버까지 왕복·흔들림·손실
 */
class NetScan {
    enum class Level { Pass, Info, Warn, Fail }

    data class Check(val id: String, val detail: String, val level: Level)

    val checks = mutableStateListOf<Check>()
    var running by mutableStateOf(false)
        private set
    /** 끝난 시각(epoch ms) */
    var finishedAt by mutableStateOf<Long?>(null)
        private set
    /** 지금 보는 검사 이름 */
    var current by mutableStateOf<String?>(null)
        private set

    val score: Int
        get() = maxOf(0, 100 - checks.fold(0) { sum, check ->
            sum + when (check.level) {
                Level.Fail -> 35
                Level.Warn -> 12
                else -> 0
            }
        })

    val grade: String
        get() = when (score) {
            in 90..Int.MAX_VALUE -> "A"
            in 75 until 90 -> "B"
            in 55 until 75 -> "C"
            in 35 until 55 -> "D"
            else -> "F"
        }

    val hasProblems get() = checks.any { it.level == Level.Warn || it.level == Level.Fail }

    /**
     * @param vpnOn 지금 VPN이 켜져 있는지(ipv6·exit 판정이 달라진다)
     * @param expected 켜져 있다면 나가야 하는 나라
     */
    suspend fun run(context: Context, vpnOn: Boolean, expected: VpnRegion?) {
        if (running) return
        running = true
        checks.clear()
        finishedAt = null
        try {
            if (Demo.on) {
                for (check in Demo.checks) {
                    current = check.id
                    kotlinx.coroutines.delay(120)
                    checks += check
                }
                return
            }
            step("link") { Probes.link(context) }
            step("portal") { Probes.portal() }
            step("dns") { Probes.dns() }
            step("nxdomain") { Probes.nxdomain() }
            step("doh") { Probes.doh() }
            step("tls") { Probes.tls() }
            step("ipv6") { Probes.ipv6(context, vpnOn, expected) }
            step("exit") { Probes.exit(vpnOn, expected) }
            step("quality") { Probes.quality() }
        } finally {
            running = false
            current = null
            finishedAt = System.currentTimeMillis()
        }
    }

    /** 스크린샷용: 검사 도중(레이더가 도는 중) 모습 */
    fun showDemo(running: Boolean) {
        this.running = running
        checks.clear()
        checks += if (running) Demo.checks.take(4) else Demo.checks
        current = if (running) order[4] else null
        finishedAt = if (running) null else System.currentTimeMillis() - 8_000
    }

    private suspend fun step(id: String, probe: suspend () -> Check) {
        current = id
        checks += withContext(Dispatchers.IO) { probe() }
    }

    companion object {
        val order = listOf("link", "portal", "dns", "nxdomain", "doh", "tls", "ipv6", "exit", "quality")
    }
}

/** 검사 하나하나(IO 스레드에서 돈다) */
private object Probes {
    private fun check(id: String, detail: String, level: NetScan.Level) = NetScan.Check(id, detail, level)

    fun link(context: Context): NetScan.Check {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        // VPN이 켜져 있으면 기본 망이 VPN이다 → 그 밑의 실제 회선을 본다
        val networks = cm.allNetworks.mapNotNull { n -> cm.getNetworkCapabilities(n)?.let { n to it } }
        val active = cm.activeNetwork
        val physical = networks.firstOrNull { (_, caps) ->
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        } ?: return if (active == null) check("link", "offline · no route", NetScan.Level.Fail)
        else check("link", "no path info", NetScan.Level.Warn)
        val (network, caps) = physical
        val kind = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wi-fi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
        val addresses = cm.getLinkProperties(network)?.linkAddresses.orEmpty().map { it.address }
        val v4 = addresses.any { it is Inet4Address }
        val v6 = addresses.any { it is java.net.Inet6Address && !it.isLinkLocalAddress }
        val bits = mutableListOf(kind, if (v4 && v6) "ipv4+ipv6" else if (v6) "ipv6 only" else "ipv4")
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) bits += "metered"
        if (cm.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED) bits += "low data"
        return check("link", bits.joinToString(" · "), NetScan.Level.Info)
    }

    fun portal(): NetScan.Check {
        val result = load("http://captive.apple.com/hotspot-detect.html")
            ?: return check("portal", "apple check unreachable", NetScan.Level.Warn)
        return if (result.first == 200 && "Success" in result.second) check("portal", "no login page · http untouched", NetScan.Level.Pass)
        else check("portal", "login page or http rewritten in transit", NetScan.Level.Warn)
    }

    suspend fun dns(): NetScan.Check {
        val answers = resolve("one.one.one.one") ?: return check("dns", "resolver didn't answer", NetScan.Level.Warn)
        return if ("1.1.1.1" in answers || "1.0.0.1" in answers) check("dns", "one.one.one.one → 1.1.1.1 ✓", NetScan.Level.Pass)
        else check("dns", "answers rewritten → ${answers.firstOrNull() ?: "?"}", NetScan.Level.Fail)
    }

    suspend fun nxdomain(): NetScan.Check {
        val label = "nago-" + UUID.randomUUID().toString().replace("-", "").take(10)
        val first = resolve("$label.example.com")?.firstOrNull()
        return if (first != null) check("nxdomain", "missing names answered → $first (ad dns)", NetScan.Level.Warn)
        else check("nxdomain", "missing names stay missing", NetScan.Level.Pass)
    }

    fun doh(): NetScan.Check {
        val result = load("https://1.1.1.1/dns-query?name=one.one.one.one&type=A", accept = "application/dns-json")
        return if (result != null && result.first == 200 && "1.1.1.1" in result.second) check("doh", "encrypted dns reachable", NetScan.Level.Pass)
        else check("doh", "encrypted dns blocked · try unicorn or wg", NetScan.Level.Warn)
    }

    /** 인증서가 기기에 원래 있던 루트로 이어지는지, 사용자가 넣은 루트(회사·검열 장비 프록시가 흔히 이렇다)로 이어지는지 */
    fun tls(): NetScan.Check {
        val host = "www.apple.com"
        val conn = URL("https://$host/library/test/success.html").openConnection() as HttpsURLConnection
        return try {
            conn.connectTimeout = 5_000
            conn.readTimeout = 5_000
            conn.useCaches = false
            conn.setRequestProperty("Connection", "close")
            conn.responseCode
            val chain = conn.serverCertificates.filterIsInstance<X509Certificate>().toTypedArray()
            val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            tmf.init(null as KeyStore?)
            val tm = tmf.trustManagers.filterIsInstance<X509TrustManager>().first()
            val ext = X509TrustManagerExtensions(tm)
            val trusted = ext.checkServerTrusted(chain, "RSA", host)
            val root = trusted.lastOrNull()
            if (root != null && ext.isUserAddedCertificate(root)) {
                check("tls", "user-installed root trusted · traffic can be inspected", NetScan.Level.Warn)
            } else {
                check("tls", "chain ends at a system root", NetScan.Level.Pass)
            }
        } catch (e: SSLHandshakeException) {
            check("tls", "certificate rejected · interception?", NetScan.Level.Fail)
        } catch (e: java.security.cert.CertificateException) {
            check("tls", "certificate rejected · interception?", NetScan.Level.Fail)
        } catch (e: Exception) {
            check("tls", "https unreachable", NetScan.Level.Warn)
        } finally {
            conn.disconnect()
        }
    }

    fun ipv6(context: Context, vpnOn: Boolean, expected: VpnRegion?): NetScan.Check {
        if (!vpnOn) {
            val cm = context.getSystemService(ConnectivityManager::class.java)
            val v6 = cm.allNetworks.any { n ->
                cm.getLinkProperties(n)?.linkAddresses.orEmpty().any { it.address is java.net.Inet6Address && !it.address.isLinkLocalAddress }
            }
            return check("ipv6", if (v6) "ipv6 available · rescan with vpn on to test leaks" else "ipv4 only", NetScan.Level.Info)
        }
        val result = load("https://[2606:4700:4700::1111]/cdn-cgi/trace")
            ?: return check("ipv6", "no ipv6 path around the tunnel", NetScan.Level.Pass)
        val loc = trace(result.second)["loc"] ?: "?"
        return if (expected != null && loc == expected.countryCode) check("ipv6", "ipv6 also exits in $loc", NetScan.Level.Pass)
        else check("ipv6", "ipv6 leaks outside the vpn → $loc", NetScan.Level.Fail)
    }

    suspend fun exit(vpnOn: Boolean, expected: VpnRegion?): NetScan.Check {
        val info = ExitInfo.fetch() ?: return check("exit", "trace unreachable", NetScan.Level.Warn)
        val head = "${info.ip} · ${info.country}"
        if (!vpnOn || expected == null) return check("exit", head, NetScan.Level.Info)
        return if (info.country == expected.countryCode) check("exit", "$head ✓", NetScan.Level.Pass)
        else check("exit", "$head ≠ ${expected.countryCode}", NetScan.Level.Fail)
    }

    fun quality(): NetScan.Check {
        val nearest = VpnRegion.entries.minBy { Geo.here.km(it.geo) }
        val samples = LatencyProbe.samples(nearest, 6)
        val got = samples.filterNotNull()
        if (got.isEmpty()) return check("quality", "${nearest.name} unreachable", NetScan.Level.Fail)
        val median = got.sorted()[got.size / 2]
        val jitter = got.zipWithNext { a, b -> abs(a - b) }.sum() / maxOf(got.size - 1, 1)
        val lost = samples.size - got.size
        val level = if (lost > 0 || jitter > 30 || median > 250) NetScan.Level.Warn else NetScan.Level.Pass
        return check("quality", "%s %.0fms · jitter %.0fms · loss %d/%d".format(nearest.name, median, jitter, lost, samples.size), level)
    }

    // MARK: 도구

    /** 검사마다 새 연결(VPN을 켜고 끄는 사이에 예전 회선에 묶인 연결을 다시 쓰면 터널 밖으로 나가서 결과가 틀린다) */
    private fun load(url: String, accept: String? = null): Pair<Int, String>? = runCatching {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 5_000
            conn.readTimeout = 5_000
            conn.useCaches = false
            conn.instanceFollowRedirects = false
            conn.setRequestProperty("Connection", "close")
            accept?.let { conn.setRequestProperty("accept", it) }
            val code = conn.responseCode
            val body = (if (code < 400) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            code to body
        } finally {
            conn.disconnect()
        }
    }.getOrNull()

    fun trace(text: String): Map<String, String> = text.lines()
        .mapNotNull { line -> line.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] } }
        .toMap()

    /** 시스템 DNS로 IPv4 주소를 찾는다(4초 안에 안 오면 null) */
    suspend fun resolve(host: String): List<String>? {
        // 막힌 조회는 취소되지 않으니 따로 띄워 두고 기다리기만 한다(coroutineScope면 끝날 때까지 붙잡힌다)
        val lookup = CoroutineScope(Dispatchers.IO).async {
            runCatching { InetAddress.getAllByName(host).filterIsInstance<Inet4Address>().mapNotNull { it.hostAddress } }
                .getOrNull()?.takeIf { it.isNotEmpty() }
        }
        return withTimeoutOrNull(4_000) { lookup.await() }
    }
}
