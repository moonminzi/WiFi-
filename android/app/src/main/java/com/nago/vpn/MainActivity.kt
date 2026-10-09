package com.nago.vpn

import android.app.Activity
import android.content.Context
import android.net.VpnManager
import android.net.VpnProfileState
import android.net.VpnService
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wireguard.android.backend.Tunnel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private lateinit var vpnManager: VpnManager
    private var consent: CompletableDeferred<Boolean>? = null

    // 처음 한 번 "VPN 연결 요청" 시스템 허용 창
    private val consentLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        consent?.complete(it.resultCode == Activity.RESULT_OK)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        vpnManager = getSystemService(VpnManager::class.java)
        setContent { VpnScreen() }
    }

    private val prefs by lazy { getSharedPreferences("nago", Context.MODE_PRIVATE) }

    /** 전달용 APK에만 들어가는 내장 비밀번호(assets/preset.txt). 공개 레포라 소스에는 없다. */
    private val preset: String? by lazy {
        runCatching { assets.open("preset.txt").bufferedReader().use { it.readText().trim() } }
            .getOrNull()?.takeIf { it.isNotEmpty() }
    }

    private suspend fun connect(
        region: VpnRegion, user: String, password: String, adblock: Boolean, proto: VpnProto, onPhase: (String?) -> Unit,
    ) {
        onPhase("${region.name}: checking server…")
        val target = try {
            RegionApi.waitUntilReady(region, password) { onPhase(it) }
        } catch (e: ApiError.Forbidden) {
            throw e
        } catch (e: Exception) {
            region.fallback ?: throw e   // 한국 서버는 고정 IP로 바로 시도
        }
        if (target.justBooted) {
            onPhase("${region.name}: up, waiting for ike…")
            delay(5_000)
        }
        when (proto) {
            VpnProto.ikev2 -> connectIke(region, target, user, password, adblock, onPhase)
            VpnProto.wg -> connectWg(region, target, user, password, adblock, onPhase)
            VpnProto.auto -> {
                connectIke(region, target, user, password, adblock, onPhase)
                onPhase("${region.name}: ikev2 handshake…")
                if (!waitForIke(12_000)) {
                    vpnManager.stopProvisionedVpnProfile()
                    onPhase("${region.name}: ikev2 timeout → wg")
                    delay(1_000)
                    connectWg(region, target, user, password, adblock, onPhase)
                }
            }
        }
        prefs.edit().putString("savedRegion", region.name).apply()
    }

    private suspend fun askConsent(intent: android.content.Intent) {
        val waiter = CompletableDeferred<Boolean>().also { consent = it }
        consentLauncher.launch(intent)
        if (!waiter.await()) throw IllegalStateException("vpn permission denied")
    }

    private suspend fun connectIke(
        region: VpnRegion, target: Target, user: String, password: String, adblock: Boolean, onPhase: (String?) -> Unit,
    ) {
        WgVpn.down(this)
        onPhase("${region.name}: ikev2 → ${target.address}")
        val profile = NagoVpn.profile(this, target, user, password, adblock)
        vpnManager.provisionVpnProfile(profile)?.let { intent ->
            askConsent(intent)
            vpnManager.provisionVpnProfile(profile)
        }
        VpnEvents.lastEvent.value = null
        vpnManager.startProvisionedVpnProfileSession()
    }

    /** IKEv2가 연결될 때까지 기다린다. 시간 안에 안 되거나 실패하면 false. */
    private suspend fun waitForIke(timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            when (runCatching { vpnManager.provisionedVpnProfileState?.state }.getOrNull()) {
                VpnProfileState.STATE_CONNECTED -> return true
                VpnProfileState.STATE_FAILED -> return false
            }
            delay(400)
        }
        return false
    }

    /** 이 폰의 WireGuard 키를 (처음이면) 서버에 등록하고, 고른 국가 서버로 터널을 연다. */
    private suspend fun connectWg(
        region: VpnRegion, target: Target, user: String, password: String, adblock: Boolean, onPhase: (String?) -> Unit,
    ) {
        vpnManager.stopProvisionedVpnProfile()
        VpnService.prepare(this)?.let { askConsent(it) }
        onPhase("${region.name}: wg register…")
        val reg = WgVpn.registration(prefs, password, "$user android app")
        val serverPub = target.wgPub ?: reg.servers[region.name]
            ?: throw IllegalStateException("no wireguard key for ${region.name}")
        val endpoint = "${target.address}:${target.wgPort}"
        onPhase("${region.name}: wg → $endpoint")
        WgVpn.up(this, WgVpn.config(reg, serverPub, endpoint, adblock))
    }

    @Composable
    private fun VpnScreen() {
        val scope = rememberCoroutineScope()
        var region by remember { mutableStateOf(VpnRegion.valueOf(prefs.getString("region", "kr") ?: "kr")) }
        var user by remember { mutableStateOf(prefs.getString("user", "wifiscan") ?: "wifiscan") }
        var password by remember { mutableStateOf(prefs.getString("pw", "") ?: "") }
        var adblock by remember { mutableStateOf(prefs.getBoolean("adblock", false)) }
        var proto by remember {
            mutableStateOf(runCatching { VpnProto.valueOf(prefs.getString("proto", "auto") ?: "auto") }.getOrDefault(VpnProto.auto))
        }
        val wgState by WgVpn.state.collectAsState()
        var busy by remember { mutableStateOf(false) }
        var phase by remember { mutableStateOf<String?>(null) }
        var error by remember { mutableStateOf<String?>(null) }
        var state by remember { mutableStateOf<VpnProfileState?>(null) }
        val event by VpnEvents.lastEvent.collectAsState()

        // 시스템 VPN 상태를 1초마다 읽는다(다른 앱/설정에서 끊어도 반영되게).
        LaunchedEffect(Unit) {
            while (true) {
                state = runCatching { vpnManager.provisionedVpnProfileState }.getOrNull()
                delay(1_000)
            }
        }

        val s = state?.state
        val wgUp = wgState == Tunnel.State.UP
        val active = wgUp || s == VpnProfileState.STATE_CONNECTED || s == VpnProfileState.STATE_CONNECTING
        val savedRegion = prefs.getString("savedRegion", "kr") ?: "kr"

        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(Term.bg)
                .safeDrawingPadding()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            TermHeader("vpn")

            TermBlock("status") {
                val (tag, color, text) = if (wgUp) Triple("[ OK ]", Term.green, "up → $savedRegion · wg") else when (s) {
                    VpnProfileState.STATE_CONNECTED -> Triple("[ OK ]", Term.green, "up → $savedRegion · ikev2")
                    VpnProfileState.STATE_CONNECTING -> Triple("[ .. ]", Term.amber, "connecting")
                    VpnProfileState.STATE_FAILED -> Triple("[FAIL]", Term.red, "failed")
                    VpnProfileState.STATE_DISCONNECTED -> Triple("[DOWN]", Term.muted, "disconnected")
                    else -> Triple("[DOWN]", Term.muted, "not configured")
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(tag, style = Term.mono(14.sp, FontWeight.SemiBold, color))
                    Text(text, style = Term.mono(14.sp, FontWeight.SemiBold, if (wgUp || s == VpnProfileState.STATE_CONNECTED) Term.text else Term.muted))
                }
                when {
                    phase != null -> StatusLine('>', phase!!)
                    error != null -> StatusLine('✗', error!!)
                    event != null && !active -> StatusLine('!', event!!)
                }
            }

            TermBlock("exit node") {
                TermChoice(
                    options = VpnRegion.entries.map { it.name to it },
                    selected = region,
                    enabled = !busy && !active,
                ) {
                    region = it
                    prefs.edit().putString("region", it.name).apply()
                }
                Text(region.detail, style = Term.mono(12.sp, color = Term.muted))
            }

            TermBlock("auth") {
                TermField("user", user, { user = it; prefs.edit().putString("user", it).apply() }, "wifiscan")
                TermDivider()
                if (preset != null) {
                    Row {
                        Text("pw", style = Term.mono(15.sp, color = Term.muted), modifier = Modifier.width(56.dp))
                        Text("••••••••", style = Term.mono(15.sp, color = Term.muted))
                    }
                } else {
                    TermField("pw", password, { password = it; prefs.edit().putString("pw", it).apply() }, "password", secure = true)
                }
            }

            TermBlock("protocol") {
                TermChoice(
                    options = VpnProto.entries.map { it.label to it },
                    selected = proto,
                    enabled = !busy && !active,
                ) {
                    proto = it
                    prefs.edit().putString("proto", it.name).apply()
                }
            }

            TermBlock("dns") {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("--adblock", style = Term.mono(15.sp, color = Term.muted))
                    TermChoice(
                        options = listOf("off" to false, "on" to true),
                        selected = adblock,
                        enabled = !busy && !active,
                    ) {
                        adblock = it
                        prefs.edit().putBoolean("adblock", it).apply()
                    }
                }
            }

            TermButton(
                label = when {
                    busy -> "working…"
                    active -> "disconnect"
                    else -> "connect"
                },
                danger = active,
                enabled = !busy && user.isNotBlank(),
            ) {
                error = null
                if (active) {
                    vpnManager.stopProvisionedVpnProfile()
                    scope.launch { WgVpn.down(this@MainActivity) }
                    return@TermButton
                }
                val key = preset ?: password
                if (key.isEmpty()) {
                    error = "password required"
                    return@TermButton
                }
                busy = true
                scope.launch {
                    try {
                        connect(region, user.trim(), key, adblock, proto) { phase = it }
                    } catch (e: Exception) {
                        error = e.message ?: e.javaClass.simpleName
                    } finally {
                        busy = false
                        phase = null
                    }
                }
            }
        }
    }
}
