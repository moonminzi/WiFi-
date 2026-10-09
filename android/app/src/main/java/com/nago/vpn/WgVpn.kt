package com.nago.vpn

import android.content.Context
import android.content.SharedPreferences
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import com.wireguard.config.InetNetwork
import com.wireguard.config.Interface
import com.wireguard.config.Peer
import com.wireguard.crypto.Key
import com.wireguard.crypto.KeyPair
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL

/** 프로토콜 선택. auto는 IKEv2를 먼저 해 보고 안 붙으면 WireGuard(udp 443)로 넘어간다. */
enum class VpnProto(val label: String) {
    auto("auto"),
    ikev2("ikev2"),
    wg("wg"),
}

/**
 * 앱 안 WireGuard(wireguard-android의 GoBackend).
 * 이 폰의 키는 처음 한 번 만들어 앱 저장소에 두고, 공개키만 서버 피어 목록에 등록한다(대시보드 Lambda).
 * 같은 키로 다시 등록하면 같은 주소가 오므로, 관리자가 지웠어도 다음 연결 때 저절로 다시 들어간다.
 */
object WgVpn {
    private const val DASH = "https://d6hphd5k56.execute-api.ap-northeast-2.amazonaws.com/?format=json"

    val state = MutableStateFlow(Tunnel.State.DOWN)

    private var backend: GoBackend? = null
    private val tunnel = object : Tunnel {
        override fun getName() = "nago"
        override fun onStateChange(newState: Tunnel.State) {
            if (state.value != newState) NagoLog.add("wg: ${newState.name.lowercase()}")
            state.value = newState
        }
    }

    /**
     * --allow-lan일 때 터널로 보낼 IPv4: 전체에서 사설망(10/8, 172.16/12, 192.168/16), 링크 로컬(169.254/16),
     * 멀티캐스트 이상(224/3)을 뺀 것. 서버 쪽 주소(피어망 10.9.0.0/24, 광고 차단 DNS 10.53.53.53)는 다시 넣는다.
     */
    private val PUBLIC_V4 = listOf(
        "0.0.0.0/5", "8.0.0.0/7", "11.0.0.0/8", "12.0.0.0/6", "16.0.0.0/4", "32.0.0.0/3", "64.0.0.0/2",
        "128.0.0.0/3", "160.0.0.0/5", "168.0.0.0/8", "169.0.0.0/9", "169.128.0.0/10", "169.192.0.0/11",
        "169.224.0.0/12", "169.240.0.0/13", "169.248.0.0/14", "169.252.0.0/15", "169.255.0.0/16", "170.0.0.0/7",
        "172.0.0.0/12", "172.32.0.0/11", "172.64.0.0/10", "172.128.0.0/9", "173.0.0.0/8", "174.0.0.0/7",
        "176.0.0.0/4", "192.0.0.0/9", "192.128.0.0/11", "192.160.0.0/13", "192.169.0.0/16", "192.170.0.0/15",
        "192.172.0.0/14", "192.176.0.0/12", "192.192.0.0/10", "193.0.0.0/8", "194.0.0.0/7", "196.0.0.0/6",
        "200.0.0.0/5", "208.0.0.0/4",
        "10.9.0.0/24", "10.53.53.53/32",
    )

    private fun backend(context: Context) =
        backend ?: GoBackend(context.applicationContext).also { backend = it }

    class Registration(val address: String, val keyPair: KeyPair, val servers: Map<String, String>)

    private fun keyPair(prefs: SharedPreferences): KeyPair {
        prefs.getString("wgPrivate", null)?.let { saved ->
            runCatching { return KeyPair(Key.fromBase64(saved)) }
        }
        return KeyPair().also { prefs.edit().putString("wgPrivate", it.privateKey.toBase64()).apply() }
    }

    private fun savedServers(prefs: SharedPreferences): Map<String, String> = runCatching {
        val o = JSONObject(prefs.getString("wgServers", "{}") ?: "{}")
        o.keys().asSequence().associateWith { o.getJSONObject(it).getString("pub") }
    }.getOrDefault(emptyMap())

    /** 등록 정보. 저장된 게 있으면 바로 쓰고 뒤에서 한 번 더 등록해 둔다(지워졌을 때 복구). */
    suspend fun registration(prefs: SharedPreferences, apiKey: String, name: String): Registration {
        val keys = keyPair(prefs)
        val pub = keys.publicKey.toBase64()
        val address = prefs.getString("wgAddress", null)
        if (prefs.getString("wgRegisteredPub", null) == pub && address != null && savedServers(prefs).isNotEmpty()) {
            CoroutineScope(Dispatchers.IO).launch { runCatching { register(prefs, pub, apiKey, name) } }
            return Registration(address, keys, savedServers(prefs))
        }
        val ip = register(prefs, pub, apiKey, name)
        return Registration(ip, keys, savedServers(prefs))
    }

    private suspend fun register(prefs: SharedPreferences, pub: String, apiKey: String, name: String): String =
        withContext(Dispatchers.IO) {
            val conn = URL(DASH).openConnection() as HttpURLConnection
            try {
                conn.requestMethod = "POST"
                conn.doOutput = true
                conn.connectTimeout = 10_000
                conn.readTimeout = 30_000
                conn.setRequestProperty("x-nago-key", apiKey)
                conn.setRequestProperty("content-type", "application/json")
                val body = JSONObject().put("op", "add").put("pub", pub).put("name", name).toString()
                conn.outputStream.use { it.write(body.toByteArray()) }
                val code = conn.responseCode
                if (code == 403) throw ApiError.Forbidden
                val text = (if (code == 200) conn.inputStream else conn.errorStream)
                    ?.bufferedReader()?.use { it.readText() } ?: ""
                val json = runCatching { JSONObject(text) }.getOrNull()
                if (code != 200 || json?.optBoolean("ok") != true) {
                    throw IllegalStateException(json?.optString("error")?.takeIf { it.isNotEmpty() } ?: "http $code")
                }
                val ip = json.getString("ip")
                val edit = prefs.edit().putString("wgRegisteredPub", pub).putString("wgAddress", ip)
                json.optJSONObject("servers")?.let { edit.putString("wgServers", it.toString()) }
                edit.apply()
                ip
            } finally {
                conn.disconnect()
            }
        }

    fun config(reg: Registration, serverPub: String, endpoint: String, dns: List<String>, allowLan: Boolean): Config =
        Config.Builder()
            .setInterface(
                Interface.Builder()
                    .setKeyPair(reg.keyPair)
                    .addAddress(InetNetwork.parse("${reg.address}/32"))
                    .addDnsServers(dns.map { InetAddress.getByName(it) })
                    .setMtu(1420)
                    .build()
            )
            .addPeer(
                Peer.Builder()
                    .setPublicKey(Key.fromBase64(serverPub))
                    .parseEndpoint(endpoint)
                    .addAllowedIps((if (allowLan) PUBLIC_V4 else listOf("0.0.0.0/0")).map(InetNetwork::parse))
                    // IPv6도 터널로 보내서(서버엔 IPv6가 없으니 막힘) 진짜 IP가 IPv6로 새지 않게 한다
                    .addAllowedIp(InetNetwork.parse("::/0"))
                    .setPersistentKeepalive(25)
                    .build()
            )
            .build()

    suspend fun up(context: Context, config: Config) = withContext(Dispatchers.IO) {
        backend(context).setState(tunnel, Tunnel.State.UP, config)
    }

    suspend fun down(context: Context) = withContext(Dispatchers.IO) {
        runCatching { backend(context).setState(tunnel, Tunnel.State.DOWN, null) }
    }
}
