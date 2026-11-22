package com.nago.vpn

import android.net.Network
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * 나갈 국가(iOS VPNRegion과 같다). kr jp us uk는 그 나라 Vultr 지역에 서버가 하나씩 늘 켜져 있다(2026-11 AWS에서 옮김).
 * 그 뒤 나라들은 임시 서버([onDemand]): 고르면 API가 그 지역에 Vultr 서버를 새로 만들고(WireGuard만, 1~2분),
 * 30분 안 쓰면 컨트롤 서버가 지운다(한꺼번에 2대까지).
 * 순서를 바꾸거나 빼지 말 것: 지도 데이터의 나라 번호가 이 순서다.
 * [awsRegion]은 왕복 시간을 잴 때 묻는 근처 AWS 리전(DynamoDB /ping, 계정 없이 됨)이다.
 */
enum class VpnRegion(val city: String, val vultrRegion: String, val awsRegion: String) {
    kr("seoul", "icn", "ap-northeast-2"),
    jp("tokyo", "nrt", "ap-northeast-1"),
    us("seattle", "sea", "us-west-2"),
    uk("london", "lhr", "eu-west-2"),
    sg("singapore", "sgp", "ap-southeast-1"),
    de("frankfurt", "fra", "eu-central-1"),
    fr("paris", "cdg", "eu-west-3"),
    ie("dublin", "-", "eu-west-1"),
    se("stockholm", "sto", "eu-north-1"),
    ca("toronto", "yto", "ca-central-1"),
    br("são paulo", "sao", "sa-east-1"),
    au("sydney", "syd", "ap-southeast-2"),
    `in`("mumbai", "bom", "ap-south-1");

    /** 고를 때 서버를 새로 만드는 나라 */
    val onDemand: Boolean get() = this !in fixed

    /** 지금 고를 수 있는 나라. 아일랜드는 Vultr에 지역이 없어서 숨긴다(지도 번호 때문에 항목은 남김) */
    val available: Boolean get() = this != ie

    /** `tokyo · nrt` 처럼 보여 줄 한 줄 (뒤는 Vultr 지역 코드) */
    val detail: String get() = "$city · $vultrRegion" + if (onDemand) " · on demand" else ""

    /** API가 안 될 때 바로 붙어 볼 주소/ID. 한국 서버만 있다(API도 같은 서버에서 돈다). */
    val fallback: Target?
        get() = if (this == kr) Target("141.164.54.197", "141.164.54.197", justBooted = false) else null

    companion object {
        /** 늘 있는 서버 */
        val fixed = listOf(kr, jp, us, uk)
    }
}

/**
 * 접속할 서버. [identifier]는 서버 인증서의 ID(한국은 IP, 해외는 jp.nago.vpn 같은 FQDN).
 * [wgPub]/[wgPort]는 그 서버의 WireGuard 공개키와 포트(443 → 서버에서 51820으로).
 */
data class Target(
    val address: String,
    val identifier: String,
    val justBooted: Boolean,
    val wgPub: String? = null,
    val wgPort: Int = 443,
)

sealed class ApiError(message: String) : Exception(message) {
    object Forbidden : ApiError("403 forbidden: wrong password")
    class Bad(val code: Int) : ApiError("api error: http $code")
    object Timeout : ApiError("timeout: server not up after 4m, retry")
    /** 임시 서버가 이미 최대 개수만큼 떠 있다 */
    object TooManyServers : ApiError("409: 2 temp servers already up · they delete after 30m idle")
}

/** 국가별 서버의 지금 주소·ID·WireGuard 키를 받아 오는 API (서울 Vultr 서버, 8443). 인증은 VPN 비밀번호로 한다. */
object RegionApi {
    private const val ENDPOINT = "https://141.164.54.197:8443/region"

    private class Status(
        val state: String, val ready: Boolean, val ip: String?, val id: String,
        val wgPub: String?, val wgPort: Int,
    )

    /** [via]: 이 망으로 묻는다(터널이 죽었을 때 NagoTun 서비스가 실제 와이파이·모바일 데이터로 서버를 깨운다) */
    private suspend fun status(region: VpnRegion, key: String, via: Network?): Status = withContext(Dispatchers.IO) {
        val url = URL("$ENDPOINT?r=${region.name}")
        val conn = (via?.openConnection(url) ?: url.openConnection()) as HttpURLConnection
        try {
            conn.connectTimeout = 10_000
            // 임시 서버를 처음 만드는 요청은 10초 가까이 걸린다
            conn.readTimeout = if (region.onDemand) 28_000 else 15_000
            conn.setRequestProperty("x-nago-key", key)
            val code = conn.responseCode
            if (code == 403) throw ApiError.Forbidden
            if (code == 409) throw ApiError.TooManyServers
            if (code != 200) throw ApiError.Bad(code)
            val json = JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
            Status(
                state = json.getString("state"),
                ready = json.getBoolean("ready"),
                ip = if (json.isNull("ip")) null else json.getString("ip"),
                id = json.getString("id"),
                wgPub = if (json.isNull("wgPub")) null else json.optString("wgPub").takeIf { it.isNotEmpty() },
                wgPort = json.optInt("wgPort", 443),
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
    suspend fun waitUntilReady(region: VpnRegion, key: String, via: Network? = null, progress: (String) -> Unit): Target {
        val deadline = System.currentTimeMillis() + 240_000
        var waited = false
        var lastError: Exception? = null
        while (true) {
            try {
                val s = status(region, key, via)
                if (s.ready && s.ip != null) return Target(s.ip, s.id, waited, s.wgPub, s.wgPort)
                lastError = null
                progress(
                    when (s.state) {
                        "stopping" -> "${region.name}: stopping → restart…"
                        "creating" -> "${region.name}: new server · ~2m"
                        else -> "${region.name}: booting…"
                    }
                )
            } catch (e: ApiError.Forbidden) {
                throw e
            } catch (e: ApiError.TooManyServers) {
                throw e
            } catch (e: CancellationException) {
                throw e    // 취소는 재시도하지 않는다
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
