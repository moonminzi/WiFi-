package com.nago.vpn

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.InetAddresses
import android.net.VpnManager
import android.net.VpnProfileState
import android.net.VpnService
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wireguard.android.backend.Tunnel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** "1.1.1.1, 8.8.8.8" → 목록. 비어 있거나 하나라도 IP가 아니면 null. */
fun parseDns(text: String): List<String>? {
    val items = text.split(',', ' ').map { it.trim() }.filter { it.isNotEmpty() }
    return items.takeIf { it.isNotEmpty() && it.all(InetAddresses::isNumericAddress) }
}

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
        NagoLog.init(this)
        setContent { App() }
    }

    private val prefs by lazy { getSharedPreferences("nago", Context.MODE_PRIVATE) }

    /** 전달용 APK에만 들어가는 내장 비밀번호(assets/preset.txt). 공개 레포라 소스에는 없다. */
    private val preset: String? by lazy {
        runCatching { assets.open("preset.txt").bufferedReader().use { it.readText().trim() } }
            .getOrNull()?.takeIf { it.isNotEmpty() }
    }

    /** settings 탭 값. 연결할 때 읽는다. */
    private data class Options(
        val user: String,
        val proto: VpnProto,
        /** 앱 안 WireGuard 엔진: neptun(Rust, NordVPN 엔진) / go(wireguard-go, 공식 앱과 같은 엔진) */
        val engine: String,
        val adblock: Boolean,
        val dns: List<String>?,
        val allowLan: Boolean,
    ) {
        /** wg에 넣을 DNS: 광고 차단 → 직접 넣은 값 → 1.1.1.1 */
        val wgDns get() = if (adblock) listOf("10.53.53.53") else dns ?: listOf("1.1.1.1")
    }

    private fun options() = Options(
        user = (prefs.getString("user", "wifiscan") ?: "wifiscan").trim(),
        proto = runCatching { VpnProto.valueOf(prefs.getString("proto", "auto") ?: "auto") }.getOrDefault(VpnProto.auto),
        engine = if (prefs.getString("engine", "neptun") == "go") "go" else "neptun",
        adblock = prefs.getBoolean("adblock", false),
        dns = parseDns(prefs.getString("dns", "") ?: ""),
        allowLan = prefs.getBoolean("allowLan", false),
    )

    private suspend fun connect(region: VpnRegion, password: String, o: Options, onPhase: (String?) -> Unit) {
        val step: (String?) -> Unit = { text -> text?.let(NagoLog::add); onPhase(text) }
        step("${region.name}: checking server…")
        val target = try {
            RegionApi.waitUntilReady(region, password) { step(it) }
        } catch (e: ApiError.Forbidden) {
            throw e
        } catch (e: Exception) {
            region.fallback ?: throw e   // 한국 서버는 고정 IP로 바로 시도
        }
        if (target.justBooted) {
            step("${region.name}: up, waiting for ike…")
            delay(5_000)
        }
        when (o.proto) {
            VpnProto.ikev2 -> connectIke(region, target, password, o, step)
            VpnProto.wg -> connectWg(region, target, password, o, step)
            VpnProto.auto -> {
                connectIke(region, target, password, o, step)
                step("${region.name}: ikev2 handshake…")
                if (!waitForIke(12_000)) {
                    vpnManager.stopProvisionedVpnProfile()
                    step("${region.name}: ikev2 timeout → wg")
                    delay(1_000)
                    connectWg(region, target, password, o, step)
                }
            }
        }
        prefs.edit().putString("savedRegion", region.name).apply()
    }

    private suspend fun askConsent(intent: Intent) {
        val waiter = CompletableDeferred<Boolean>().also { consent = it }
        consentLauncher.launch(intent)
        if (!waiter.await()) throw IllegalStateException("vpn permission denied")
    }

    private suspend fun connectIke(
        region: VpnRegion, target: Target, password: String, o: Options, onPhase: (String?) -> Unit,
    ) {
        WgVpn.down(this)
        if (NeptunVpnService.up.value) NeptunVpnService.stop(this)
        onPhase("${region.name}: ikev2 → ${target.address}")
        val profile = NagoVpn.profile(this, target, o.user, password, o.adblock, o.allowLan)
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
        region: VpnRegion, target: Target, password: String, o: Options, onPhase: (String?) -> Unit,
    ) {
        vpnManager.stopProvisionedVpnProfile()
        VpnService.prepare(this)?.let { askConsent(it) }
        onPhase("${region.name}: wg register…")
        val reg = WgVpn.registration(prefs, password, "${o.user} android app")
        val serverPub = target.wgPub ?: reg.servers[region.name]
            ?: throw IllegalStateException("no wireguard key for ${region.name}")
        val endpoint = "${target.address}:${target.wgPort}"
        onPhase("${region.name}: wg/${o.engine} → $endpoint")
        if (o.engine == "go") {
            if (NeptunVpnService.up.value) NeptunVpnService.stop(this)
            WgVpn.up(this, WgVpn.config(reg, serverPub, endpoint, o.wgDns, o.allowLan))
        } else {
            WgVpn.down(this)
            NeptunVpnService.start(
                this,
                NeptunVpnService.Session(
                    privateKey = reg.keyPair.privateKey.toBase64(),
                    address = reg.address,
                    serverPub = serverPub,
                    endpoint = endpoint,
                    dns = o.wgDns,
                    allowLan = o.allowLan,
                    region = region.name,
                    apiKey = password,
                ),
            )
            NeptunVpnService.awaitUp(10_000)
        }
    }

    private fun stateName(state: Int?) = when (state) {
        VpnProfileState.STATE_CONNECTED -> "connected"
        VpnProfileState.STATE_CONNECTING -> "connecting"
        VpnProfileState.STATE_DISCONNECTED -> "disconnected"
        VpnProfileState.STATE_FAILED -> "failed"
        else -> "none"
    }

    @Composable
    private fun App() {
        var tab by remember { mutableStateOf("vpn") }
        val wgState by WgVpn.state.collectAsState()
        val neptunUp by NeptunVpnService.up.collectAsState()
        var ike by remember { mutableStateOf<Int?>(null) }

        // 시스템 VPN(IKEv2) 상태를 1초마다 읽는다(다른 앱/설정에서 끊어도 반영되게). 바뀌면 로그에 남긴다.
        LaunchedEffect(Unit) {
            var first = true
            while (true) {
                val now = runCatching { vpnManager.provisionedVpnProfileState?.state }.getOrNull()
                if (!first && now != ike) NagoLog.add("ikev2: ${stateName(now)}")
                first = false
                ike = now
                delay(1_000)
            }
        }

        val wgUp = wgState == Tunnel.State.UP || neptunUp
        val active = wgUp || ike == VpnProfileState.STATE_CONNECTED || ike == VpnProfileState.STATE_CONNECTING

        Column(Modifier.fillMaxSize().background(Term.bg).safeDrawingPadding()) {
            Box(Modifier.weight(1f)) {
                if (tab == "settings") SettingsScreen(active) else VpnScreen(ike, wgUp, active)
            }
            TermDivider()
            Row(Modifier.fillMaxWidth()) {
                listOf("vpn", "settings").forEach { name ->
                    val on = name == tab
                    Text(
                        name,
                        style = Term.mono(13.sp, if (on) FontWeight.Bold else FontWeight.Normal, if (on) Term.green else Term.muted),
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .weight(1f)
                            .clickable { tab = name }
                            .padding(vertical = 14.dp),
                    )
                }
            }
        }
    }

    @Composable
    private fun VpnScreen(state: Int?, wgUp: Boolean, active: Boolean) {
        val scope = rememberCoroutineScope()
        var region by remember { mutableStateOf(VpnRegion.valueOf(prefs.getString("region", "kr") ?: "kr")) }
        var busy by remember { mutableStateOf(false) }
        var phase by remember { mutableStateOf<String?>(null) }
        var error by remember { mutableStateOf<String?>(null) }
        val event by VpnEvents.lastEvent.collectAsState()
        // 탭을 오갈 때마다 다시 읽는다(settings에서 바꾼 값)
        val o = remember { options() }
        val savedRegion = prefs.getString("savedRegion", "kr") ?: "kr"

        Column(
            modifier = Modifier
                .fillMaxSize()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            TermHeader("vpn")

            TermBlock("status") {
                val (tag, color, text) = if (wgUp) Triple("[ OK ]", Term.green, "up → $savedRegion · wg") else when (state) {
                    VpnProfileState.STATE_CONNECTED -> Triple("[ OK ]", Term.green, "up → $savedRegion · ikev2")
                    VpnProfileState.STATE_CONNECTING -> Triple("[ .. ]", Term.amber, "connecting")
                    VpnProfileState.STATE_FAILED -> Triple("[FAIL]", Term.red, "failed")
                    VpnProfileState.STATE_DISCONNECTED -> Triple("[DOWN]", Term.muted, "disconnected")
                    else -> Triple("[DOWN]", Term.muted, "not configured")
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(tag, style = Term.mono(14.sp, FontWeight.SemiBold, color))
                    Text(text, style = Term.mono(14.sp, FontWeight.SemiBold, if (wgUp || state == VpnProfileState.STATE_CONNECTED) Term.text else Term.muted))
                }
                Text(flags(o), style = Term.mono(12.sp, color = Term.muted))
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

            TermButton(
                label = when {
                    busy -> "working…"
                    active -> "disconnect"
                    else -> "connect"
                },
                danger = active,
                enabled = !busy && o.user.isNotBlank(),
            ) {
                error = null
                if (active) {
                    NagoLog.add("disconnect")
                    vpnManager.stopProvisionedVpnProfile()
                    if (NeptunVpnService.up.value) NeptunVpnService.stop(this@MainActivity)
                    scope.launch { WgVpn.down(this@MainActivity) }
                    return@TermButton
                }
                val key = preset ?: (prefs.getString("pw", "") ?: "")
                if (key.isEmpty()) {
                    error = "password required → settings"
                    NagoLog.add("✗ password required")
                    return@TermButton
                }
                busy = true
                val current = options()
                scope.launch {
                    try {
                        connect(region, key, current) { phase = it }
                    } catch (e: Exception) {
                        val message = e.message ?: e.javaClass.simpleName
                        error = message
                        NagoLog.add("✗ $message")
                    } finally {
                        busy = false
                        phase = null
                    }
                }
            }
        }
    }

    /** `auto · adblock · allow-lan` 처럼 지금 설정 한 줄 */
    private fun flags(o: Options) = buildList {
        add(if (o.proto == VpnProto.wg) "wg/${o.engine}" else o.proto.label)
        when {
            o.adblock -> add("adblock")
            o.proto != VpnProto.ikev2 && o.dns != null -> add("dns " + o.dns.joinToString(","))
        }
        if (o.allowLan) add("allow-lan")
    }.joinToString(" · ")

    @Composable
    private fun SettingsScreen(active: Boolean) {
        var user by remember { mutableStateOf(prefs.getString("user", "wifiscan") ?: "wifiscan") }
        var password by remember { mutableStateOf(prefs.getString("pw", "") ?: "") }
        var proto by remember { mutableStateOf(options().proto) }
        var engine by remember { mutableStateOf(options().engine) }
        var adblock by remember { mutableStateOf(prefs.getBoolean("adblock", false)) }
        var dns by remember { mutableStateOf(prefs.getString("dns", "") ?: "") }
        var allowLan by remember { mutableStateOf(prefs.getBoolean("allowLan", false)) }
        var showLogs by remember { mutableStateOf(false) }
        val logs by NagoLog.lines.collectAsState()
        // 연결 중에는 바꿔도 지금 연결에 안 들어가서 잠가 둔다.
        val enabled = !active

        Column(
            modifier = Modifier
                .fillMaxSize()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            TermHeader("settings")
            if (active) StatusLine('!', "locked while connected")

            TermBlock("account") {
                TermField("user", user, { user = it; prefs.edit().putString("user", it).apply() }, "wifiscan", enabled = enabled)
                TermDivider()
                if (preset != null) {
                    Row {
                        Text("pw", style = Term.mono(15.sp, color = Term.muted), modifier = Modifier.width(56.dp))
                        Text("••••••••", style = Term.mono(15.sp, color = Term.muted))
                    }
                } else {
                    TermField("pw", password, { password = it; prefs.edit().putString("pw", it).apply() }, "password",
                        secure = true, enabled = enabled)
                }
            }

            TermBlock("protocol") {
                TermChoice(VpnProto.entries.map { it.label to it }, proto, enabled) {
                    proto = it
                    prefs.edit().putString("proto", it.name).apply()
                }
                if (proto != VpnProto.ikev2) {
                    TermDivider()
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("engine", style = Term.mono(15.sp, color = Term.muted), modifier = Modifier.weight(1f))
                        TermChoice(listOf("neptun" to "neptun", "go" to "go"), engine, enabled) {
                            engine = it
                            prefs.edit().putString("engine", it).apply()
                        }
                    }
                }
            }

            TermBlock("connection") {
                OptionRow("--allow-lan", allowLan, enabled) {
                    allowLan = it
                    prefs.edit().putBoolean("allowLan", it).apply()
                }
                TermDivider()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("always-on · kill switch", style = Term.mono(13.sp, color = Term.muted), modifier = Modifier.weight(1f))
                    TermSmallButton("system ›") { startActivity(Intent(Settings.ACTION_VPN_SETTINGS)) }
                }
            }

            TermBlock("dns") {
                OptionRow("--adblock", adblock, enabled) {
                    adblock = it
                    prefs.edit().putBoolean("adblock", it).apply()
                }
                TermDivider()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) {
                        TermField("custom", dns, { dns = it; prefs.edit().putString("dns", it).apply() }, "1.1.1.1",
                            enabled = enabled && !adblock)
                    }
                    val valid = dns.isBlank() || parseDns(dns) != null
                    Text(if (valid) "wg" else "invalid", style = Term.mono(12.sp, color = if (valid) Term.muted else Term.red))
                }
            }

            TermBlock("server") {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("accelerator", style = Term.mono(13.sp, color = Term.muted))
                    Text("on · tcp", style = Term.mono(13.sp, color = Term.green))
                }
            }

            TermBlock("logs") {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    TermSmallButton(if (showLogs) "hide" else "view") { showLogs = !showLogs }
                    TermSmallButton("copy") {
                        getSystemService(ClipboardManager::class.java)
                            .setPrimaryClip(ClipData.newPlainText("nago log", logs.joinToString("\n")))
                    }
                    TermSmallButton("clear", danger = true) { NagoLog.clear() }
                    Spacer(Modifier.weight(1f))
                    Text("${logs.size} lines", style = Term.mono(12.sp, color = Term.muted))
                }
                if (showLogs) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        if (logs.isEmpty()) Text("(empty)", style = Term.mono(11.sp, color = Term.muted))
                        logs.forEach { Text(it, style = Term.mono(11.sp)) }
                    }
                }
            }

            TermBlock("about") {
                val version = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: "?"
                Text("nago vpn $version", style = Term.mono(13.sp))
                Text("neptun ce18515 · wireguard-go 1.0.20230706", style = Term.mono(13.sp, color = Term.muted))
            }
        }
    }

    /** `--adblock  [off] on` 한 줄 */
    @Composable
    private fun OptionRow(label: String, value: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = Term.mono(15.sp, color = Term.muted), modifier = Modifier.weight(1f))
            TermChoice(listOf("off" to false, "on" to true), value, enabled, onChange)
        }
    }
}
