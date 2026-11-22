package com.nago.vpn

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * 앱 안 WireGuard의 NagoTun 엔진(NepTUN을 고친 Rust 엔진). VpnService가 만든 TUN을 엔진 스레드가 직접 읽고 쓴다.
 * 앱도 VPN 안에 있다(iOS처럼 — 속도 측정·네트워크 검사·출구 확인이 터널을 지나게). 서버로 가는 소켓(엔진의 UDP,
 * nagoing의 UDP·TCP)만 엔진이 만들 때 protect()로 터널 밖으로 뺀다(NagoTun/src/android.rs).
 * nagoing을 켜면 WG를 막힌 망 우회 전송(QUIC 모양 UDP → 막히면 TLS 1.3/TCP 443)으로 감싸고 엔진에 바로 붙인다.
 * 핸드셰이크가 끊기면(서버 유휴 종료, 재부팅으로 IP 변경) 실제 와이파이·모바일 데이터로 국가 API에 물어 서버를 깨우고
 * 새 주소로 바꾼다. 시스템이 다시 띄우면(항상 켜기, 프로세스 재시작) 마지막으로 연결한 설정으로 다시 붙는다.
 */
class NeptunVpnService : VpnService() {
    data class Session(
        val privateKey: String,     // base64
        val address: String,        // 10.9.0.x
        val serverPub: String,
        val endpoint: String,       // ip:port (서버 WG)
        val dns: List<String>,
        val allowLan: Boolean,
        val region: String,
        val apiKey: String,
        /** NagoTun 이벤트 루프 수(settings → loops) */
        val loops: Int = 1,
        /** 막힌 망 우회. null이면 끔(엔진이 서버 WG 포트로 바로 보낸다) */
        val nagoing: NagoingSettings? = null,
    ) {
        val serverIp get() = endpoint.substringBeforeLast(':').trim('[', ']')
    }

    companion object {
        private const val ACTION_STOP = "com.nago.vpn.NEPTUN_STOP"

        val up = MutableStateFlow(false)
        val failure = MutableStateFlow<String?>(null)
        @Volatile private var pending: Session? = null
        /** 지금 엔진을 돌리는 서비스(통계 읽기용) */
        @Volatile private var running: NeptunVpnService? = null

        /**
         * 켜고 끄는 일은 프로세스에 하나뿐인 이 스레드에서 차례로 한다. nagoing은 멈출 때 연결 수립을 기다리느라
         * 몇 초 걸릴 수 있어서 메인 스레드에서 하지 않고, 바로 다시 켤 때 예전 것이 로컬 포트를 놓기 전에 켜지지 않게.
         */
        private val worker = Executors.newSingleThreadExecutor { Thread(it, "nagotun-service") }

        /** 받은·보낸 바이트와 마지막 핸드셰이크. 꺼져 있으면 null. 엔진 잠금을 잡으니 메인 스레드에서 부르지 않는다. */
        fun stats(): LinkStats? = running?.readStats()

        /** nagoing 전송 상태 한 줄("udp · tx .. · rx .. · fec+..") — 켜져 있을 때만 */
        fun transport(): String? = running?.nagoingStats()

        fun start(context: Context, session: Session) {
            pending = session
            failure.value = null
            save(context, session)
            context.startService(Intent(context, NeptunVpnService::class.java))
        }

        fun stop(context: Context) {
            context.startService(Intent(context, NeptunVpnService::class.java).setAction(ACTION_STOP))
        }

        /** 켜질 때까지 기다린다. 실패하면 이유를 던진다. */
        suspend fun awaitUp(timeoutMs: Long) {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (System.currentTimeMillis() < deadline) {
                if (up.value) return
                failure.value?.let { throw IllegalStateException(it) }
                delay(200)
            }
            throw IllegalStateException("NagoTun: start timeout")
        }

        private fun prefs(context: Context) = context.getSharedPreferences("nago", Context.MODE_PRIVATE)

        /** 다시 붙을 때 쓸 설정. 키는 이미 앱 저장소(wgPrivate)에 있고 비밀번호는 내장 값/입력 값을 쓴다. */
        private fun save(context: Context, s: Session) {
            val json = JSONObject()
                .put("address", s.address)
                .put("serverPub", s.serverPub)
                .put("endpoint", s.endpoint)
                .put("dns", JSONArray(s.dns))
                .put("allowLan", s.allowLan)
                .put("region", s.region)
                .put("loops", s.loops)
            s.nagoing?.let { n -> json.put("nagoing", JSONObject().put("prefer", n.prefer).put("fec", n.fec)) }
            prefs(context).edit().putString("neptunSession", json.toString()).apply()
        }

        private fun restore(context: Context): Session? = runCatching {
            val p = prefs(context)
            val o = JSONObject(p.getString("neptunSession", null) ?: return null)
            val key = p.getString("wgPrivate", null) ?: return null
            val dns = o.getJSONArray("dns")
            Session(
                privateKey = key,
                address = o.getString("address"),
                serverPub = o.getString("serverPub"),
                endpoint = o.getString("endpoint"),
                dns = List(dns.length()) { dns.getString(it) },
                allowLan = o.optBoolean("allowLan"),
                region = o.getString("region"),
                apiKey = apiKey(context) ?: "",
                loops = o.optInt("loops", 1),
                nagoing = o.optJSONObject("nagoing")?.let { NagoingSettings(prefer = it.optString("prefer", "auto"), fec = it.optBoolean("fec", true)) },
            )
        }.getOrNull()

        private fun apiKey(context: Context): String? =
            runCatching { context.assets.open("preset.txt").bufferedReader().use { it.readText().trim() } }
                .getOrNull()?.takeIf { it.isNotEmpty() }
                ?: prefs(context).getString("pw", null)?.takeIf { it.isNotEmpty() }
    }

