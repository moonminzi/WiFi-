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
            state.value = newState
        }
    }

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

    fun config(reg: Registration, serverPub: String, endpoint: String, adblock: Boolean): Config =
        Config.Builder()
            .setInterface(
                Interface.Builder()
                    .setKeyPair(reg.keyPair)
                    .addAddress(InetNetwork.parse("${reg.address}/32"))
                    .addDnsServer(InetAddress.getByName(if (adblock) "10.53.53.53" else "1.1.1.1"))
                    .setMtu(1420)
                    .build()
            )
            .addPeer(
                Peer.Builder()
                    .setPublicKey(Key.fromBase64(serverPub))
                    .parseEndpoint(endpoint)
                    .addAllowedIp(InetNetwork.parse("0.0.0.0/0"))
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
