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
import android.view.HapticFeedbackConstants
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import com.wireguard.android.backend.Tunnel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** "1.1.1.1, 8.8.8.8" → 목록. 비어 있거나 하나라도 IP가 아니면 null. */
fun parseDns(text: String): List<String>? {
    val items = text.split(',', ' ').map { it.trim() }.filter { it.isNotEmpty() }
    return items.takeIf { it.isNotEmpty() && it.all(InetAddresses::isNumericAddress) }
}

/** 지금 터널 상태(ikev2 시스템 VPN 또는 앱 안 wg) */
enum class LinkState { Connected, Connecting, Failed, Down }

class MainActivity : ComponentActivity() {
    private lateinit var vpnManager: VpnManager
    private var consent: CompletableDeferred<Boolean>? = null

    /** 연결 작업. 화면(탭)을 오가도 끊기지 않게 화면 밖에서 돌린다. */
    private val work = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    // 처음 한 번 "VPN 연결 요청" 시스템 허용 창
    private val consentLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        consent?.complete(it.resultCode == Activity.RESULT_OK)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        vpnManager = getSystemService(VpnManager::class.java)
        NagoLog.catchCrashes(this)
        NagoLog.reportLastExit(this)
        setContent { App() }
    }

    override fun onDestroy() {
        work.cancel()
        super.onDestroy()
    }

    private val prefs by lazy { getSharedPreferences("nago", Context.MODE_PRIVATE) }

    /** 전달용 APK에만 들어가는 내장 비밀번호(assets/preset.txt). 공개 레포라 소스에는 없다. */
    private val preset: String? by lazy {
        runCatching { assets.open("preset.txt").bufferedReader().use { it.readText().trim() } }
            .getOrNull()?.takeIf { it.isNotEmpty() }
    }

    /** 가볍게 톡(단계) · 확인(연결됨) · 거절(실패) 같은 손끝 신호. 시스템의 "터치 진동" 설정을 따른다. */
    private fun haptic(kind: Int) {
        window.decorView.post { window.decorView.performHapticFeedback(kind) }
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

    private fun region(key: String) =
        runCatching { VpnRegion.valueOf(prefs.getString(key, "kr") ?: "kr") }.getOrDefault(VpnRegion.kr)

    private suspend fun connect(region: VpnRegion, password: String, o: Options, onPhase: (String?) -> Unit) {
        val step: (String?) -> Unit = { text -> text?.let(NagoLog::add); onPhase(text) }
        step("${region.name}: checking server…")
        val target = try {
            RegionApi.waitUntilReady(region, password) { step(it) }
        } catch (e: ApiError.Forbidden) {
            throw e
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            region.fallback ?: throw e   // 한국 서버는 고정 IP로 바로 시도
        }
        if (target.justBooted) {
            step("${region.name}: up, waiting for ike…")
            delay(5_000)
        }
        when (o.proto) {
            VpnProto.ikev2 -> {
                connectIke(region, target, password, o, step)
                // 시스템이 "연결 중"을 알릴 때까지 기다린다(그 사이 지도가 대기로 튀지 않게)
                waitForIke(3_000, started = true)
            }
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

    /** IKEv2가 연결될 때까지(started면 연결 중이 될 때까지) 기다린다. 시간 안에 안 되거나 실패하면 false. */
    private suspend fun waitForIke(timeoutMs: Long, started: Boolean = false): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            when (runCatching { vpnManager.provisionedVpnProfileState?.state }.getOrNull()) {
                VpnProfileState.STATE_CONNECTED -> return true
                VpnProfileState.STATE_CONNECTING -> if (started) return true
                VpnProfileState.STATE_FAILED -> return false
            }
            delay(if (started) 150 else 400)
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
        prefs.edit().putString("wgEndpoint", endpoint).putString("wgEngineUsed", o.engine).apply()
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

    /** 터널을 모두 내린다(ikev2·neptun·go 중 무엇이 떠 있든) */
    private fun stopAll(includeStarting: Boolean = false) {
        vpnManager.stopProvisionedVpnProfile()
        // 켜지는 중이면 up이 아직 false다 — 취소할 때는 그래도 멈춤 요청을 보낸다
        if (includeStarting || NeptunVpnService.up.value) NeptunVpnService.stop(this)
        work.launch { WgVpn.down(this@MainActivity) }
    }

    private fun tunnelActive(): Boolean {
        val ike = runCatching { vpnManager.provisionedVpnProfileState?.state }.getOrNull()
        return NeptunVpnService.up.value || WgVpn.state.value == Tunnel.State.UP ||
            ike == VpnProfileState.STATE_CONNECTED || ike == VpnProfileState.STATE_CONNECTING
    }

    private fun stateName(state: Int?) = when (state) {
        VpnProfileState.STATE_CONNECTED -> "connected"
        VpnProfileState.STATE_CONNECTING -> "connecting"
        VpnProfileState.STATE_DISCONNECTED -> "disconnected"
        VpnProfileState.STATE_FAILED -> "failed"
        else -> "none"
    }

    // MARK: - vpn 탭 상태

    private class Step(val at: Long, val text: String)

    /** vpn 탭 상태. 설정 탭에 다녀와도 진행 기록·측정값이 남아 있게 화면 밖에 둔다. */
    private inner class VpnUi {
        var region by mutableStateOf(region("region"))
        var savedRegion by mutableStateOf(region("savedRegion"))
        var busy by mutableStateOf(false)
        var phase by mutableStateOf<String?>(null)
        var error by mutableStateOf<String?>(null)
        var cancelled by mutableStateOf(false)
        val steps = mutableStateListOf<Step>()
        var exit by mutableStateOf<ExitInfo?>(null)
        var rtt by mutableStateOf<Map<VpnRegion, Int>>(emptyMap())
        var measuring by mutableStateOf(false)
        var probedAt = 0L
        val meter = TrafficMeter()
        var handshakeMs by mutableLongStateOf(0L)
        var hopTo by mutableStateOf<VpnRegion?>(null)
        /** 사용자가 cancel을 눌렀다(앱이 닫혀서 멈춘 것과 구분 — 그때는 터널을 건드리지 않는다) */
        var cancelRequested = false
        var connectedAt by mutableLongStateOf(prefs.getLong("connectedAt", 0L))
        var job: Job? = null
    }

    private val ui by lazy { VpnUi() }

    /** 연결(또는 갈아타기). 단계마다 기록·햅틱, 실패하면 오류 진동, 취소하면 터널을 내린다. */
    private fun start(target: VpnRegion, hopping: Boolean) {
        val key = preset ?: (prefs.getString("pw", "") ?: "")
        if (key.isEmpty()) {
            ui.error = "password required → settings"
            NagoLog.add("✗ password required")
            haptic(HapticFeedbackConstants.REJECT)
            return
        }
        ui.error = null
        ui.cancelled = false
        ui.cancelRequested = false
        ui.steps.clear()
        ui.busy = true
        ui.region = target
        prefs.edit().putString("region", target.name).apply()
        val o = options()
        ui.job = work.launch {
            try {
                if (hopping) {
                    ui.steps += Step(System.currentTimeMillis(), "${ui.savedRegion.name}: down → hop ${target.name}")
                    stopAll()
                    val deadline = System.currentTimeMillis() + 4_000
                    while (tunnelActive() && System.currentTimeMillis() < deadline) delay(150)
                }
                connect(target, key, o) { text ->
                    work.launch {
                        ui.phase = text
                        if (text != null && ui.steps.lastOrNull()?.text != text) {
                            ui.steps += Step(System.currentTimeMillis(), text)
                            haptic(HapticFeedbackConstants.KEYBOARD_TAP)
                        }
                    }
                }
                ui.savedRegion = target
            } catch (e: CancellationException) {
                if (ui.cancelRequested) {
                    ui.cancelled = true
                    NagoLog.add("cancelled")
                    stopAll(includeStarting = true)
                }
            } catch (e: Exception) {
                val message = e.message ?: e.javaClass.simpleName
                ui.error = message
                NagoLog.add("✗ $message")
                haptic(HapticFeedbackConstants.REJECT)
            } finally {
                ui.busy = false
                ui.phase = null
                ui.job = null
            }
        }
    }

    // MARK: - 화면

    @Composable
    private fun App() {
        var tab by remember { mutableStateOf("vpn") }
        var appearance by remember { mutableStateOf(prefs.getString("appearance", "system") ?: "system") }
        val dark = when (appearance) {
            "dark" -> true
            "light" -> false
            else -> isSystemInDarkTheme()
        }
        if (Term.dark != dark) Term.dark = dark
        val view = LocalView.current
        SideEffect {
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }

        val wgState by WgVpn.state.collectAsState()
        val neptunUp by NeptunVpnService.up.collectAsState()
        var ike by remember { mutableStateOf<Int?>(null) }

        // 시스템 VPN(IKEv2) 상태를 자주 읽는다(다른 앱/설정에서 끊어도 반영되게). 바뀌면 로그에 남긴다.
        LaunchedEffect(Unit) {
            var first = true
            while (true) {
                val now = runCatching { vpnManager.provisionedVpnProfileState?.state }.getOrNull()
                if (!first && now != ike) NagoLog.add("ikev2: ${stateName(now)}")
                first = false
                ike = now
                delay(500)
            }
        }

        val wgUp = wgState == Tunnel.State.UP || neptunUp
        val link = when {
            wgUp || ike == VpnProfileState.STATE_CONNECTED -> LinkState.Connected
            ike == VpnProfileState.STATE_CONNECTING -> LinkState.Connecting
            ike == VpnProfileState.STATE_FAILED -> LinkState.Failed
            else -> LinkState.Down
        }
        val active = link == LinkState.Connected || link == LinkState.Connecting

        // 연결된 시각(앱을 다시 열어도 이어지게 저장) · 연결되면 확인 진동, 끊기면 가볍게 톡
        var previous by remember { mutableStateOf<LinkState?>(null) }
        LaunchedEffect(link) {
            if (link == LinkState.Connected) {
                if (ui.connectedAt == 0L) {
                    ui.connectedAt = System.currentTimeMillis()
                    prefs.edit().putLong("connectedAt", ui.connectedAt).apply()
                }
                if (previous != null && previous != LinkState.Connected) haptic(HapticFeedbackConstants.CONFIRM)
            } else if (link != LinkState.Connecting) {
                if (ui.connectedAt != 0L) {
                    ui.connectedAt = 0L
                    prefs.edit().remove("connectedAt").apply()
                }
                if (previous == LinkState.Connected) haptic(HapticFeedbackConstants.KEYBOARD_TAP)
            }
            previous = link
        }

        Column(Modifier.fillMaxSize().background(Term.bg)) {
            Box(Modifier.weight(1f)) {
                if (tab == "settings") {
                    SettingsScreen(active, appearance) {
                        appearance = it
                        prefs.edit().putString("appearance", it).apply()
                    }
                } else {
                    VpnScreen(link, ike, wgUp)
                }
            }
            TabBar(tab) {
                if (it != tab) haptic(HapticFeedbackConstants.CLOCK_TICK)
                tab = it
            }
        }
    }

    @Composable
    private fun TabBar(tab: String, onSelect: (String) -> Unit) {
        Column(Modifier.fillMaxWidth().background(Term.bg).navigationBarsPadding()) {
            TermDivider()
            Row(Modifier.fillMaxWidth()) {
                listOf("vpn", "settings").forEach { name ->
                    val on = name == tab
                    val bar by animateDpAsState(if (on) 22.dp else 0.dp, tween(220), label = "tab-bar")
                    val color by animateColorAsState(if (on) Term.green else Term.muted, tween(220), label = "tab-color")
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier
                            .weight(1f)
                            .clickable(remember { MutableInteractionSource() }, indication = null) { onSelect(name) }
                            .padding(bottom = 12.dp),
                    ) {
                        Box(Modifier.size(bar, 2.dp).background(Term.green, RoundedCornerShape(1.dp)))
                        Spacer(Modifier.height(10.dp))
                        Text(name, style = Term.mono(13.sp, if (on) FontWeight.Bold else FontWeight.Normal, color))
                    }
                }
            }
        }
    }

    /** `wg/neptun · adblock · allow-lan` 처럼 지금 설정 */
    private fun flags(o: Options) = buildList {
        add(if (o.proto == VpnProto.wg) "wg/${o.engine}" else o.proto.label)
        when {
            o.adblock -> add("adblock")
            o.proto != VpnProto.ikev2 && o.dns != null -> add("dns " + o.dns.joinToString(","))
        }
        if (o.allowLan) add("allow-lan")
    }

    @Composable
    private fun VpnScreen(link: LinkState, ike: Int?, wgUp: Boolean) {
        val o = remember { options() }
        val busy = ui.busy
        val connected = link == LinkState.Connected
        // 연결돼 있으면 실제로 붙은 나라를 보여 준다
        val shown = if ((connected || link == LinkState.Connecting) && !busy) ui.savedRegion else ui.region
        val locked = busy || link == LinkState.Connecting
        val pill = when {
            connected -> PillKind.On
            busy || link == LinkState.Connecting -> PillKind.Busy
            ui.error != null || link == LinkState.Failed -> PillKind.Error
            else -> PillKind.Off
        }
        val stage = when {
            busy || link == LinkState.Connecting -> RouteStage.Connecting
            connected -> RouteStage.Connected
            ui.error != null || link == LinkState.Failed -> RouteStage.Failed
            else -> RouteStage.Idle
        }

        // 상태가 자리를 잡으면: 연결 전엔 지금 회선 IP와 나라별 지연을 재고, ikev2로 연결되면 출구 IP를 확인한다
        LaunchedEffect(link, wgUp) {
            when (link) {
                LinkState.Connected -> {
                    ui.exit = null
                    // neptun은 앱 자신을 터널에서 빼 둬서 앱이 재면 평소 회선이 보인다 — 그때는 재지 않는다
                    if (!NeptunVpnService.up.value) {
                        delay(1_500)
                        ui.exit = ExitInfo.fetch()
                    }
                }
                LinkState.Down, LinkState.Failed -> {
                    ui.exit = null
                    launch { ui.exit = ExitInfo.fetch() }
                    if (!ui.measuring && System.currentTimeMillis() - ui.probedAt > 20_000) {
                        ui.measuring = true
                        ui.rtt = LatencyProbe.measure()
                        ui.measuring = false
                        ui.probedAt = System.currentTimeMillis()
                    }
                }
                LinkState.Connecting -> Unit
            }
        }
        // 앱 안 wg로 연결돼 있는 동안 1초마다 엔진에 바이트 수·핸드셰이크를 묻는다
        LaunchedEffect(connected && wgUp) {
            ui.meter.reset()
            ui.handshakeMs = 0L
            if (!(connected && wgUp)) return@LaunchedEffect
            while (true) {
                val stats = withContext(Dispatchers.IO) {
                    if (NeptunVpnService.up.value) NeptunVpnService.stats() else WgVpn.stats(this@MainActivity)
                }
                stats?.let {
                    ui.meter.add(it.rx, it.tx)
                    ui.handshakeMs = it.handshakeMs
                }
                delay(1_000)
            }
        }

        BoxWithConstraints(Modifier.fillMaxSize()) {
            val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
            val screen = maxHeight
            val heroHeight = (screen * 0.55f).coerceIn(300.dp, 540.dp)
            val overlap = 28.dp
            val scroll = rememberScrollState()

            Column(Modifier.fillMaxSize().verticalScroll(scroll)) {
                // 지도(화면 위쪽 배경)
                Box(Modifier.fillMaxWidth().height(heroHeight)) {
                    // 위로 밀면 지도는 천천히 따라간다(패럴랙스)
                    Box(Modifier.graphicsLayer { translationY = scroll.value * 0.45f }) {
                        RouteMap(
                            destination = shown,
                            stage = stage,
                            hop = ui.phase ?: if (link == LinkState.Connecting) "connecting" else null,
                            height = heroHeight,
                            top = top + 56.dp,
                            bottom = overlap,
                            onSelect = if (locked) null else { r -> select(r, link) },
                        )
                    }
                    Box(Modifier.matchParentSize().stateGlow(pill))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = top + 10.dp, start = 16.dp, end = 16.dp),
                    ) {
                        TermHeader("vpn")
                        Spacer(Modifier.weight(1f))
                        StatusPill(pill, pillText(pill))
                    }
                }

                // 콘솔(지도 위로 올라오는 판)
                Box(
                    contentAlignment = Alignment.TopCenter,
                    modifier = Modifier
                        .offset(y = -overlap)
                        .fillMaxWidth()
                        .heightIn(min = screen - heroHeight + overlap)
                        .consoleSheet(),
                ) {
                    Column(
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                        modifier = Modifier
                            .widthIn(max = 680.dp)
                            .fillMaxWidth()
                            .padding(start = 16.dp, end = 16.dp, top = 26.dp, bottom = 24.dp),
                    ) {
                        SessionPanel(link, ike, wgUp, shown, o)
                        ConnectButton(link, o)
                        ExitPanel(link, shown, locked)
                        AnimatedVisibility(
                            ui.steps.isNotEmpty() || ui.error != null,
                            enter = fadeIn() + expandVertically(),
                            exit = fadeOut() + shrinkVertically(),
                        ) { BootLog(connected) }
                    }
                }
            }

            // 밀어 올리면 상태 표시줄 밑으로 글자가 비치지 않게 배경색으로 덮는다
            val scrim = (scroll.value / 120f).coerceIn(0f, 1f)
            if (scrim > 0f) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(top + 10.dp)
                        .alpha(scrim)
                        .background(Brush.verticalGradient(0.7f to Term.bg, 1f to Term.bg.copy(alpha = 0f))),
                )
            }
        }

        ui.hopTo?.let { target -> HopDialog(target) }
    }

    private fun pillText(pill: PillKind) = when (pill) {
        PillKind.On -> "secured"
        PillKind.Busy -> "linking"
        PillKind.Error -> "failed"
        PillKind.Off -> "exposed"
    }

    /** 지도·카드에서 나라를 골랐을 때. 연결돼 있으면 갈아탈지 묻는다. */
    private fun select(choice: VpnRegion, link: LinkState) {
        if (ui.busy || link == LinkState.Connecting) return
        haptic(HapticFeedbackConstants.CLOCK_TICK)
        if (link == LinkState.Connected) {
            if (choice != ui.savedRegion) ui.hopTo = choice
            return
        }
        ui.error = null
        ui.region = choice
        prefs.edit().putString("region", choice.name).apply()
    }

    @Composable
    private fun HopDialog(target: VpnRegion) {
        val from = ui.savedRegion
        AlertDialog(
            onDismissRequest = { ui.hopTo = null },
            containerColor = Term.surface,
            shape = RoundedCornerShape(12.dp),
            title = { Text("hop to ${target.geo.city}?", style = Term.mono(16.sp, FontWeight.Bold, Term.text)) },
            text = {
                Text(
                    "${from.name} ${from.geo.city} → ${target.name} ${target.geo.city}\ndisconnects ${from.name}, then connects ${target.name}",
                    style = Term.mono(12.sp, color = Term.muted),
                )
            },
            confirmButton = {
                TermSmallButton("hop → ${target.name}") {
                    ui.hopTo = null
                    start(target, hopping = true)
                }
            },
            dismissButton = { TermSmallButton("stay on ${from.name}") { ui.hopTo = null } },
        )
    }

    // MARK: 세션

    @Composable
    private fun SessionPanel(link: LinkState, ike: Int?, wgUp: Boolean, shown: VpnRegion, o: Options) {
        val connected = link == LinkState.Connected
        val busy = ui.busy
        val engine = prefs.getString("wgEngineUsed", o.engine) ?: o.engine
        val proto = if (wgUp) "wg/$engine" else "ikev2"
        val (tag, tagColor) = when {
            connected -> "[ OK ]" to Term.green
            busy || link == LinkState.Connecting -> "[ .. ]" to Term.amber
            link == LinkState.Failed -> "[FAIL]" to Term.red
            else -> "[DOWN]" to Term.muted
        }
        val text = when {
            connected -> "up → ${ui.savedRegion.name} · $proto"
            busy -> "linking ${ui.region.name}"
            link == LinkState.Connecting -> "connecting"
            link == LinkState.Failed -> "failed · ikev2"
            ike == null && !wgUp -> "not set up · first connect asks once"
            else -> "disconnected · traffic goes out direct"
        }

        // 시스템이 알려 준 ikev2 오류나 neptun 엔진 실패(끊겨 있을 때만)
        val event by VpnEvents.lastEvent.collectAsState()
        val engineFailure by NeptunVpnService.failure.collectAsState()
        val notice = (event ?: engineFailure)?.takeIf { !connected && !busy && link != LinkState.Connecting }

        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(tag, style = Term.mono(13.sp, FontWeight.SemiBold, tagColor))
                Text(text, style = Term.mono(13.sp, FontWeight.SemiBold, if (connected) Term.text else Term.muted),
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }

            Row(verticalAlignment = Alignment.Bottom) {
                val cityColor by animateColorAsState(if (connected) Term.green else Term.num, tween(350), label = "city")
                // 나라를 바꾸면 이름이 위아래로 부드럽게 바뀐다
                AnimatedContent(
                    targetState = shown,
                    transitionSpec = {
                        (slideInVertically(tween(300)) { it / 2 } + fadeIn(tween(300)))
                            .togetherWith(slideOutVertically(tween(250)) { -it / 2 } + fadeOut(tween(200)))
                    },
                    label = "city",
                    modifier = Modifier.weight(1f, fill = false),
                ) { region ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        DotFlag(region, 38.dp, Modifier.padding(top = 3.dp))
                        Text(region.geo.city, style = Term.mono(28.sp, FontWeight.Bold, cityColor),
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                Spacer(Modifier.weight(1f).widthIn(min = 8.dp))
                if (connected && ui.connectedAt > 0) {
                    SessionClock(ui.connectedAt)
                } else {
                    val km = Geo.here.km(shown.geo)
                    RollingText(if (km < 150) "local" else "${RouteMath.grouped(km.toInt())} km",
                        Term.mono(13.sp, color = Term.muted), Modifier.padding(bottom = 5.dp))
                }
            }

            AnimatedContent(
                targetState = busy || link == LinkState.Connecting,
                transitionSpec = { fadeIn(tween(300)).togetherWith(fadeOut(tween(200))) },
                label = "pipeline",
            ) { linking ->
                if (linking) PhasePipeline(pipelineIndex(link)) else ExitLine(connected, wgUp)
            }

            notice?.let { Text("! $it", style = Term.mono(12.sp, color = Term.amber), maxLines = 2, overflow = TextOverflow.Ellipsis) }

            AnimatedVisibility(connected && !busy, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
                if (wgUp) {
                    val ago = ui.handshakeMs.takeIf { it > 0 }?.let { (System.currentTimeMillis() - it) / 1000 }
                    TrafficPanel(ui.meter, ago)
                } else {
                    Text("link · ikev2 system tunnel", style = Term.mono(12.sp, color = Term.muted))
                }
            }

            FlagRow(flags(o))
        }
    }

    /** 진행 단계 문구로 어디까지 왔는지(api → boot → tunnel → up) */
    private fun pipelineIndex(link: LinkState): Int {
        if (link == LinkState.Connected && !ui.busy) return 3
        val text = ui.phase ?: ""
        return when {
            "ikev2" in text || "wg" in text -> 2
            "boot" in text || "stopping" in text || "retry" in text || "waiting" in text -> 1
            link == LinkState.Connecting && ui.phase == null -> 2
            else -> 0
        }
    }

    /**
     * `isp 211.36.1.9 · KR ICN · sites see this` — 밖에서 보이는 IP. 연결되면 고른 나라인지 맞춰 본다.
     * neptun은 앱 자신이 터널 밖이라 출구를 직접 못 재니 서버 주소를 보여 준다.
     */
    @Composable
    private fun ExitLine(connected: Boolean, wgUp: Boolean) {
        val bypass = connected && wgUp && NeptunVpnService.up.value
        val muted = SpanStyle(color = Term.muted)
        val num = SpanStyle(color = Term.num)
        val line = buildAnnotatedString {
            val exit = ui.exit
            when {
                bypass -> {
                    val endpoint = prefs.getString("wgEndpoint", null)?.substringBeforeLast(':')
                    withStyle(muted) { append("exit ") }
                    withStyle(num) { append(endpoint ?: "—") }
                    withStyle(muted) { append(" · ${ui.savedRegion.countryCode} server") }
                }
                exit == null -> withStyle(muted) { append(if (connected) "exit checking…" else "isp checking…") }
                else -> {
                    withStyle(muted) { append(if (connected) "exit " else "isp ") }
                    withStyle(num) { append(exit.ip) }
                    withStyle(muted) { append(" · ${exit.country}" + if (exit.colo.isEmpty()) "" else " ${exit.colo}") }
                    when {
                        !connected -> withStyle(SpanStyle(color = Term.muted.copy(alpha = 0.7f))) { append(" · sites see this") }
                        exit.country == ui.savedRegion.countryCode -> withStyle(SpanStyle(color = Term.green)) { append(" ✓ matches") }
                        else -> withStyle(SpanStyle(color = Term.red)) { append(" ✗ not ${ui.savedRegion.countryCode}") }
                    }
                }
            }
        }
        Text(
            line,
            style = Term.mono(12.sp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.clickable(enabled = !bypass) {
                work.launch { ui.exit = ExitInfo.fetch() }
            },
        )
    }

    // MARK: 연결 버튼

    /** 연결 중에는 같은 버튼이 취소 버튼이 된다(지금 단계 + cancel). */
    @Composable
    private fun ConnectButton(link: LinkState, o: Options) {
        val busy = ui.busy
        val active = link == LinkState.Connected || link == LinkState.Connecting
        val accent = when {
            busy -> Term.amber
            active -> Term.red
            else -> Term.green
        }
        val filled = !busy && !active
        val enabled = busy || active || o.user.isNotBlank()
        val shape = RoundedCornerShape(6.dp)
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp, if (busy) Alignment.Start else Alignment.CenterHorizontally),
            modifier = Modifier
                .fillMaxWidth()
                .alpha(if (enabled) 1f else 0.35f)
                .background(if (filled) accent else Term.surface, shape)
                .border(1.dp, accent, shape)
                .sweep(busy, Term.amber)
                .pressable(enabled) {
                    when {
                        busy -> {
                            ui.cancelRequested = true
                            ui.job?.cancel()
                        }
                        active -> {
                            NagoLog.add("disconnect")
                            ui.error = null
                            stopAll()
                        }
                        else -> start(ui.region, hopping = false)
                    }
                }
                .padding(horizontal = 16.dp, vertical = 15.dp),
        ) {
            when {
                busy -> {
                    CircularProgressIndicator(Modifier.size(14.dp), color = Term.amber, strokeWidth = 1.5.dp)
                    Text((ui.phase ?: "working").replace("…", ""), style = Term.mono(14.sp, FontWeight.SemiBold, Term.text),
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text("cancel ✕", style = Term.mono(14.sp, FontWeight.SemiBold, Term.amber))
                }
                active -> Text("■ disconnect", style = Term.mono(14.sp, FontWeight.SemiBold, Term.red))
                else -> {
                    Text("$", style = Term.mono(14.sp, FontWeight.SemiBold, Term.bg.copy(alpha = 0.6f)))
                    Text("nago up ${ui.region.name}", style = Term.mono(14.sp, FontWeight.SemiBold, Term.bg))
                }
            }
        }
    }

    // MARK: 나갈 국가

    @Composable
    private fun ExitPanel(link: LinkState, shown: VpnRegion, locked: Boolean) {
        val connected = link == LinkState.Connected
        // 잰 것 중 가장 빠른 나라(둘 이상 쟀을 때만)
        val fastest = ui.rtt.takeIf { it.size > 1 }?.minByOrNull { it.value }?.key
        val hint = when {
            locked -> "locked while linking"
            connected -> "tap another to hop"
            ui.measuring -> "pinging…"
            ui.rtt.isEmpty() -> "tap map or card · rtt est."
            else -> "tap map or card · rtt live"
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row {
                Text("// exit node", style = Term.mono(11.sp, color = Term.muted))
                Spacer(Modifier.weight(1f))
                Text(hint, style = Term.mono(11.sp, color = Term.muted.copy(alpha = 0.7f)))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.alpha(if (locked) 0.55f else 1f)) {
                VpnRegion.entries.forEach { option ->
                    RegionCard(
                        region = option,
                        selected = option == shown,
                        live = connected && option == ui.savedRegion,
                        measured = ui.rtt[option],
                        fastest = option == fastest,
                        enabled = !locked,
                        modifier = Modifier.weight(1f),
                    ) { select(option, link) }
                }
            }
        }
    }

    // MARK: 진행 기록

    @Composable
    private fun BootLog(connected: Boolean) {
        TermBlock("boot log") {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                val steps = ui.steps.takeLast(7)
                val start = ui.steps.firstOrNull()?.at ?: System.currentTimeMillis()
                steps.forEachIndexed { i, step ->
                    val last = i == steps.size - 1
                    val (symbol, symbolColor) = when {
                        !last -> "✓" to Term.green
                        ui.error != null -> "✗" to Term.red
                        ui.cancelled -> "–" to Term.muted
                        ui.busy -> ">" to Term.amber
                        else -> "✓" to Term.green
                    }
                    val color = when {
                        !last -> Term.text
                        ui.error != null -> Term.red
                        ui.cancelled -> Term.muted
                        else -> Term.text
                    }
                    LogLine((step.at - start) / 1000.0, symbol, symbolColor, step.text, color)
                }
                if (connected && !ui.busy && ui.connectedAt > 0 && ui.steps.isNotEmpty()) {
                    LogLine((ui.connectedAt - start) / 1000.0, "✓", Term.green, "tunnel up", Term.green)
                }
                ui.error?.let { LogLine(null, "✗", Term.red, it, Term.red) }
            }
        }
    }

    // MARK: - 설정

    @Composable
    private fun SettingsScreen(active: Boolean, appearance: String, onAppearance: (String) -> Unit) {
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
                .statusBarsPadding()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            TermHeader("settings")
            if (active) StatusLine('!', "locked while connected")

            TermBlock("appearance") {
                // 화면 색은 연결 중에도 바꿀 수 있다
                TermChoice(listOf("system" to "system", "dark" to "dark", "light" to "light"), appearance, true) {
                    onAppearance(it)
                    haptic(HapticFeedbackConstants.CLOCK_TICK)
                }
            }

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
