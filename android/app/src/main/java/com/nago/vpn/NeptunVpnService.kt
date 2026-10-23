package com.nago.vpn

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.VpnService
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

/**
 * 앱 안 WireGuard의 NepTUN 엔진(NordVPN의 Rust 엔진). VpnService가 만든 TUN을 엔진 스레드가 직접 읽고 쓴다.
 * 앱 자신은 VPN에서 빼 둬서(addDisallowedApplication) 엔진의 UDP 소켓과 국가 API 요청은 터널 밖으로 나간다.
 * 핸드셰이크가 끊기면(서버 유휴 종료, 재부팅으로 IP 변경) 국가 API로 서버를 깨우고 새 주소로 바꾼다.
 * 시스템이 다시 띄우면(항상 켜기, 프로세스 재시작) 마지막으로 연결한 설정으로 다시 붙는다.
 */
class NeptunVpnService : VpnService() {
    data class Session(
        val privateKey: String,     // base64
        val address: String,        // 10.9.0.x
        val serverPub: String,
        val endpoint: String,       // ip:port
        val dns: List<String>,
        val allowLan: Boolean,
        val region: String,
        val apiKey: String,
    )

    companion object {
        private const val ACTION_STOP = "com.nago.vpn.NEPTUN_STOP"
        /** NordVPN(libtelio)과 같게 안드로이드는 이벤트 루프 4개 */
        private const val THREADS = 4

        val up = MutableStateFlow(false)
        val failure = MutableStateFlow<String?>(null)
        @Volatile private var pending: Session? = null

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
            throw IllegalStateException("neptun: start timeout")
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
            )
        }.getOrNull()

        private fun apiKey(context: Context): String? =
            runCatching { context.assets.open("preset.txt").bufferedReader().use { it.readText().trim() } }
                .getOrNull()?.takeIf { it.isNotEmpty() }
                ?: prefs(context).getString("pw", null)?.takeIf { it.isNotEmpty() }
    }

    private val lock = Any()
    private var handle = 0L
    @Volatile private var session: Session? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var watchdog: Job? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        NagoLog.init(this)
        if (intent?.action == ACTION_STOP) {
            teardown("stop")
            stopSelf()
            return START_NOT_STICKY
        }
        // 앱이 넘긴 설정, 없으면(시스템이 다시 띄움) 마지막으로 연결한 설정
        val s = pending ?: restore(this)
        pending = null
        if (s == null) {
            fail("neptun: no saved config")
            return START_NOT_STICKY
        }
        bringUp(s)
        return START_STICKY
    }

    override fun onRevoke() {
        teardown("revoked")
        super.onRevoke()
    }

    override fun onDestroy() {
        teardown(null)
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
            .addDisallowedApplication(packageName)
            .setMetered(false)
        s.dns.forEach { builder.addDnsServer(it) }
        (Routes.ipv4(s.allowLan) + "::/0").forEach { cidr ->
            val (ip, length) = cidr.split('/')
            builder.addRoute(ip, length.toInt())
        }
        val tun = runCatching { builder.establish() }.getOrNull()
        if (tun == null) {
            fail("neptun: vpn permission missing")
            return
        }
        val fd = tun.detachFd()
        val h = NeptunNative.start(fd, uapi(s, withKey = true), THREADS)
        if (h == 0L) {
            val error = NeptunNative.lastError() ?: "unknown"
            // 엔진이 TUN을 넘겨받기 전에 실패했으면 직접 닫는다(넘겨받았으면 엔진이 이미 닫음).
            if (error.startsWith("tun fd") || error.startsWith("uapi is not")) {
                runCatching { ParcelFileDescriptor.adoptFd(fd).close() }
            }
            fail("neptun: $error")
            return
        }
        synchronized(lock) { handle = h }
        session = s
        up.value = true
        NagoLog.add("neptun: up → ${s.endpoint}")
        watchNetwork()
        startWatchdog()
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
        val stopped = synchronized(lock) {
            val h = handle
            handle = 0L
            if (h != 0L) NeptunNative.stop(h)
            h != 0L
        }
        if (stopped && reason != null) NagoLog.add("neptun: $reason")
        session = null
        up.value = false
    }

    /** 와이파이↔모바일 데이터가 바뀌면 엔진이 서버에 맞춰 연결해 둔 소켓을 새로 만든다. */
    private fun watchNetwork() {
        var current: Network? = null
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val previous = current
                current = network
                if (previous == null || previous == network) return
                synchronized(lock) { if (handle != 0L) NeptunNative.networkChanged(handle) }
                NagoLog.add("neptun: network changed")
            }
        }
        // 앱은 VPN에서 빠져 있어서 앱 기준 기본 망 = 실제 와이파이/모바일 데이터
        getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(cb)
        networkCallback = cb
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
            val target = RegionApi.waitUntilReady(region, s.apiKey) { NagoLog.add(it) }
            val endpoint = "${target.address}:${target.wgPort}"
            val serverPub = target.wgPub ?: s.serverPub
            if (endpoint == s.endpoint && serverPub == s.serverPub) {
                NagoLog.add("${s.region}: up · $endpoint")
                return
            }
            val next = s.copy(endpoint = endpoint, serverPub = serverPub)
            val rc = synchronized(lock) { if (handle != 0L) NeptunNative.set(handle, uapi(next, withKey = false)) else -1 }
            if (rc == 0) {
                session = next
                save(this, next)
                NagoLog.add("${s.region}: endpoint → $endpoint")
            } else {
                NagoLog.add("✗ neptun: uapi set errno $rc")
            }
        } catch (e: Exception) {
            NagoLog.add("✗ ${s.region}: ${e.message}")
        }
    }

    /** 서버(피어) 하나짜리 UAPI 설정. 키는 base64 그대로(엔진이 16진수로 바꿈). */
    private fun uapi(s: Session, withKey: Boolean) = buildString {
        append("set=1\n")
        if (withKey) append("private_key=${s.privateKey}\n")
        append("replace_peers=true\n")
        append("public_key=${s.serverPub}\n")
        append("endpoint=${s.endpoint}\n")
        append("persistent_keepalive_interval=25\n")
        append("replace_allowed_ips=true\n")
        append("allowed_ip=0.0.0.0/0\n")
        append("allowed_ip=::/0\n")
        append("\n")
    }
}
