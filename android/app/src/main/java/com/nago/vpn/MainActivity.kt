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
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
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
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.view.WindowCompat
import com.wireguard.android.backend.Tunnel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
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

/**
 * NAGO VPN 안드로이드 앱. 화면은 iOS 앱(VPNView·SettingsView)과 같은 모양이고, 대시보드 탭만 없다.
 * - vpn: 지도(머리줄 · 검사 단추 · 상태 알약) 위로 콘솔 판(세션 · 연결 버튼 · 나갈 국가 · 임시 서버 나라 · net scan · speed test)
 * - settings: 화면 색 · 계정 · 프로토콜(엔진 · loops · nagoing · fast) · 연결 · dns · 서버 · 로그 · 정보
 */
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
        Demo.load(this)
        applyDemo()
        setContent { App() }
    }

    /** 스크린샷용 데모 상태(디버그 빌드 + `--es nagoDemo connected`, iOS -nagoDemo와 같음) */
    private fun applyDemo() {
        val state = Demo.state ?: return
        val r = Demo.region ?: VpnRegion.jp
        if (Demo.unfold) {
            ui.foldScan = false
            ui.foldSpeed = false
            ui.foldOnDemand = false
        }
        ui.rtt = Demo.rtt
        ui.probedAt = System.currentTimeMillis()
        ui.speed.showDemo()
        ui.region = r
        when (state) {
            "connecting" -> {
                ui.busy = true
                ui.phase = "${r.name}: up, waiting for ike…"
            }
            "connected" -> {
                ui.savedRegion = r
                prefs.edit().putString("activeProto", "wg").putString("wgEngineUsed", "neptun").putInt("wgLoopsUsed", 1).apply()
                ui.connectedAt = Demo.since
                Demo.fill(LinkMonitor.meter)
                NeptunVpnService.up.value = true
            }
            "failed" -> {
                ui.region = VpnRegion.us
                ui.error = "timeout: server not up after 4m, retry"
            }
            "scan" -> ui.scan.showDemo(running = true)
        }
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

    /** settings 탭 값. 연결할 때 읽는다(iOS와 같은 기본값). */
    private data class Options(
        val user: String,
        val proto: VpnProto,
        /** 앱 안 WireGuard 엔진: neptun(NagoTun, Rust) / go(wireguard-go, 공식 앱과 같은 엔진) */
        val engine: String,
        /** NagoTun 이벤트 루프 수. 2면 내려받기와 올리기(ACK 포함)가 다른 코어에서 돈다 */
        val loops: Int,
        /** NagoTun에서 막힌 망 우회(nagoing) */
        val nagoOn: Boolean,
        val nagoPrefer: String,
        val nagoFec: Boolean,
        /** IKEv2 데이터를 AES-256-GCM으로 */
        val fast: Boolean,
        val adblock: Boolean,
        val dns: List<String>?,
        val allowLan: Boolean,
    ) {
        /** 임시 서버는 WireGuard만 있다 */
        fun proto(region: VpnRegion) = if (region.onDemand) VpnProto.wg else proto

        /** 광고 차단 DNS → 직접 넣은 DNS → 1.1.1.1. 임시 서버엔 차단 DNS가 없다. */
        fun wgDns(region: VpnRegion) = if (adblock && !region.onDemand) listOf("10.53.53.53") else dns ?: listOf("1.1.1.1")

        val nagoing get() = if (nagoOn && engine == "neptun") NagoingSettings(prefer = nagoPrefer, fec = nagoFec) else null
    }

    private fun options() = Options(
        user = (prefs.getString("user", "wifiscan") ?: "wifiscan").trim(),
        proto = runCatching { VpnProto.valueOf(prefs.getString("proto", "auto") ?: "auto") }.getOrDefault(VpnProto.auto),
        engine = if (prefs.getString("engine", "neptun") == "go") "go" else "neptun",
        loops = prefs.getInt("loops", 1).coerceIn(1, 2),
        nagoOn = prefs.getBoolean("nagoOn", false),
        nagoPrefer = prefs.getString("nagoPrefer", "auto") ?: "auto",
        nagoFec = prefs.getBoolean("nagoFec", true),
        fast = prefs.getBoolean("fast", true),
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
        } catch (e: ApiError.TooManyServers) {
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
        when (o.proto(region)) {
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
        val profile = NagoVpn.profile(this, target, o.user, password, o.adblock, o.allowLan, o.fast)
        vpnManager.provisionVpnProfile(profile)?.let { intent ->
            askConsent(intent)
            vpnManager.provisionVpnProfile(profile)
        }
        VpnEvents.lastEvent.value = null
        prefs.edit().putString("activeProto", "ikev2").apply()
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
        prefs.edit().putString("wgEndpoint", endpoint).putString("wgEngineUsed", o.engine)
            .putInt("wgLoopsUsed", o.loops).putString("activeProto", "wg").apply()
        val nagoing = o.nagoing
        onPhase(
            if (nagoing != null) "${region.name}: nagoing → ${target.address}:${nagoing.udpPort}"
            else "${region.name}: wg/${engineName(o.engine)} → $endpoint",
        )
        if (o.engine == "go") {
            if (NeptunVpnService.up.value) NeptunVpnService.stop(this)
            WgVpn.up(this, WgVpn.config(reg, serverPub, endpoint, o.wgDns(region), o.allowLan))
        } else {
            WgVpn.down(this)
            NeptunVpnService.start(
                this,
                NeptunVpnService.Session(
                    privateKey = reg.keyPair.privateKey.toBase64(),
                    address = reg.address,
                    serverPub = serverPub,
                    endpoint = endpoint,
                    dns = o.wgDns(region),
                    allowLan = o.allowLan,
                    region = region.name,
                    apiKey = password,
                    loops = o.loops,
                    nagoing = nagoing,
                ),
            )
            NeptunVpnService.awaitUp(10_000)
        }
    }

    /** 터널을 모두 내린다(ikev2·NagoTun·go 중 무엇이 떠 있든) */
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

    /** vpn 탭 상태. 설정 탭에 다녀와도 진행·측정값이 남아 있게 화면 밖에 둔다. */
    private inner class VpnUi {
        var region by mutableStateOf(region("region"))
        var savedRegion by mutableStateOf(region("savedRegion"))
        var busy by mutableStateOf(false)
        var phase by mutableStateOf<String?>(null)
        var error by mutableStateOf<String?>(null)
        /** 이번 연결의 단계 수(하나 찍힐 때마다 햅틱) */
        var steps = 0
        var exit by mutableStateOf<ExitInfo?>(null)
        var rtt by mutableStateOf<Map<VpnRegion, Int>>(emptyMap())
        var measuring by mutableStateOf(false)
        var probedAt = 0L
        var hopTo by mutableStateOf<VpnRegion?>(null)
        /** isp·exit 줄의 IP를 가린다(줄을 누르면 바뀜, 기억해 둠) */
        var hideIP by mutableStateOf(prefs.getBoolean("hideIP", false))
        /** 사용자가 cancel을 눌렀다(앱이 닫혀서 멈춘 것과 구분 — 그때는 터널을 건드리지 않는다) */
        var cancelRequested = false
        var connectedAt by mutableLongStateOf(prefs.getLong("connectedAt", 0L))
        var job: Job? = null
        /** 접어 둔 패널(net scan · speed test · 임시 서버 나라). 처음엔 접혀 있다 */
        var foldScan by mutableStateOf(prefs.getBoolean("foldScan", true))
        var foldSpeed by mutableStateOf(prefs.getBoolean("foldSpeed", true))
        var foldOnDemand by mutableStateOf(prefs.getBoolean("foldOnDemand", true))
        /** 연결 기록 창(실패 줄 · settings → logs) */
        var showLogs by mutableStateOf(false)
        val scan = NetScan()
        val speed = SpeedTest(this@MainActivity)
    }

    private val ui by lazy { VpnUi() }

    private fun fold(key: String, value: Boolean) {
        prefs.edit().putBoolean(key, value).apply()
        haptic(HapticFeedbackConstants.CLOCK_TICK)
    }

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
        ui.cancelRequested = false
        ui.steps = 0
        ui.busy = true
        ui.region = target
        prefs.edit().putString("region", target.name).apply()
        val o = options()
        ui.job = work.launch {
            try {
                if (hopping) {
                    NagoLog.add("hop ${ui.savedRegion.name} → ${target.name}")
                    ui.phase = "hop: ${ui.savedRegion.name} → ${target.name}"
                    stopAll()
                    val deadline = System.currentTimeMillis() + 8_000
                    while (tunnelActive() && System.currentTimeMillis() < deadline) delay(200)
                }
                connect(target, key, o) { text ->
                    work.launch {
                        if (text != null && text != ui.phase) {
                            ui.steps += 1
                            haptic(HapticFeedbackConstants.KEYBOARD_TAP)
                        }
                        ui.phase = text
                    }
                }
                ui.savedRegion = target
            } catch (e: CancellationException) {
                if (ui.cancelRequested) {
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

    /** 지금 네트워크를 검사한다(앱을 열면 한 번, 머리줄 레이더 단추로 다시) */
    private fun runScan(link: LinkState) {
        if (ui.scan.running) return
        val on = link == LinkState.Connected
        work.launch {
            ui.scan.run(this@MainActivity, on, if (on) ui.savedRegion else null)
            haptic(if (ui.scan.hasProblems) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.CONFIRM)
        }
    }

    /** 속도 측정 결과에 남길 설정 이름: 연결돼 있으면 "wg/NagoTun ×2 · jp", 아니면 "direct" */
    private fun speedVia(link: LinkState): String {
        if (link != LinkState.Connected) return "direct"
        val region = ui.savedRegion.name
        if (prefs.getString("activeProto", "wg") == "ikev2") return "ikev2 · $region"
        val engine = prefs.getString("wgEngineUsed", "neptun") ?: "neptun"
        val name = if (engine == "neptun") "wg/NagoTun ×${prefs.getInt("wgLoopsUsed", 1)}" else "wg/$engine"
        return "$name · $region"
    }

    // MARK: - 화면

    @Composable
    private fun App() {
        var tab by remember { mutableStateOf(Demo.tab ?: "vpn") }
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
        // 앱을 열면 지금 네트워크를 한 번 검사한다(iOS와 같음)
        LaunchedEffect(Unit) {
            delay(400)
            if (Demo.state != "scan") runScan(link)
        }

        Column(Modifier.fillMaxSize().background(Term.bg)) {
            Box(Modifier.weight(1f)) {
                if (tab == "settings") {
                    SettingsScreen(active, appearance) {
                        appearance = it
                        prefs.edit().putString("appearance", it).apply()
                    }
                } else {
                    VpnScreen(link, wgUp)
                }
            }
            TabBar(tab) {
                if (it != tab) haptic(HapticFeedbackConstants.CLOCK_TICK)
                tab = it
            }
        }
        if (ui.showLogs) LogsSheet { ui.showLogs = false }
    }

    /** iOS 탭 막대: 아이콘 + 이름, 고른 탭은 초록. 대시보드 탭은 없다 */
    @Composable
    private fun TabBar(tab: String, onSelect: (String) -> Unit) {
        Column(Modifier.fillMaxWidth().background(Term.bg).navigationBarsPadding()) {
            TermDivider()
            Row(Modifier.fillMaxWidth().height(52.dp)) {
                listOf("vpn" to Glyph.Shield, "settings" to Glyph.Gear).forEach { (name, glyph) ->
                    val on = name == tab
                    val color by animateColorAsState(if (on) Term.green else Term.muted, tween(220), label = "tab-color")
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxSize()
                            .clickable(remember { MutableInteractionSource() }, indication = null) { onSelect(name) },
                    ) {
                        TermIcon(glyph, 24.dp, color)
                        Spacer(Modifier.height(3.dp))
                        Text(name, style = Term.mono(10.5.sp, if (on) FontWeight.SemiBold else FontWeight.Normal, color))
                    }
                }
            }
        }
    }

    /** `wg/NagoTun ×1 · nagoing auto · gcm · adblock` 처럼 지금 설정 */
    private fun flags(o: Options, region: VpnRegion) = buildList {
        val proto = o.proto(region)
        add(
            when (proto) {
                VpnProto.wg -> "wg/${engineName(o.engine)}" + if (o.engine == "neptun") " ×${o.loops}" else ""
                else -> proto.label
            },
        )
        if (proto == VpnProto.wg && o.nagoing != null) add("nagoing ${o.nagoPrefer}")
        if (o.fast && proto != VpnProto.wg) add("gcm")
        when {
            o.adblock -> add(if (region.onDemand) "adblock n/a · temp server" else "adblock")
            proto != VpnProto.ikev2 && o.dns != null -> add("dns " + o.dns.joinToString(","))
        }
        if (o.allowLan) add("allow-lan")
    }

    @Composable
    private fun VpnScreen(link: LinkState, wgUp: Boolean) {
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

        // 상태가 자리를 잡으면 출구 IP를 다시 보고, 끊겼으면 나라별 지연도 다시 잰다
        // (연결된 직후엔 경로가 바뀌는 중이라 잠깐 기다린다)
        LaunchedEffect(link) {
            when (link) {
                LinkState.Connected -> {
                    ui.exit = null
                    delay(1_500)
                    var info = ExitInfo.fetch()
                    // 막 붙었을 때 한 번 다르게 나오면 3초 뒤 한 번 더 본다(경로가 자리 잡는 중일 수 있다) — 그래도 다르면 leak?
                    if (info != null && info.country != ui.savedRegion.countryCode) {
                        delay(3_000)
                        info = ExitInfo.fetch() ?: info
                    }
                    ui.exit = info
                }
                LinkState.Down, LinkState.Failed -> {
                    ui.exit = null
                    val info = async { ExitInfo.fetch() }
                    if (!ui.measuring && System.currentTimeMillis() - ui.probedAt > 20_000) {
                        ui.measuring = true
                        ui.rtt = LatencyProbe.measure()
                        ui.measuring = false
                        ui.probedAt = System.currentTimeMillis()
                    }
                    ui.exit = info.await()
                }
                LinkState.Connecting -> Unit
            }
        }

        BoxWithConstraints(Modifier.fillMaxSize()) {
            val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
            val screen = maxHeight
            // 화면의 절반쯤을 지도로. 너무 작거나 너무 크지 않게(iOS와 같은 비율)
            val heroHeight = ((screen + top) * 0.52f).coerceIn(320.dp, 560.dp)
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
                            // 앱 안 wg로 연결돼 있으면 엔진이 알려 준 속도만큼 경로 위로 점이 흐른다
                            flowDown = if (connected) LinkMonitor.meter.current?.down ?: 0.0 else 0.0,
                            flowUp = if (connected) LinkMonitor.meter.current?.up ?: 0.0 else 0.0,
                            scanning = ui.scan.running,
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
                        Spacer(Modifier.weight(1f).widthIn(min = 12.dp))
                        ScanButton(ui.scan.running) { runScan(link) }
                        Spacer(Modifier.width(8.dp))
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
                            .padding(start = 16.dp, end = 16.dp, top = 22.dp, bottom = 24.dp)
                            .animateContentSize(tween(350)),
                    ) {
                        SessionPanel(link, wgUp, shown, o)
                        ConnectButton(link, o)
                        // 실패하면 버튼 바로 아래 이유 한 줄만 — 누르면 기록 전체
                        val error = ui.error
                        if (error != null && !busy) {
                            Box(Modifier.offset(y = (-6).dp)) { FailureLine(error) { ui.showLogs = true } }
                        }
                        ExitPanel(link, shown, locked)
                        if (ui.scan.running || ui.scan.checks.isNotEmpty()) {
                            ScanPanel(ui.scan, connected, ui.foldScan, ui.hideIP,
                                onFold = { ui.foldScan = !ui.foldScan; fold("foldScan", ui.foldScan) },
                                rescan = { runScan(link) })
                        }
                        SpeedPanel(ui.speed, speedVia(link), ui.foldSpeed,
                            onFold = { ui.foldSpeed = !ui.foldSpeed; fold("foldSpeed", ui.foldSpeed) },
                        ) {
                            val via = speedVia(link)
                            work.launch {
                                ui.speed.run(via)
                                if (ui.speed.phase == SpeedTest.Phase.Done) haptic(HapticFeedbackConstants.CONFIRM)
                            }
                        }
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

    /** 머리줄의 레이더 단추: 지금 네트워크를 검사한다 */
    @Composable
    private fun ScanButton(running: Boolean, onClick: () -> Unit) {
        val phase = pulse(1100, running)
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(30.dp)
                .background(Term.surface.copy(alpha = 0.85f), CircleShape)
                .border(1.dp, if (running) Term.amber.copy(alpha = 0.5f) else Term.border, CircleShape)
                .pressable(!running, onClick),
        ) {
            TermIcon(Glyph.Radio, 15.dp, if (running) Term.amber.copy(alpha = 1f - 0.5f * phase) else Term.text)
        }
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
            title = { Text("hop to ${target.city}?", style = Term.mono(16.sp, FontWeight.Bold, Term.text)) },
            text = {
                Text(
                    if (target.onDemand) "disconnects ${from.name}, then makes a new server in ${target.city} (~1m)"
                    else "disconnects ${from.name}, then connects ${target.name}",
                    style = Term.mono(12.sp, color = Term.muted),
                )
            },
            confirmButton = {
                TermSmallButton("hop → ${target.name} · ${target.city}") {
                    ui.hopTo = null
                    start(target, hopping = true)
                }
            },
            dismissButton = { TermSmallButton("stay on ${from.name}") { ui.hopTo = null } },
        )
    }

    // MARK: 세션

    @Composable
    private fun SessionPanel(link: LinkState, wgUp: Boolean, shown: VpnRegion, o: Options) {
        val connected = link == LinkState.Connected
        val busy = ui.busy
        val proto = if (wgUp) "wg" else "ikev2"
        // 꼬리표는 터널 상태만 따른다(iOS와 같음 — 진행은 아래 단계 막대와 버튼이 보여 준다)
        val (tag, tagColor) = when (link) {
            LinkState.Connected -> "[ OK ]" to Term.green
            LinkState.Connecting -> "[ .. ]" to Term.amber
            else -> "[DOWN]" to Term.muted
        }
        // 아직 한 번도 연결하지 않았다(시스템 VPN 허용 창이 아직 안 떴다)
        val fresh = remember(link) {
            runCatching { vpnManager.provisionedVpnProfileState }.getOrNull() == null && VpnService.prepare(this) != null
        }
        val text = when {
            connected -> "up → ${ui.savedRegion.name} · $proto"
            link == LinkState.Connecting -> "connecting"
            fresh -> "not set up · first connect asks once"
            else -> "disconnected · traffic goes out direct"
        }

        // 시스템이 알려 준 ikev2 오류나 NagoTun 엔진 실패(끊겨 있을 때만)
        val event by VpnEvents.lastEvent.collectAsState()
        val engineFailure by NeptunVpnService.failure.collectAsState()
        val notice = (event ?: engineFailure)?.takeIf { !connected && !busy && link != LinkState.Connecting && ui.error == null }

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
                    modifier = Modifier.weight(1f),
                ) { region ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        DotFlag(region, 38.dp, Modifier.padding(top = 3.dp))
                        // 긴 도시(frankfurt · stockholm · são paulo)는 줄이지 않고 글자를 줄여 한 줄에(iOS minimumScaleFactor 0.6)
                        FitText(region.city, Term.mono(28.sp, FontWeight.Bold, cityColor), minScale = 0.6f)
                    }
                }
                Spacer(Modifier.width(8.dp))
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
                if (linking) PhasePipeline(pipelineIndex(link)) else ExitLine(connected)
            }

            notice?.let { Text("! $it", style = Term.mono(12.sp, color = Term.amber), maxLines = 2, overflow = TextOverflow.Ellipsis) }

            AnimatedVisibility(connected && !busy, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
                if (wgUp && LinkMonitor.meter.hasData) {
                    TrafficPanel(LinkMonitor.meter)
                } else {
                    val stats = linkStats(wgUp)
                    Text(stats ?: if (wgUp) "link · waiting for stats…" else "link · ikev2 system tunnel",
                        style = Term.mono(12.sp, color = if (stats == null) Term.muted else Term.green),
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }

            FlagRow(flags(o, shown))
        }
    }

    /** `link · nagoing udp · tx … · rx …` 또는 `link · handshake 12s ago` — 터널이 알려 준 것 */
    private fun linkStats(wgUp: Boolean): String? {
        if (!wgUp) return null
        NeptunVpnService.transport()?.let { return "link · nagoing $it" }
        val at = LinkMonitor.handshakeMs.takeIf { it > 0 } ?: return null
        return "link · handshake ${clock((System.currentTimeMillis() - at) / 1000)} ago"
    }

    /** 진행 단계 문구로 어디까지 왔는지(api → boot → tunnel → up) */
    private fun pipelineIndex(link: LinkState): Int {
        if (link == LinkState.Connected && !ui.busy) return 3
        val text = ui.phase ?: ""
        return when {
            "ikev2" in text || "wg" in text || "nagoing" in text -> 2
            "boot" in text || "stopping" in text || "retry" in text || "waiting" in text || "new server" in text -> 1
            link == LinkState.Connecting && ui.phase == null -> 2
            else -> 0
        }
    }

    /**
     * `exit 54.199.12.4 · JP NRT ✓ matches` — 밖에서 보이는 IP가 고른 나라인지. 연결 전엔 지금 회선(isp) IP.
     * 누르면 IP 뒷부분을 가리거나 다시 보여 주고(스크린샷용, 기억해 둠), 길게 누르면 다시 잰다.
     */
    @OptIn(ExperimentalFoundationApi::class)
    @Composable
    private fun ExitLine(connected: Boolean) {
        val muted = SpanStyle(color = Term.muted)
        val label = if (connected) "exit" else "isp"
        val line = buildAnnotatedString {
            val exit = ui.exit
            if (exit == null) {
                withStyle(muted) { append("$label checking…") }
            } else {
                withStyle(muted) { append("$label ") }
                withStyle(SpanStyle(color = Term.num)) { append(if (ui.hideIP) ExitInfo.masked(exit.ip) else exit.ip) }
                withStyle(muted) { append(" · ${exit.country}" + if (exit.colo.isEmpty()) "" else " ${exit.colo}") }
                when {
                    !connected -> Unit
                    exit.country == ui.savedRegion.countryCode -> withStyle(SpanStyle(color = Term.green)) { append(" ✓ matches") }
                    else -> withStyle(SpanStyle(color = Term.amber)) { append(" ! not ${ui.savedRegion.countryCode} — leak?") }
                }
            }
        }
        Text(
            line,
            style = Term.mono(12.sp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.combinedClickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onLongClick = { work.launch { ui.exit = ExitInfo.fetch() } },
            ) {
                ui.hideIP = !ui.hideIP
                prefs.edit().putBoolean("hideIP", ui.hideIP).apply()
                haptic(HapticFeedbackConstants.CLOCK_TICK)
            },
        )
    }

    // MARK: 연결 버튼

    /** 연결 중에는 같은 버튼이 취소 버튼이 된다(지금 단계 + cancel). */
    @Composable
    private fun ConnectButton(link: LinkState, o: Options) {
        val busy = ui.busy
        val active = link == LinkState.Connected || link == LinkState.Connecting
        val primary = !busy && !active
        val enabled = busy || active || o.user.isNotBlank()
        val shape = RoundedCornerShape(6.dp)
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp, if (busy) Alignment.Start else Alignment.CenterHorizontally),
            modifier = Modifier
                .fillMaxWidth()
                .alpha(if (enabled) 1f else 0.35f)
                .background(if (primary) Term.green else Term.surface, shape)
                .border(1.dp, if (primary) Term.green else Term.border, shape)
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
                .heightIn(min = 52.dp)
                .padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            when {
                busy -> {
                    CircularProgressIndicator(Modifier.size(16.dp), color = Term.amber, strokeWidth = 1.8.dp)
                    Text((ui.phase ?: "working").replace("…", ""), style = Term.mono(14.sp, FontWeight.SemiBold, Term.text),
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text("cancel", style = Term.mono(14.sp, FontWeight.SemiBold, Term.amber))
                    TermIcon(Glyph.Close, 12.dp, Term.amber)
                }
                active -> {
                    TermIcon(Glyph.Stop, 17.dp, Term.red)
                    Text("disconnect", style = Term.mono(14.sp, FontWeight.SemiBold, Term.red))
                }
                else -> {
                    TermIcon(Glyph.Bolt, 18.dp, Term.bg)
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
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.dimmed(locked)) {
                VpnRegion.fixed.forEach { option ->
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
            // 임시 서버 나라: 고르면 그 나라에 서버를 새로 만든다
            OnDemandPanel(link, shown, locked)
        }
    }

    /** 임시 서버 나라: 처음엔 한 줄로 접혀 있고(고른 나라만 보임), 펴면 작은 칸으로 두 줄 */
    @Composable
    private fun OnDemandPanel(link: LinkState, shown: VpnRegion, locked: Boolean) {
        val connected = link == LinkState.Connected
        val regions = VpnRegion.entries.filter { it.onDemand }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 2.dp)) {
            OnDemandHeader(
                ui.foldOnDemand, regions.size,
                trailing = {
                    // 접혀 있어도 지금 고른 임시 나라는 보이게
                    if (ui.foldOnDemand && shown.onDemand) {
                        Box(Modifier.width(84.dp)) {
                            RegionChip(shown, true, connected && shown == ui.savedRegion, ui.rtt[shown], enabled = false) {}
                        }
                    }
                },
            ) {
                ui.foldOnDemand = !ui.foldOnDemand
                fold("foldOnDemand", ui.foldOnDemand)
            }
            AnimatedVisibility(!ui.foldOnDemand, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.dimmed(locked)) {
                        AdaptiveGrid(regions, 74.dp, 6.dp) { option, modifier ->
                            RegionChip(
                                option, option == shown, connected && option == ui.savedRegion, ui.rtt[option],
                                enabled = !locked, modifier = modifier,
                            ) { select(option, link) }
                        }
                    }
                    OnDemandFootnote(shown, ui.rtt[shown])
                }
            }
        }
    }

    // MARK: - 로그 창

    /** 연결 기록(실패 줄을 누르거나 settings → logs → view): 터널 상태 + 앱 기록, copy · clear · done */
    @Composable
    private fun LogsSheet(onDone: () -> Unit) {
        val logs by NagoLog.lines.collectAsState()
        var tunnel by remember { mutableStateOf<List<String>>(emptyList()) }
        LaunchedEffect(Unit) {
            val go = WgVpn.stats(this@MainActivity)
            tunnel = withContext(Dispatchers.IO) {
                buildList {
                    NeptunVpnService.stats()?.let { s ->
                        val ago = s.handshakeMs.takeIf { it > 0 }?.let { "handshake ${clock((System.currentTimeMillis() - it) / 1000)} ago · " } ?: ""
                        add("NagoTun · ${ago}rx ${TrafficMeter.bytes(s.rx)} · tx ${TrafficMeter.bytes(s.tx)}")
                    }
                    NeptunVpnService.transport()?.let { add("nagoing · $it") }
                    go?.let { s -> add("wg/go · rx ${TrafficMeter.bytes(s.rx)} · tx ${TrafficMeter.bytes(s.tx)}") }
                }
            }
        }
        val all = buildList {
            if (tunnel.isNotEmpty()) {
                add("# tunnel")
                addAll(tunnel)
            }
            add("# app")
            addAll(logs)
        }
        Dialog(onDismissRequest = onDone, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier
                    .fillMaxSize()
                    .background(Term.bg)
                    .statusBarsPadding()
                    .navigationBarsPadding()
                    .padding(16.dp),
            ) {
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .background(Term.surface, RoundedCornerShape(8.dp))
                        .border(1.dp, Term.border, RoundedCornerShape(8.dp)),
                ) {
                    // 대시보드 사이트와 같은 터미널 창: 점 세 개 제목 줄
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(7.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(Term.chrome, RoundedCornerShape(topStart = 8.dp, topEnd = 8.dp))
                            .padding(horizontal = 12.dp, vertical = 9.dp),
                    ) {
                        repeat(3) { Box(Modifier.size(10.dp).background(Term.dot, CircleShape)) }
                        Text("nago@vpn: ~/logs", style = Term.mono(11.5.sp, color = Term.muted), modifier = Modifier.padding(start = 8.dp))
                    }
                    TermDivider()
                    SelectionContainer {
                        Column(
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                            modifier = Modifier
                                .fillMaxSize()
                                .verticalScroll(rememberScrollState())
                                .padding(start = 14.dp, end = 14.dp, top = 14.dp, bottom = 18.dp),
                        ) {
                            if (tunnel.isNotEmpty()) {
                                Text("# tunnel", style = Term.mono(11.sp, color = Term.muted))
                                tunnel.forEach { Text(it, style = Term.mono(11.sp, color = Term.green)) }
                                Text(" ", style = Term.mono(11.sp))
                            }
                            Text("# app", style = Term.mono(11.sp, color = Term.muted))
                            if (logs.isEmpty()) Text("(empty)", style = Term.mono(11.sp, color = Term.muted))
                            logs.forEach { Text(it, style = Term.mono(11.sp, color = if ("✗" in it) Term.red else Term.text)) }
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    TermSmallButton("copy") {
                        getSystemService(ClipboardManager::class.java)
                            .setPrimaryClip(ClipData.newPlainText("nago log", all.joinToString("\n")))
                        haptic(HapticFeedbackConstants.CONFIRM)
                    }
                    TermSmallButton("clear", danger = true) { NagoLog.clear() }
                    Spacer(Modifier.weight(1f))
                    TermSmallButton("done", onClick = onDone)
                }
            }
        }
    }

    // MARK: - 설정

    @Composable
    private fun SettingsScreen(active: Boolean, appearance: String, onAppearance: (String) -> Unit) {
        var user by remember { mutableStateOf(prefs.getString("user", "wifiscan") ?: "wifiscan") }
        var password by remember { mutableStateOf("") }
        var savedPassword by remember { mutableStateOf(!prefs.getString("pw", "").isNullOrEmpty()) }
        var proto by remember { mutableStateOf(options().proto) }
        var engine by remember { mutableStateOf(options().engine) }
        var loops by remember { mutableStateOf(options().loops) }
        var nagoOn by remember { mutableStateOf(prefs.getBoolean("nagoOn", false)) }
        var nagoPrefer by remember { mutableStateOf(prefs.getString("nagoPrefer", "auto") ?: "auto") }
        var nagoFec by remember { mutableStateOf(prefs.getBoolean("nagoFec", true)) }
        var fast by remember { mutableStateOf(prefs.getBoolean("fast", true)) }
        var adblock by remember { mutableStateOf(prefs.getBoolean("adblock", false)) }
        var dns by remember { mutableStateOf(prefs.getString("dns", "") ?: "") }
        var allowLan by remember { mutableStateOf(prefs.getBoolean("allowLan", false)) }
        val logs by NagoLog.lines.collectAsState()
        // 연결 중에는 바꿔도 지금 연결에 안 들어가서 잠가 둔다.
        val enabled = !active

        fun savePassword() {
            if (preset != null || password.isEmpty()) return
            prefs.edit().putString("pw", password).apply()
            password = ""
            savedPassword = true
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Box(Modifier.padding(top = 8.dp)) { TermHeader("settings") }
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
                if (preset != null || savedPassword) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text("pw", style = Term.mono(15.sp, color = Term.muted), modifier = Modifier.width(46.dp))
                        Text("••••••••", style = Term.mono(15.sp, color = Term.muted))
                        Text(if (preset != null) "built-in" else "saved", style = Term.mono(11.sp, color = Term.muted))
                        Spacer(Modifier.weight(1f))
                        // 내장 비밀번호는 못 바꾸지만, 넣어 둔 건 다시 입력할 수 있게 둔다.
                        if (preset == null) TermSmallButton("change", enabled = enabled) { savedPassword = false }
                    }
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.weight(1f)) {
                            TermField("pw", password, { password = it }, "password", secure = true, enabled = enabled)
                        }
                        if (password.isNotEmpty()) TermSmallButton("save", enabled = enabled) { savePassword() }
                    }
                }
            }

            TermBlock("protocol") {
                TermChoice(VpnProto.entries.map { it.label to it }, proto, enabled) {
                    proto = it
                    prefs.edit().putString("proto", it.name).apply()
                }
                if (proto != VpnProto.ikev2) {
                    TermDivider()
                    KeyRow("engine") {
                        TermChoice(listOf("NagoTun" to "neptun", "go" to "go"), engine, enabled) {
                            engine = it
                            prefs.edit().putString("engine", it).apply()
                        }
                    }
                    if (engine == "neptun") {
                        TermDivider()
                        KeyRow("loops") {
                            TermChoice(listOf("1" to 1, "2" to 2), loops, enabled) {
                                loops = it
                                prefs.edit().putInt("loops", it).apply()
                            }
                        }
                        TermDivider()
                        ToggleRow("--nagoing", nagoOn, enabled) {
                            nagoOn = it
                            prefs.edit().putBoolean("nagoOn", it).apply()
                        }
                        AnimatedVisibility(nagoOn, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
                            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                Text(
                                    "tunnels wireguard through networks that block vpns: quic-style udp first, real tls 1.3 on " +
                                        "tcp 443 if udp is blocked. turn on only where wg won't connect — it costs some speed and battery.",
                                    style = Term.mono(12.sp, color = Term.muted),
                                )
                                KeyRow("prefer") {
                                    TermChoice(listOf("auto" to "auto", "udp" to "udp", "tcp" to "tcp"), nagoPrefer, enabled) {
                                        nagoPrefer = it
                                        prefs.edit().putString("nagoPrefer", it).apply()
                                    }
                                }
                                ToggleRow("--fec", nagoFec, enabled) {
                                    nagoFec = it
                                    prefs.edit().putBoolean("nagoFec", it).apply()
                                }
                            }
                        }
                    }
                }
                if (proto != VpnProto.wg) {
                    TermDivider()
                    ToggleRow("--fast", fast, enabled) {
                        fast = it
                        prefs.edit().putBoolean("fast", it).apply()
                    }
                }
            }

            TermBlock("connection") {
                // 안드로이드는 자동 연결·킬 스위치를 시스템 VPN 설정(항상 켜기 · VPN 없이 연결 차단)에서 켠다
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("auto-connect · kill switch", style = Term.mono(13.sp, color = Term.muted))
                        Text("always-on vpn · block without vpn", style = Term.mono(11.sp, color = Term.muted.copy(alpha = 0.7f)))
                    }
                    TermSmallButton("system ›") { startActivity(Intent(Settings.ACTION_VPN_SETTINGS)) }
                }
                TermDivider()
                ToggleRow("--allow-lan", allowLan, enabled) {
                    allowLan = it
                    prefs.edit().putBoolean("allowLan", it).apply()
                }
            }

            TermBlock("dns") {
                ToggleRow("--adblock", adblock, enabled) {
                    adblock = it
                    prefs.edit().putBoolean("adblock", it).apply()
                }
                TermDivider()
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.alpha(if (adblock) 0.4f else 1f)) {
                    Box(Modifier.weight(1f)) {
                        TermField("custom", dns, { dns = it; prefs.edit().putString("dns", it).apply() }, "1.1.1.1",
                            enabled = enabled && !adblock)
                    }
                    val valid = dns.isBlank() || parseDns(dns) != null
                    Text(if (valid) "wg" else "invalid", style = Term.mono(12.sp, color = if (valid) Term.muted else Term.red))
                }
            }

            TermBlock("server") {
                KeyRow("accelerator") { Text("on · tcp", style = Term.mono(13.sp, color = Term.green)) }
            }

            // 마지막 몇 줄(연결 단계 · 실패 이유)을 바로 보여 주고, 전체는 view로
            TermBlock("logs") {
                val recent = logs.takeLast(6)
                if (recent.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        recent.forEach { line ->
                            // "MM-dd HH:mm:ss 내용"에서 날짜는 떼고 시각부터
                            Text(line.drop(6), style = Term.mono(10.5.sp, color = if ("✗" in line) Term.red else Term.muted),
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
                TermWideButton({ ui.showLogs = true }) {
                    Text("view", style = Term.mono(14.sp, FontWeight.SemiBold, Term.text))
                    Spacer(Modifier.weight(1f))
                    Text("${logs.size} lines", style = Term.mono(14.sp, FontWeight.SemiBold, Term.muted))
                }
            }

            TermBlock("about") {
                val info = runCatching { packageManager.getPackageInfo(packageName, 0) }.getOrNull()
                Text("nago vpn ${info?.versionName ?: "?"} (${info?.longVersionCode ?: "?"}) · android", style = Term.mono(13.sp))
                Text("NagoTun 2.2.3-nago.1 (NepTUN ce18515) · wireguard-go 1.0.20230706",
                    style = Term.mono(13.sp, color = Term.muted))
            }
        }
    }
}