    private val lock = Any()
    private var handle = 0L
    /** nagoing 클라이언트(켰을 때만) */
    private var nagoing = 0L
    @Volatile private var session: Session? = null
    /** VPN 밑의 실제 회선(와이파이·모바일 데이터). 터널이 죽었을 때 국가 API를 여기로 묻는다 */
    @Volatile private var underlying: Network? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var watchdog: Job? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        NagoLog.catchCrashes(this)
        if (intent?.action == ACTION_STOP) {
            worker.execute {
                teardown("stop")
                // 그사이 새 연결(갈아타기)이 들어왔으면 서비스는 남겨 둔다 — 가장 최근 요청일 때만 멈춘다
                stopSelfResult(startId)
            }
            return START_NOT_STICKY
        }
        // 앱이 넘긴 설정, 없으면(시스템이 다시 띄움) 마지막으로 연결한 설정
        val s = pending ?: restore(this)
        pending = null
        if (s == null) {
            fail("NagoTun: no saved config")
            return START_NOT_STICKY
        }
        worker.execute {
            // 여기서 예외가 나면 앱 프로세스째 죽고, START_STICKY라 시스템이 다시 띄우며 또 죽는다 → 실패로 돌린다
            try {
                bringUp(s)
            } catch (e: Exception) {
                teardown(null)
                fail("NagoTun: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
        return START_STICKY
    }

    override fun onRevoke() {
        worker.execute { teardown("revoked") }
        super.onRevoke()
    }

    override fun onDestroy() {
        worker.execute { teardown(null) }
        scope.cancel()
        super.onDestroy()
    }

    private fun bringUp(s: Session) {
        teardown(null)
        val builder = Builder()
            .setSession("NAGO VPN")
            .setMtu(1420)
            .addAddress(s.address, 32)
            // IPv6도 터널로 받아서(서버엔 IPv6가 없으니 버려짐) 진짜 IP가 IPv6로 새지 않게 한다
            .addAddress("fd09::" + s.address.substringAfterLast('.'), 128)
            .setMetered(false)
        s.dns.forEach { builder.addDnsServer(it) }
        (Routes.ipv4(s.allowLan) + "::/0").forEach { cidr ->
            val (ip, length) = cidr.split('/')
            builder.addRoute(ip, length.toInt())
        }
        val tun = runCatching { builder.establish() }.getOrNull()
        if (tun == null) {
            fail("NagoTun: vpn permission missing")
            return
        }
        val protectFailures = NeptunNative.protectFailures()
        val fd = tun.detachFd()
        // nagoing을 먼저 띄운다(iOS와 같은 순서) — 엔진은 기기 안 로컬 포트(nagoing)로 보내고, 엔진이 뜨면 바로 붙인다
        s.nagoing?.let { ns ->
            NagoLog.add("start nagoing · ${ns.summary} → ${s.serverIp}:${ns.udpPort}")
            if (startNagoing(s, s.serverIp, s.serverPub) == 0L) {
                runCatching { ParcelFileDescriptor.adoptFd(fd).close() }
                fail("nagoing: ${NeptunNative.lastError() ?: "start failed"}")
                return
            }
        }
        val engineEndpoint = s.nagoing?.let { "127.0.0.1:${it.localPort}" } ?: s.endpoint
        val h = NeptunNative.start(this, fd, uapi(s, engineEndpoint, withKey = true), s.loops.coerceIn(1, 2))
        if (h == 0L) {
            val error = NeptunNative.lastError() ?: "unknown"
            // 엔진이 TUN을 넘겨받기 전에 실패했으면 직접 닫는다(넘겨받았으면 엔진이 이미 닫음).
            if (error.startsWith("tun fd") || error.startsWith("uapi is not")) {
                runCatching { ParcelFileDescriptor.adoptFd(fd).close() }
            }
            teardown(null)
            fail("NagoTun: $error")
            return
        }
        synchronized(lock) { handle = h }
        if (s.nagoing != null) attachNagoing()
        if (NeptunNative.protectFailures() > protectFailures) {
            NagoLog.add("✗ NagoTun: protect failed — engine socket stays in the tunnel")
        }
        session = s
        running = this
        up.value = true
        NagoLog.add("NagoTun: up → ${s.endpoint}" + if (s.nagoing != null) " · nagoing" else "")
        LinkMonitor.start { stats() }
        watchNetwork()
        startWatchdog()
    }

    /** nagoing 클라이언트를 띄운다(엔진이 떠 있으면 바로 붙인다). 실패하면 0 */
    private fun startNagoing(s: Session, serverIp: String, serverPub: String): Long {
        val ns = s.nagoing ?: return 0L
        val client = NagoingNative.start(
            this, serverIp, ns.udpPort, ns.tcpPort, ns.localPort, ns.fecK, ns.fecGroups, if (ns.fec) 1 else 0,
            ns.preferCode, ns.sni, s.privateKey, serverPub,
        )
        if (client == 0L) return 0L
        synchronized(lock) { nagoing = client }
        if (synchronized(lock) { handle != 0L }) attachNagoing()
        return client
    }

    /** 엔진 ↔ nagoing 직결(로컬 UDP 홉 없음). 안 되면 로컬 포트로 그대로 돈다 */
    private fun attachNagoing() {
        val attached = synchronized(lock) { handle != 0L && nagoing != 0L && NagoingNative.attach(nagoing, handle) == 0 }
        NagoLog.add(if (attached) "nagoing: attached to NagoTun" else "nagoing: local hop")
    }

    private fun fail(message: String) {
        NagoLog.add("✗ $message")
        failure.value = message
        up.value = false
        stopSelf()
    }

    private fun teardown(reason: String?) {
        watchdog?.cancel()
        watchdog = null
        networkCallback?.let { cb ->
            runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(cb) }
        }
        networkCallback = null
        underlying = null
        val (h, client) = synchronized(lock) {
            val pair = handle to nagoing
            handle = 0L
            nagoing = 0L
            pair
        }
        if (h != 0L) NeptunNative.stop(h)
        // 엔진을 먼저 멈춰도 된다(nagoing이 멈출 땐 엔진에서 스스로 떨어진다). 수립 중이면 몇 초 걸린다(이 스레드는 일꾼 스레드)
        if (client != 0L) NagoingNative.stop(client)
        if (h != 0L && reason != null) NagoLog.add("NagoTun: $reason")
        session = null
        // 다른(새) 서비스가 이미 돌고 있으면 그쪽 상태는 건드리지 않는다(예전 서비스가 늦게 내려갈 때)
        val mine = running === this
        if (mine) {
            running = null
            LinkMonitor.stop()
        }
        if (mine || running == null) up.value = false
    }

    private fun readStats(): LinkStats? {
        val text = synchronized(lock) { if (handle != 0L) NeptunNative.get(handle) else null } ?: return null
        var rx = 0L
        var tx = 0L
        var sec = 0L
        var nsec = 0L
        text.lineSequence().forEach { line ->
            val value = line.substringAfter('=').toLongOrNull() ?: return@forEach
            when (line.substringBefore('=')) {
                "rx_bytes" -> rx += value
                "tx_bytes" -> tx += value
                "last_handshake_time_sec" -> sec = maxOf(sec, value)
                "last_handshake_time_nsec" -> nsec = value
            }
        }
        return LinkStats(rx, tx, if (sec > 0) sec * 1000 + nsec / 1_000_000 else 0L)
    }

    private fun nagoingStats(): String? =
        synchronized(lock) { if (nagoing != 0L) NagoingNative.stats(nagoing) else null }?.takeIf { it.isNotEmpty() }

    /**
     * VPN 밑의 실제 회선을 따라간다(앱은 VPN 안이라 기본 망 콜백은 VPN 자신을 준다 → VPN이 아닌 망 중 시스템이 고른 것).
     * 와이파이↔모바일 데이터가 바뀌면 엔진·nagoing이 서버로 가는 소켓을 새로 만들고, 시스템에 밑 회선을 알려 준다
     * (데이터 절약·요금제 표시가 실제 회선을 따르게).
     */
    private fun watchNetwork() {
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val previous = underlying
                underlying = network
                runCatching { setUnderlyingNetworks(arrayOf(network)) }
                if (previous == null || previous == network) return
                synchronized(lock) {
                    if (handle != 0L) NeptunNative.networkChanged(handle)
                    if (nagoing != 0L) NagoingNative.networkChanged(nagoing)
                }
                NagoLog.add("NagoTun: network changed")
            }

            override fun onLost(network: Network) {
                if (underlying == network) underlying = null
            }
        }
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        // 못 걸어도(권한 등) 터널은 그대로 두고 로그만 남긴다 — 망이 바뀌면 watchdog이 핸드셰이크로 알아챈다
        runCatching {
            getSystemService(ConnectivityManager::class.java)
                .registerBestMatchingNetworkCallback(request, cb, Handler(Looper.getMainLooper()))
        }
            .onSuccess { networkCallback = cb }
            .onFailure { NagoLog.add("! NagoTun: network watch off (${it.message})") }
    }

    /**
     * 핸드셰이크가 오래 없으면(서버가 꺼졌거나 IP가 바뀜) 국가 API로 서버를 켜고 주소가 바뀌었으면 피어를 바꾼다.
     * keepalive(25초) 덕에 정상이면 2분마다 새 핸드셰이크가 생기므로 170초를 넘으면 끊긴 것으로 본다.
     */
    private fun startWatchdog() {
        val started = System.currentTimeMillis()
        watchdog = scope.launch {
            var lastWake = 0L
            delay(15_000)
            while (isActive) {
                val text = synchronized(lock) { if (handle != 0L) NeptunNative.get(handle) else null } ?: break
                val handshake = text.lineSequence()
                    .firstOrNull { it.startsWith("last_handshake_time_sec=") }
                    ?.substringAfter('=')?.toLongOrNull() ?: 0L
                val now = System.currentTimeMillis()
                val stale = if (handshake > 0) now / 1000 - handshake > 170 else now - started > 15_000
                if (stale && now - lastWake > 60_000) {
                    lastWake = now
                    wake()
                }
                delay(20_000)
            }
        }
    }

    private suspend fun wake() {
        val s = session ?: return
        val region = runCatching { VpnRegion.valueOf(s.region) }.getOrNull() ?: return
        if (s.apiKey.isEmpty()) return
        NagoLog.add("${s.region}: no handshake → api")
        try {
            // 터널이 죽어 있으니 실제 회선으로 묻는다(앱은 VPN 안이라 그냥 물으면 죽은 터널로 들어간다)
            val target = RegionApi.waitUntilReady(region, s.apiKey, underlying) { NagoLog.add(it) }
            val endpoint = "${target.address}:${target.wgPort}"
            val serverPub = target.wgPub ?: s.serverPub
            if (s.nagoing != null) {
                rebindNagoing(s, target.address, serverPub)
                return
            }
            if (endpoint == s.endpoint && serverPub == s.serverPub) {
                NagoLog.add("${s.region}: up · $endpoint")
                return
            }
            val next = s.copy(endpoint = endpoint, serverPub = serverPub)
            val rc = synchronized(lock) { if (handle != 0L) NeptunNative.set(handle, uapi(next, endpoint, withKey = false)) else -1 }
            if (rc == 0) {
                session = next
                save(this, next)
                NagoLog.add("${s.region}: endpoint → $endpoint")
            } else {
                NagoLog.add("✗ NagoTun: uapi set errno $rc")
            }
        } catch (e: Exception) {
            NagoLog.add("✗ ${s.region}: ${e.message}")
        }
    }

    /**
     * nagoing: 엔진 endpoint는 로컬 포트라 그대로 둔다. 서버 IP나 WG 키(HELLO 인증에 씀)가 바뀌었으면 nagoing만 새로 띄우고,
     * 같으면(서울처럼 고정 IP 서버 재부팅) 전송을 다시 세우라고 알린다.
     */
    private fun rebindNagoing(s: Session, serverIp: String, serverPub: String) {
        if (serverIp == s.serverIp && serverPub == s.serverPub) {
            NagoLog.add("${s.region}: up · $serverIp · nagoing rebind")
            synchronized(lock) { if (nagoing != 0L) NagoingNative.networkChanged(nagoing) }
            return
        }
        val old = synchronized(lock) { nagoing.also { nagoing = 0L } }
        // 예전 것이 로컬 포트를 놓을 때까지 기다린 뒤 새로 띄운다(watchdog 스레드라 막아도 된다)
        if (old != 0L) NagoingNative.stop(old)
        // 기다리는 사이 터널이 멈췄으면 새로 띄우지 않는다
        if (session == null || synchronized(lock) { handle == 0L }) return
        val wgPort = s.endpoint.substringAfterLast(':')
        val next = s.copy(endpoint = "$serverIp:$wgPort", serverPub = serverPub)
        if (startNagoing(next, serverIp, serverPub) == 0L) {
            NagoLog.add("✗ ${s.region}: nagoing restart: ${NeptunNative.lastError()}")
            return
        }
        if (serverPub != s.serverPub) {
            val rc = synchronized(lock) {
                if (handle != 0L) NeptunNative.set(handle, uapi(next, "127.0.0.1:${s.nagoing?.localPort}", withKey = false)) else -1
            }
            if (rc != 0) NagoLog.add("✗ NagoTun: uapi set errno $rc")
        }
        session = next
        save(this, next)
        NagoLog.add("${s.region}: nagoing → $serverIp")
    }

    /** 서버(피어) 하나짜리 UAPI 설정. 키는 base64 그대로(엔진이 16진수로 바꿈). */
    private fun uapi(s: Session, endpoint: String, withKey: Boolean) = buildString {
        append("set=1\n")
        if (withKey) append("private_key=${s.privateKey}\n")
        append("replace_peers=true\n")
        append("public_key=${s.serverPub}\n")
        append("endpoint=$endpoint\n")
        append("persistent_keepalive_interval=25\n")
        append("replace_allowed_ips=true\n")
        append("allowed_ip=0.0.0.0/0\n")
        append("allowed_ip=::/0\n")
        append("\n")
    }
}
