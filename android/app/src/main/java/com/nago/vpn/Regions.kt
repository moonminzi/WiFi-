package com.nago.vpn

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** 나갈 국가. 국가마다 그 나라 AWS 리전에 IKEv2 서버가 하나씩 있다(iOS 앱과 같은 서버). */
enum class VpnRegion(val detail: String) {
    kr("🇰🇷 seoul · ap-northeast-2"),
    jp("🇯🇵 tokyo · ap-northeast-1"),
    us("🇺🇸 oregon · us-west-2"),
    uk("🇬🇧 london · eu-west-2");

    /** API가 안 될 때 바로 붙어 볼 주소/ID. 고정 IP인 한국 서버만 있다. */
    val fallback: Target?
        get() = if (this == kr) Target("3.38.243.135", "3.38.243.135", justBooted = false) else null
}

/** 접속할 서버. [identifier]는 서버 인증서의 ID(한국은 IP, 해외는 jp.nago.vpn 같은 FQDN). */
data class Target(val address: String, val identifier: String, val justBooted: Boolean)

sealed class ApiError(message: String) : Exception(message) {
    object Forbidden : ApiError("403 forbidden: wrong password")
    class Bad(val code: Int) : ApiError("api error: http $code")
    object Timeout : ApiError("timeout: server not up after 4m, retry")
}

/** 국가별 서버를 켜고 지금 주소를 받아 오는 API (AWS Lambda). 인증은 VPN 비밀번호로 한다. */
object RegionApi {
    private const val ENDPOINT = "https://wqzk1bnms3.execute-api.ap-northeast-2.amazonaws.com/region"

    private class Status(val state: String, val ready: Boolean, val ip: String?, val id: String)

    private suspend fun status(region: VpnRegion, key: String): Status = withContext(Dispatchers.IO) {
        val conn = URL("$ENDPOINT?r=${region.name}").openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 10_000
            conn.readTimeout = 15_000
            conn.setRequestProperty("x-nago-key", key)
            val code = conn.responseCode
            if (code == 403) throw ApiError.Forbidden
            if (code != 200) throw ApiError.Bad(code)
            val json = JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
            Status(
                state = json.getString("state"),
                ready = json.getBoolean("ready"),
                ip = if (json.isNull("ip")) null else json.getString("ip"),
                id = json.getString("id"),
            )
        } finally {
            conn.disconnect()
        }
    }

    /**
     * 서버가 꺼져 있으면 켜고, 접속할 수 있을 때까지 기다렸다가 주소/ID를 돌려준다.
     * 해외 서버는 켜지는 동안 요청이 실패해도(망 전환, 5xx) 마감까지 계속 묻는다.
     * 한국 서버는 고정 IP로 바로 넘어갈 수 있게 첫 실패에서 멈춘다.
     */
    suspend fun waitUntilReady(region: VpnRegion, key: String, progress: (String) -> Unit): Target {
        val deadline = System.currentTimeMillis() + 240_000
        var waited = false
        var lastError: Exception? = null
        while (true) {
            try {
                val s = status(region, key)
                if (s.ready && s.ip != null) return Target(s.ip, s.id, justBooted = waited)
                lastError = null
                progress(
                    if (s.state == "stopping") "${region.name}: stopping, will restart…"
                    else "${region.name}: booting… (1-2 min)"
                )
            } catch (e: ApiError.Forbidden) {
                throw e
            } catch (e: ApiError.Bad) {
                if (e.code in 400..499 && e.code != 429) throw e
                if (region.fallback != null) throw e
                lastError = e
                progress("${region.name}: api retry… (${e.message})")
            } catch (e: Exception) {
                if (region.fallback != null) throw e
                lastError = e
                progress("${region.name}: api retry… (${e.message})")
            }
            waited = true
            if (System.currentTimeMillis() >= deadline) break
            delay(4_000)
        }
        throw lastError ?: ApiError.Timeout
    }
}
