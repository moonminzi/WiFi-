package com.nago.vpn

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import java.util.TimeZone
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

// vpn 탭의 route 지도(iOS RouteMap.swift · RouteGeometry.swift와 같은 모양·움직임).
// 평면 좌표는 (경도°, 메르카토르°) — 위도를 메르카토르로 펴서 경도와 같은 단위로 쓴다.

data class WorldPoint(val x: Double, val y: Double)

/** 위도/경도 한 점과 그곳 이름 */
data class Geo(val lat: Double, val lon: Double, val city: String) {
    val world get() = WorldPoint(lon, RouteMath.mercY(lat))

    /** 대권 거리(km) */
    fun km(other: Geo): Double {
        val p1 = lat * PI / 180
        val p2 = other.lat * PI / 180
        val dp = p2 - p1
        val dl = (other.lon - lon) * PI / 180
        val h = sin(dp / 2).pow(2) + cos(p1) * cos(p2) * sin(dl / 2).pow(2)
        return 2 * 6371 * asin(min(1.0, sqrt(h)))
    }

    companion object {
        private val seoul = Geo(37.5665, 126.978, "seoul")
        private val zones = mapOf(
            "Asia/Seoul" to seoul,
            "Asia/Tokyo" to Geo(35.6762, 139.6503, "tokyo"),
            "Asia/Shanghai" to Geo(31.2304, 121.4737, "shanghai"),
            "Asia/Hong_Kong" to Geo(22.3193, 114.1694, "hong kong"),
            "Asia/Taipei" to Geo(25.033, 121.5654, "taipei"),
            "Asia/Singapore" to Geo(1.3521, 103.8198, "singapore"),
            "Asia/Bangkok" to Geo(13.7563, 100.5018, "bangkok"),
            "Asia/Ho_Chi_Minh" to Geo(10.8231, 106.6297, "ho chi minh"),
            "Asia/Manila" to Geo(14.5995, 120.9842, "manila"),
            "Asia/Jakarta" to Geo(-6.2088, 106.8456, "jakarta"),
            "Asia/Kolkata" to Geo(28.6139, 77.209, "new delhi"),
            "Asia/Dubai" to Geo(25.2048, 55.2708, "dubai"),
            "Europe/London" to Geo(51.5074, -0.1278, "london"),
            "Europe/Paris" to Geo(48.8566, 2.3522, "paris"),
            "Europe/Berlin" to Geo(52.52, 13.405, "berlin"),
            "Europe/Madrid" to Geo(40.4168, -3.7038, "madrid"),
            "Europe/Rome" to Geo(41.9028, 12.4964, "rome"),
            "Europe/Amsterdam" to Geo(52.3676, 4.9041, "amsterdam"),
            "Europe/Moscow" to Geo(55.7558, 37.6173, "moscow"),
            "America/New_York" to Geo(40.7128, -74.006, "new york"),
            "America/Chicago" to Geo(41.8781, -87.6298, "chicago"),
            "America/Denver" to Geo(39.7392, -104.9903, "denver"),
            "America/Los_Angeles" to Geo(34.0522, -118.2437, "los angeles"),
            "America/Toronto" to Geo(43.6532, -79.3832, "toronto"),
            "America/Vancouver" to Geo(49.2827, -123.1207, "vancouver"),
            "America/Mexico_City" to Geo(19.4326, -99.1332, "mexico city"),
            "America/Sao_Paulo" to Geo(-23.5505, -46.6333, "sao paulo"),
            "Australia/Sydney" to Geo(-33.8688, 151.2093, "sydney"),
            "Australia/Melbourne" to Geo(-37.8136, 144.9631, "melbourne"),
            "Pacific/Auckland" to Geo(-36.8485, 174.7633, "auckland"),
            "Pacific/Honolulu" to Geo(21.3069, -157.8583, "honolulu"),
        )

        /** 이 기기의 대략적인 위치. 위치 권한 없이 시간대의 도시로 어림한다(모르는 시간대면 서울). */
        val here: Geo by lazy { zones[TimeZone.getDefault().id] ?: seoul }
    }
}

/** 그 나라 AWS 리전이 있는 곳 */
val VpnRegion.geo: Geo
    get() = when (this) {
        VpnRegion.kr -> Geo(37.5665, 126.978, city)
        VpnRegion.jp -> Geo(35.6762, 139.6503, city)
        VpnRegion.us -> Geo(45.84, -119.70, city)
        VpnRegion.uk -> Geo(51.5074, -0.1278, city)
        VpnRegion.sg -> Geo(1.3521, 103.8198, city)
        VpnRegion.de -> Geo(50.1109, 8.6821, city)
        VpnRegion.fr -> Geo(48.8566, 2.3522, city)
        VpnRegion.ie -> Geo(53.3498, -6.2603, city)
        VpnRegion.se -> Geo(59.3293, 18.0686, city)
        VpnRegion.ca -> Geo(45.5017, -73.5673, city)
        VpnRegion.br -> Geo(-23.5505, -46.6333, city)
        VpnRegion.au -> Geo(-33.8688, 151.2093, city)
        VpnRegion.`in` -> Geo(19.0760, 72.8777, city)
    }

/** 지도 칸 값(2부터 VpnRegion 순서) */
val VpnRegion.mapCode: Int get() = 2 + ordinal

object RouteMath {
    fun mercY(lat: Double): Double {
        val l = min(85.0, max(-85.0, lat)) * PI / 180
        return ln(tan(PI / 4 + l / 2)) * 180 / PI
    }

    fun lat(mercY: Double): Double = (2 * atan(exp(mercY * PI / 180)) - PI / 2) * 180 / PI

    /** ref에서 180° 안쪽으로 경도를 편다(태평양을 건너는 경로가 지도 끝으로 돌아가지 않게) */
    fun unwrap(lon: Double, near: Double): Double {
        var x = lon
        while (x - near > 180) x -= 360
        while (x - near < -180) x += 360
        return x
    }

    fun normalized(lon: Double): Double {
        val x = (lon + 180) % 360
        return (if (x < 0) x + 360 else x) - 180
    }

    fun easeInOut(t: Double) = if (t < 0.5) 4 * t * t * t else 1 - (-2 * t + 2).pow(3) / 2
    fun easeOut(t: Double) = 1 - (1 - t).pow(3)

    fun smooth(a: Double, b: Double, x: Double): Double {
        val t = min(1.0, max(0.0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /** 1149 → "1,149" */
    fun grouped(n: Int): String = "%,d".format(n)
}

/** 출발점에서 도착점까지 북쪽으로 휜 2차 곡선. 같은 곳이면(서울에서 kr) [local] — 도착점을 도는 고리로 그린다. */
class RouteArc(from: Geo, to: Geo) {
    val a = from.world
    val b = WorldPoint(RouteMath.unwrap(to.lon, from.lon), RouteMath.mercY(to.lat))
    val local: Boolean
    private val control: WorldPoint
    private val lengths = DoubleArray(SAMPLES + 1)

    init {
        val dx = b.x - a.x
        val dy = b.y - a.y
        val len = max(hypot(dx, dy), 1e-9)
        var nx = -dy / len
        var ny = dx / len
        if (ny < 0 || (ny == 0.0 && nx < 0)) {
            nx = -nx
            ny = -ny
        }
        control = WorldPoint((a.x + b.x) / 2 + nx * len * 0.22, (a.y + b.y) / 2 + ny * len * 0.22)
        var p = a
        for (i in 1..SAMPLES) {
            val q = bezier(i.toDouble() / SAMPLES)
            lengths[i] = lengths[i - 1] + hypot(q.x - p.x, q.y - p.y)
            p = q
        }
        local = len < 2.5
    }

    /** 길이 비율(0…1)로 점을 찾는다(웨이포인트가 고르게 찍히게) */
    fun point(f: Double): WorldPoint {
        val total = lengths[SAMPLES]
        if (total <= 0) return a
        val target = min(1.0, max(0.0, f)) * total
        var i = 1
        while (i < SAMPLES && lengths[i] < target) i++
        val l0 = lengths[i - 1]
        val l1 = lengths[i]
        val t = (i - 1 + if (l1 > l0) (target - l0) / (l1 - l0) else 0.0) / SAMPLES
        return bezier(t)
    }

    private fun bezier(t: Double): WorldPoint {
        val u = 1 - t
        return WorldPoint(u * u * a.x + 2 * u * t * control.x + t * t * b.x, u * u * a.y + 2 * u * t * control.y + t * t * b.y)
    }

    private companion object {
        const val SAMPLES = 64
    }
}

/** 연결 한 번의 진행. 단계가 바뀔 때마다 웨이포인트가 하나 찍히고 머리(커서)가 거기까지 간다. 시간은 초. */
class RouteRun(start: Double) {
    class Mark(val f: Double, val time: Double)

    val stops = mutableListOf(Mark(0.0, start))
    var finish: Mark? = null
        private set
    var failure: Mark? = null
        private set
    /** 이 시각부터 경로가 사라진다 */
    var gone: Double? = null
    private var hops = 0

    /** 첫 단계(서버 확인)는 출발점이다. 그다음 단계부터 웨이포인트를 찍는다. */
    fun hop(now: Double) {
        hops += 1
        if (hops <= 1 || finish != null || failure != null || stops.size >= 8) return
        stops += Mark(next(stops.last().f, stops.size), now)
    }

    fun complete(now: Double) {
        if (finish == null) finish = Mark(head(now), now)
    }

    fun fail(now: Double) {
        if (finish == null && failure == null) failure = Mark(head(now), now)
    }

    /** 지금 머리 자리(0…1). 다음 단계를 기다리는 동안엔 다음 자리 쪽으로 천천히 기어간다. */
    fun head(now: Double): Double {
        finish?.let { val u = min(1.0, max(0.0, (now - it.time) / 0.8)); return it.f + (1 - it.f) * RouteMath.easeOut(u) }
        failure?.let { return it.f }
        val last = stops.last()
        val prev = if (stops.size > 1) stops[stops.size - 2] else last
        val since = max(0.0, now - last.time)
        if (since < TRAVEL) return prev.f + (last.f - prev.f) * RouteMath.easeOut(since / TRAVEL)
        val creep = 1 - exp(-(since - TRAVEL) / 6)
        return last.f + (next(last.f, stops.size) - last.f) * 0.5 * creep
    }

    companion object {
        const val TRAVEL = 0.6
        private const val SPAN = 0.88
        private const val USUAL_HOPS = 4
        fun next(after: Double, index: Int) =
            if (index <= USUAL_HOPS) SPAN * index / (USUAL_HOPS + 1) else after + (0.95 - after) * 0.4
    }
}

/** 지도 카메라. z = log2(1°당 px) */
data class Camera(val x: Double, val y: Double, val z: Double) {
    val scale get() = 2.0.pow(z)
}

/** 한 카메라에서 목표로 날아가는 중. 멀리 갈 때는 중간에 한 번 멀어졌다가 다가간다. */
class Flight(private val from: Camera, to: Camera, width: Double, private val start: Double) {
    private val duration: Double
    private val bump: Double

    init {
        val k = 2.0.pow(min(from.z, to.z))
        val dist = hypot(to.x - from.x, to.y - from.y) * k
        duration = 0.9 + 0.6 * min(1.0, dist / width)
        bump = min(1.4, log2(1 + dist / width))
    }

    /** 끝났으면 null */
    fun camera(to: Camera, now: Double): Camera? {
        val u = (now - start) / duration
        if (u >= 1) return null
        val e = RouteMath.easeInOut(max(0.0, u))
        return Camera(from.x + (to.x - from.x) * e, from.y + (to.y - from.y) * e, from.z + (to.z - from.z) * e - bump * sin(PI * e))
    }
}

enum class RouteStage { Idle, Connecting, Connected, Failed }

private fun nowSeconds() = System.nanoTime() / 1e9

/**
 * 화면 위쪽을 꽉 채우는 route 지도.
 * - 대기: 고른 나라까지 점선(다른 나라 길은 아주 옅게), 나라 점을 누르면 그 나라를 고른다
 * - 연결 중: 단계([hop])가 바뀔 때마다 웨이포인트, 깜빡이는 블록 커서가 경로를 따라간다
 * - 연결됨: 경로를 끝까지 긋고 그 나라로 확대, 나라 점이 초록으로 켜지고 신호가 퍼진다
 * - 실패: 커서가 빨갛게 멈췄다가 사라진다
 * [top]·[bottom]은 머리줄·콘솔에 가려지는 높이 — 그만큼 비켜 맞춘다.
 */
@Composable
fun RouteMap(
    destination: VpnRegion,
    stage: RouteStage,
    hop: String?,
    height: Dp,
    top: Dp,
    bottom: Dp,
    onSelect: ((VpnRegion) -> Unit)?,
    /** 지금 받는·보내는 속도(바이트/초). 연결돼 있을 때 경로 위 흐름의 양 */
    flowDown: Double = 0.0,
    flowUp: Double = 0.0,
    /** 네트워크 검사 중(레이더) */
    scanning: Boolean = false,
) {
    val context = LocalContext.current
    remember { WorldDots.load(context) }
    val model = remember { RouteMapModel() }
    val measurer = rememberTextMeasurer()
    var now by remember { mutableDoubleStateOf(nowSeconds()) }
    val select by rememberUpdatedState(onSelect)
    val flowing = stage == RouteStage.Connected && maxOf(flowDown, flowUp) > FlowLane.FLOOR

    // 움직일 게 있을 때만 프레임마다 다시 그린다(연결 중엔 계속, 바뀐 뒤엔 잠깐, 연결된 뒤엔 신호가 퍼지는 동안)
    // 흐름이 있으면 계속, 멈추면 흐르던 점이 서서히 사라지는 동안(2.5초) 더 그린다
    LaunchedEffect(stage, destination, hop, flowing, scanning) {
        val wake = when {
            stage == RouteStage.Connecting || flowing || scanning -> Double.MAX_VALUE
            stage == RouteStage.Connected -> 10.0
            else -> 3.5
        }
        val end = nowSeconds() + wake
        while (nowSeconds() < end) {
            withFrameNanos { now = nowSeconds() }
        }
        now = nowSeconds()
    }

    Canvas(
        Modifier
            .fillMaxWidth()
            .height(height)
            .pointerInput(Unit) {
                detectTapGestures { p -> model.regionNear(p)?.let { r -> select?.invoke(r) } }
            },
    ) {
        model.sync(stage, destination, hop, now)
        model.flow(flowDown, flowUp, scanning, now)
        model.draw(this, measurer, now, top.toPx(), bottom.toPx())
    }
}

/**
 * 경로 위 흐름 한 줄(받기 또는 보내기). 속도가 1초마다 바뀌어도 점이 튀지 않게 상태를 이어 간다(iOS FlowLane과 같음):
 * 자리(phase)는 매 프레임 속도만큼 더해 가고, 양·속도는 목표값을 부드럽게 따라가며,
 * 주고받는 게 멈추면 점이 계속 흐르면서 1.5초쯤에 걸쳐 사라진다.
 */
class FlowLane {
    /** 로그 눈금 속도: 400 B/s → 0, 4 MB/s → 4 */
    var level = 0.0
        private set
    /** 보이는 정도 0…1 */
    var amount = 0.0
        private set
    /** 지금까지 흐른 거리(경로 한 번 = 1) */
    var phase = 0.0
        private set

    /** 속도에 맞는 점 개수 */
    val count get() = minOf(SLOTS.toDouble(), maxOf(2.0, 2 + level * 3.5))
    /** 지금 보이는 점 개수. [count]를 1초에 4개씩만 따라가서 점 하나가 0.25초에 걸쳐 나타나고 사라진다 */
    var shown = 2.0
        private set

    fun step(rate: Double, active: Boolean, dt: Double) {
        val on = active && rate > FLOOR
        if (on) {
            val target = minOf(4.0, log10(rate / FLOOR))
            level += (target - level) * (1 - exp(-dt / 0.8))
        }
        amount += ((if (on) 1.0 else 0.0) - amount) * (1 - exp(-dt / if (on) 0.35 else 0.5))
        if (amount < 0.002 && !on) amount = 0.0
        phase = (phase + (0.22 + 0.08 * level) * dt) % 1.0
        shown += (count - shown).coerceIn(-4 * dt, 4 * dt)
    }

    companion object {
        /** 이보다 느리면(바이트/초) 흐름이 없는 것으로 본다 */
        const val FLOOR = 400.0
        const val SLOTS = 18
        /** 점이 늘거나 줄 때 앞에서부터 켜고 끄는 자리. 몇 개를 켜든 경로 위에 고르게 퍼진다(반전 비트 순서). */
        val offsets = DoubleArray(SLOTS) { i ->
            var x = 0.0
            var f = 0.5
            var n = i
            while (n > 0) {
                if (n and 1 == 1) x += f
                f /= 2
                n = n shr 1
            }
            x
        }
    }
}

class RouteMapModel {
    private enum class Framing { Route, Focus }

    private companion object {
        /** 같은 도시(서울에서 kr)일 때 목적지를 도는 고리 반지름(dp). 22였을 땐 고리·번호·you·꼬리표가 한 점에 몰려 답답했다 */
        const val ORBIT = 34.0
    }

    private val origin = Geo.here
    private val arcs = VpnRegion.entries.associateWith { RouteArc(origin, it.geo) }
    private var started = false
    private var stage = RouteStage.Idle
    private var stageAt = 0.0
    private var destination = VpnRegion.kr
    private var arc = arcs.getValue(VpnRegion.kr)
    private var lastHop: String? = null
    private var run: RouteRun? = null
    private var framing = Framing.Route
    private var flight: Flight? = null
    private var focusAt: Double? = null
    private val down = FlowLane()
    private val up = FlowLane()
    private var flowAt: Double? = null
    private var scanning = false
    private var scanAt = 0.0
    /** 검사가 끝난 시각(레이더가 서서히 사라진다) */
    private var scanEndAt: Double? = null
    private var w = 0.0
    private var h = 0.0
    private var top = 0.0
    private var bottom = 0.0
    private var d = 1.0
    private val hits = mutableListOf<Pair<VpnRegion, Offset>>()
    private var dotKey: List<Double>? = null
    private var dotLayers: List<Triple<Path, Path, Float>> = emptyList()

    // MARK: 상태 맞추기

    fun flow(downRate: Double, upRate: Double, newScanning: Boolean, now: Double) {
        // 멈춰 있던 뒤 첫 프레임에 한꺼번에 건너뛰지 않게
        val dt = minOf(0.1, maxOf(0.0, flowAt?.let { now - it } ?: 0.0))
        flowAt = now
        val active = stage == RouteStage.Connected
        down.step(downRate, active, dt)
        up.step(upRate, active, dt)
        if (newScanning && !scanning) {
            // 사라지는 중에 다시 켜지면 각도가 튀지 않게 이어 간다
            val resuming = scanEndAt?.let { now - it < 0.6 } ?: false
            if (!resuming) scanAt = now
            scanEndAt = null
        } else if (!newScanning && scanning) {
            scanEndAt = now
        }
        scanning = newScanning
    }

    fun sync(newStage: RouteStage, newDestination: VpnRegion, hop: String?, now: Double) {
        if (!started) {
            started = true
            destination = newDestination
            arc = arcs.getValue(newDestination)
        }
        if (newDestination != destination) {
            val from = camera(now)
            destination = newDestination
            arc = arcs.getValue(newDestination)
            fly(from, now)
            // 연결 중에 나라가 바뀌면(갈아타기) 새 길에서 처음부터
            if (stage == RouteStage.Connecting && newStage == RouteStage.Connecting) run = RouteRun(now)
        }
        if (newStage != stage) transition(newStage, now)
        if (hop != lastHop) {
            lastHop = hop
            if (hop != null && stage == RouteStage.Connecting) run?.hop(now)
        }
    }

    /** 사라지기로 했지만 아직 유예 시간 안이라 이어 갈 수 있는 경로인지 */
    private fun resumable(now: Double): Boolean {
        val r = run ?: return false
        val gone = r.gone ?: return false
        return r.failure == null && r.finish == null && gone > now
    }

    private fun transition(newStage: RouteStage, now: Double) {
        val previous = stage
        stage = newStage
        stageAt = now
        when (newStage) {
            RouteStage.Connecting -> {
                // 잠깐 대기로 튀었던 거면 같은 경로를 이어 간다(처음부터 다시 그리지 않게)
                if (resumable(now)) run?.gone = null else run = RouteRun(now)
                focusAt = null
                setFraming(Framing.Route, now)
            }
            RouteStage.Connected -> {
                if (resumable(now)) run?.gone = null
                val r = run
                if (r == null || r.failure != null || r.gone != null) run = RouteRun(now)
                run?.complete(now)
                focusAt = now + 0.6
            }
            RouteStage.Failed -> {
                run?.fail(now)
                if (run?.gone == null) run?.gone = now + 2.5
            }
            RouteStage.Idle -> {
                // 연결 중에서 바로 넘어온 거면 1초 유예(그새 다시 연결 중이 되면 이어 간다)
                if (run != null && run?.gone == null) run?.gone = now + if (previous == RouteStage.Connecting) 1.0 else 0.0
                focusAt = null
                if (previous != RouteStage.Connecting) setFraming(Framing.Route, now)
            }
        }
    }

    private fun setFraming(newFraming: Framing, now: Double) {
        if (newFraming == framing) return
        val from = camera(now)
        framing = newFraming
        fly(from, now)
    }

    // MARK: 카메라

    private fun fly(from: Camera, now: Double) {
        flight = if (w > 0) Flight(from, target(), w, now) else null
    }

    private fun camera(now: Double): Camera {
        val to = target()
        val f = flight ?: return to
        val cam = f.camera(to, now)
        if (cam == null) flight = null
        return cam ?: to
    }

    private fun target(): Camera {
        val width = max(w, 1.0)
        val height = max(h, 1.0)
        val shift = (top - bottom) / 2
        val focusZ = log2(min(16 * d, max(9 * d, width / 30)))
        fun at(p: WorldPoint, z: Double) = Camera(p.x, p.y + shift / 2.0.pow(z), z)
        return when (framing) {
            Framing.Focus -> at(arc.b, focusZ)
            Framing.Route -> {
                if (arc.local) {
                    // 고리 아래에 꼬리표(you ⇄ kr · seoul)가 붙으니 서울을 가운데보다 12dp 위로
                    val z = focusZ - 0.6
                    return Camera(arc.b.x, arc.b.y + (shift - 12 * d) / 2.0.pow(z), z)
                }
                val apex = arc.point(0.5)
                val xs = listOf(arc.a.x, arc.b.x, apex.x)
                val ys = listOf(arc.a.y, arc.b.y, apex.y)
                val minX = xs.min()
                val maxX = xs.max()
                val minY = ys.min()
                val maxY = ys.max()
                val fit = minOf(
                    max(width - 96 * d, 60 * d) / max(maxX - minX, 1.0),
                    max(height - top - bottom - 72 * d, 60 * d) / max(maxY - minY, 1.0),
                    2.0.pow(focusZ),
                )
                val k = max(fit, width / 400)
                Camera((minX + maxX) / 2, (minY + maxY) / 2 - 4 * d / k + shift / k, log2(k))
            }
        }
    }

    /** 누른 자리에서 가장 가까운 나라(32dp 안) */
    fun regionNear(p: Offset): VpnRegion? {
        val nearest = hits.minByOrNull { hypot((it.second.x - p.x).toDouble(), (it.second.y - p.y).toDouble()) } ?: return null
        val dist = hypot((nearest.second.x - p.x).toDouble(), (nearest.second.y - p.y).toDouble())
        return if (dist < 32 * d) nearest.first else null
    }

    // MARK: 그리기

    private inner class View(val cam: Camera) {
        val k = cam.scale
        val x0 get() = cam.x - w / 2 / k
        val x1 get() = cam.x + w / 2 / k
        val y0 get() = cam.y - h / 2 / k
        val y1 get() = cam.y + h / 2 / k
        fun sx(x: Double) = (w / 2 + (x - cam.x) * k).toFloat()
        fun sy(y: Double) = (h / 2 - (y - cam.y) * k).toFloat()
        fun point(p: WorldPoint) = Offset(sx(p.x), sy(p.y))
    }

    fun draw(scope: DrawScope, tm: TextMeasurer, now: Double, topPx: Float, bottomPx: Float) = with(scope) {
        if (size.width <= 0 || size.height <= 0) return@with
        d = density.toDouble()
        top = topPx.toDouble()
        bottom = bottomPx.toDouble()
        if (w != size.width.toDouble() || h != size.height.toDouble()) {
            w = size.width.toDouble()
            h = size.height.toDouble()
            flight = null    // 화면 크기가 바뀌면 바로 새 자리로
        }
        focusAt?.let { if (now >= it) { focusAt = null; setFraming(Framing.Focus, now) } }
        val view = View(camera(now))
        hits.clear()

        drawRect(Term.bg)
        drawDots(this, view, now)
        drawEdgeFade(this)
        val radar = radarAlpha(now)
        if ((scanning || scanEndAt != null) && radar > 0.005) drawRadar(this, view, now, radar)
        drawRoute(this, tm, view, now)
        drawHud(this, tm, view)
    }

    /** 점 간격이 화면에서 4.5dp쯤 되는 단계. 단계가 바뀌는 언저리에서만 두 단계를 섞는다. 카메라가 가만있으면 모양을 재사용. */
    private fun drawDots(s: DrawScope, view: View, now: Double) {
        val levels = WorldDots.levels
        if (levels.isEmpty()) return
        val lod = min((levels.size - 1).toDouble(), max(0.0, log2(4.5 * d / (WorldDots.step * view.k))))
        val lo = floor(lod).toInt()
        val mix = if (lo >= levels.size - 1) 0.0 else RouteMath.smooth(0.42, 0.58, lod - lo)
        val code = destination.mapCode
        val glow = when (stage) {
            RouteStage.Connected -> 0.25 + 0.65 * RouteMath.smooth(0.0, 0.9, now - stageAt - 0.5)
            RouteStage.Connecting -> 0.45
            else -> 0.3
        }
        val key = listOf(view.cam.x, view.cam.y, view.cam.z, w, h, code.toDouble(), if (Term.dark) 1.0 else 0.0)
        if (key != dotKey) {
            dotKey = key
            dotLayers = buildDots(view, levels, lo, mix, code)
        }
        for ((land, lit, alpha) in dotLayers) {
            s.drawPath(land, Term.dot.copy(alpha = alpha))
            s.drawPath(lit, Term.green.copy(alpha = alpha * glow.toFloat()))
        }
    }

    private fun buildDots(view: View, levels: List<WorldDots.Level>, lo: Int, mix: Double, code: Int): List<Triple<Path, Path, Float>> {
        val out = mutableListOf<Triple<Path, Path, Float>>()
        for ((index, alpha) in listOf(lo to 1 - mix, lo + 1 to mix)) {
            if (alpha <= 0.01 || index >= levels.size) continue
            val level = levels[index]
            val cell = level.cell
            val dot = min(3.4 * d, max(1.2 * d, cell * view.k * 0.42)).toFloat()
            val i0 = floor((view.x0 + 180) / cell).toInt() - 1
            val i1 = kotlin.math.ceil((view.x1 + 180) / cell).toInt()
            val j0 = max(0, floor((WorldDots.yTop - view.y1) / cell).toInt() - 1)
            val j1 = min(level.rows - 1, kotlin.math.ceil((WorldDots.yTop - view.y0) / cell).toInt())
            if (i0 > i1 || j0 > j1) continue
            val land = Path()
            val lit = Path()
            for (j in j0..j1) {
                val y = view.sy(WorldDots.yTop - (j + 0.5) * cell) - dot / 2
                for (i in i0..i1) {
                    val v = level.value(i, j)
                    if (v == 0) continue
                    val rect = Rect(Offset(view.sx(-180 + (i + 0.5) * cell) - dot / 2, y), Size(dot, dot))
                    if (v == code) lit.addRect(rect) else land.addRect(rect)
                }
            }
            out += Triple(land, lit, alpha.toFloat())
        }
        return out
    }

    /** 가장자리를 배경색으로 흐려서 점이 끝에서 잘려 보이지 않게(위·아래는 머리줄·콘솔 밑으로 더 길게) */
    private fun drawEdgeFade(s: DrawScope) = with(s) {
        val bg = Term.bg
        val clear = bg.copy(alpha = 0f)
        val side = 28 * density
        val topFade = (34 * density + top * 0.8).toFloat()
        val bottomFade = (34 * density + bottom * 1.2).toFloat()
        drawRect(Brush.horizontalGradient(listOf(bg, clear), 0f, side), size = Size(side, size.height))
        drawRect(Brush.horizontalGradient(listOf(clear, bg), size.width - side, size.width),
            topLeft = Offset(size.width - side, 0f), size = Size(side, size.height))
        drawRect(Brush.verticalGradient(listOf(bg, clear), 0f, topFade), size = Size(size.width, topFade))
        drawRect(Brush.verticalGradient(listOf(clear, bg), size.height - bottomFade, size.height),
            topLeft = Offset(0f, size.height - bottomFade), size = Size(size.width, bottomFade))
    }

    private fun drawRoute(s: DrawScope, tm: TextMeasurer, view: View, now: Double) = with(s) {
        val local = arc.local
        val b = view.point(arc.b)
        val orbit = (ORBIT * density).toFloat()
        fun at(f: Double): Offset {
            if (local) {
                val angle = -PI / 2 + f * 2 * PI
                return Offset(b.x + orbit * cos(angle).toFloat(), b.y + orbit * sin(angle).toFloat())
            }
            return view.point(arc.point(f))
        }
        fun line(f0: Double, f1: Double): Path {
            val path = Path()
            val n = max(2, ((f1 - f0) * 72).toInt() + 1)
            for (i in 0..n) {
                val p = at(f0 + (f1 - f0) * i / n)
                if (i == 0) path.moveTo(p.x, p.y) else path.lineTo(p.x, p.y)
            }
            return path
        }

        var fade = 1.0
        run?.gone?.let { gone ->
            fade = 1 - RouteMath.smooth(0.0, 0.6, now - gone)
            if (fade <= 0) run = null
        }
        val r = run
        val head = r?.head(now) ?: 0.0
        val failed = r?.failure != null
        val color = if (failed) Term.red else Term.green

        // 고를 수 있는 다른 나라로 가는 길(아주 옅게)
        if (stage == RouteStage.Idle || stage == RouteStage.Failed) {
            // 임시 서버 나라까지 그으면 지도가 실선 뭉치가 된다 — 늘 있는 서버로 가는 길만
            for (region in VpnRegion.fixed) {
                if (region == destination) continue
                val other = arcs.getValue(region)
                if (other.local) continue
                val path = Path()
                for (i in 0..48) {
                    val p = view.point(other.point(i / 48.0))
                    if (i == 0) path.moveTo(p.x, p.y) else path.lineTo(p.x, p.y)
                }
                drawPath(path, Term.muted.copy(alpha = 0.18f),
                    style = Stroke(1 * density, pathEffect = PathEffect.dashPathEffect(floatArrayOf(1 * density, 5 * density))))
            }
        }

        // 갈 길(점선)
        if (r?.finish == null || fade < 1) {
            val alpha = if (r == null) 0.55f else 0.5f * fade.toFloat()
            drawPath(line(if (r == null) 0.0 else head, 1.0), Term.muted.copy(alpha = alpha),
                style = Stroke(1 * density, pathEffect = PathEffect.dashPathEffect(floatArrayOf(3 * density, 4 * density))))
        }

        if (r != null && head > 0.001) {
            // 지나온 길: 옅은 번짐 + 실선
            val path = line(0.0, head)
            drawPath(path, color.copy(alpha = 0.18f * fade.toFloat()), style = Stroke(5 * density))
            drawPath(path, color.copy(alpha = fade.toFloat()), style = Stroke(1.5f * density, cap = StrokeCap.Round))
            // 웨이포인트: 머리가 닿으면 작게 튀어나오며 찍힌다
            r.stops.forEachIndexed { i, stop ->
                if (i == 0) return@forEachIndexed
                val arrive = stop.time + RouteRun.TRAVEL
                if (stop.f > head + 0.0001 || (now < arrive && r.finish == null)) return@forEachIndexed
                val pop = if (now < arrive) 1.0 else RouteMath.easeOut(min(1.0, (now - arrive) / 0.26))
                val p = at(stop.f)
                val sz = (5 * density * (1 + 0.8 * (1 - pop))).toFloat()
                val alpha = (fade * max(pop, 0.01)).toFloat()
                val rect = Rect(Offset(p.x - sz / 2, p.y - sz / 2), Size(sz, sz))
                drawRect(Term.bg.copy(alpha = alpha), rect.topLeft, rect.size)
                drawRect((if (failed && i == r.stops.size - 1) Term.red else Term.green).copy(alpha = alpha),
                    rect.topLeft, rect.size, style = Stroke(1.2f * density))
                // 서울 고리에선 번호가 좁은 데 몰리니, 연결되고 1.5~2.5초 사이에 번호만 흐려지고 칸은 남는다
                val finish = r.finish
                val numberAlpha = if (local && finish != null) {
                    alpha * (1 - RouteMath.smooth(1.5, 2.5, now - finish.time)).toFloat()
                } else alpha
                // 번호는 경로 바깥쪽(위)에
                val q = at(min(1.0, stop.f + 0.01))
                val tx = q.x - p.x
                val ty = q.y - p.y
                val tl = max(hypot(tx, ty), 0.001f)
                var nx = ty / tl
                var ny = -tx / tl
                if (local) {
                    nx = (p.x - b.x) / orbit
                    ny = (p.y - b.y) / orbit
                } else if (ny > 0) {
                    nx = -nx
                    ny = -ny
                }
                if (numberAlpha > 0.01f) {
                    label(tm, "%02d".format(i), Offset(p.x + nx * 11 * density, p.y + ny * 11 * density), Anchor.Center,
                        9.sp, FontWeight.Normal, Term.muted.copy(alpha = numberAlpha))
                }
            }
        }

        // 다 그은 경로 위로 실제 주고받는 만큼 점이 흐른다(끊기면 서서히 사라지고, 경로가 지워질 땐 같이 흐려진다)
        if (r != null && r.finish != null && head > 0.98 && down.amount + up.amount > 0) {
            drawFlow(this, ::at, fade)
        }

        drawNodes(this, tm, view, destination)
        drawYou(this, tm, view)

        // 연결되면 목적지에서 신호가 퍼진다(10초쯤 뒤엔 멈춘 고리 하나)
        if (stage == RouteStage.Connected) {
            val since = now - stageAt - 0.8
            if (since >= 0) {
                if (since > 8) {
                    drawCircle(Term.green.copy(alpha = 0.35f), 14 * density, b, style = Stroke(1 * density))
                } else {
                    for (offset in listOf(0.0, 1.2)) {
                        val p = ((since + offset) % 2.4) / 2.4
                        drawCircle(Term.green.copy(alpha = ((1 - p) * 0.55).toFloat()), ((6 + 24 * p) * density).toFloat(), b,
                            style = Stroke(1 * density))
                    }
                }
            }
        }
        drawNode(this, tm, view, destination, on = true)

        // 머리: 머리줄의 커서와 같은 블록 커서
        if (r != null && r.finish == null && fade > 0) {
            val p = at(head)
            val phase = (now - r.stops[0].time) % 1.1
            val blink = if (failed) 1.0 else 0.5 + 0.5 * cos(PI * phase / 0.55)
            drawRect(color.copy(alpha = (blink * fade).toFloat()), Offset(p.x - 3 * density, p.y - 5.5f * density),
                Size(6 * density, 11 * density))
        }
    }

    /** 받는 건 목적지 → you(초록), 보내는 건 you → 목적지(하늘색). 속도가 빠를수록 점이 많고 빠르다(로그 눈금). */
    private fun drawFlow(s: DrawScope, at: (Double) -> Offset, fade: Double) = with(s) {
        for ((lane, color, toward, dotDp) in listOf(
            Lane(down, Term.green, false, 3.2f),
            Lane(up, Term.key, true, 2.4f),
        )) {
            if (lane.amount <= 0) continue
            val count = lane.shown
            val size = dotDp * density
            for ((i, offset) in FlowLane.offsets.withIndex()) {
                // 마지막 하나는 늘고 주는 만큼만 보여서 개수가 바뀔 때도 툭 생기거나 사라지지 않는다
                val weight = minOf(1.0, count - i)
                if (weight <= 0) break
                var f = (lane.phase + offset) % 1.0
                if (!toward) f = 1 - f
                val alpha = (0.25 + 0.75 * sin(PI * f)) * lane.amount * weight * fade   // 양 끝에선 흐려진다
                if (alpha <= 0.01) continue
                val p = at(f)
                drawRect(color.copy(alpha = alpha.toFloat()), Offset(p.x - size / 2, p.y - size / 2), Size(size, size))
            }
        }
    }

    private data class Lane(val lane: FlowLane, val color: Color, val toward: Boolean, val size: Float)

    private fun drawNodes(s: DrawScope, tm: TextMeasurer, view: View, highlighted: VpnRegion?) {
        for (region in VpnRegion.entries) {
            if (region == highlighted || origin.km(region.geo) <= 150) continue
            drawNode(s, tm, view, region, on = false)
        }
    }

    private fun drawNode(s: DrawScope, tm: TextMeasurer, view: View, region: VpnRegion, on: Boolean) = with(s) {
        val geo = region.geo
        val base = RouteMath.unwrap(geo.lon, view.cam.x)
        for (offset in listOf(-360.0, 0.0, 360.0)) {
            val x = view.sx(base + offset)
            val y = view.sy(RouteMath.mercY(geo.lat))
            if (x < -40 * density || x > size.width + 40 * density || y < -20 * density || y > size.height + 20 * density) continue
            // 목적지가 아닌 나라는 머리줄·아래 패널 밑에선 땅 점처럼 흐려진다. 안 그러면 땅은 흐려졌는데
            // 북쪽에 있는 uk만 머리줄 옆에 또렷하게 떠 있다(넓게 볼 때). 거의 안 보이면 누를 수도 없다
            val shown = if (on) 1.0 else edgeVisibility(y.toDouble())
            if (shown <= 0.02) continue
            if (shown > 0.5) hits += region to Offset(x, y)
            // 고르지 않은 나라는 이름 없이 점만: 늘 있는 서버는 빈 칸, 임시 서버 나라는 더 작은 칸.
            // 이름은 아래 카드·칸에 있고, 지도의 점은 눌러서 고를 수 있다
            if (!on) {
                val half = (if (region.onDemand) 2.5f else 3.5f) * density
                val a = shown.toFloat()
                drawRect(Term.bg.copy(alpha = a), Offset(x - half, y - half), Size(half * 2, half * 2))
                drawRect(Term.muted.copy(alpha = a * (if (region.onDemand) 0.7f else 1f)),
                    Offset(x - half, y - half), Size(half * 2, half * 2),
                    style = Stroke((if (region.onDemand) 1f else 1.2f) * density))
                continue
            }
            val half = 3.5f * density
            drawRect(Term.green, Offset(x - half, y - half), Size(half * 2, half * 2))
            val text = if (stage == RouteStage.Connected) "${region.name} · ${geo.city}" else region.name
            // 목적지 나라는 땅 점이 초록으로 켜져서 초록 글자가 묻힌다 → 배경색 판 + 초록 테두리(꼬리표)
            if (arc.local) {
                // 서울에서 kr: you와 서버가 같은 점이라 이름표를 하나로 합쳐 고리 아래 가운데에
                label(tm, "you ⇄ $text", Offset(x, y + ((ORBIT + 24) * density).toFloat()), Anchor.Center, 10.sp,
                    FontWeight.SemiBold, Term.green, backed = true, outline = Term.green.copy(alpha = 0.45f))
            } else {
                // 연결되면 고리(반지름 14) 밖에서 시작한다 — 안에서 시작하면 고리가 글자를 긋는다
                label(tm, text, Offset(x + 22 * density, y), Anchor.Leading, 10.sp, FontWeight.SemiBold, Term.green,
                    backed = true, outline = Term.green.copy(alpha = 0.45f))
            }
        }
    }

    /** 0(머리줄·아래 패널 밑) ~ 1(보이는 지도). 위는 머리줄 아래 끝부터, 아래는 도시 → 도시 줄 언저리부터 흐린다 */
    private fun edgeVisibility(y: Double): Double {
        val t = RouteMath.smooth(top - 12 * d, top + 14 * d, y)
        val b = 1 - RouteMath.smooth(h - bottom - 30 * d, h - bottom - 6 * d, y)
        return min(t, b)
    }

    private fun drawYou(s: DrawScope, tm: TextMeasurer, view: View) = with(s) {
        val p = view.point(origin.world)
        // you 바로 밑에 가려진 나라(서울에서 kr)는 you를 눌러 고른다
        for (region in VpnRegion.entries) if (origin.km(region.geo) <= 150) hits += region to p
        drawCircle(Term.text, 3.2f * density, p)
        drawCircle(Term.text.copy(alpha = 0.35f), 6.5f * density, p, style = Stroke(1 * density))
        when {
            // 서울에서 kr: you는 고리 아래 목적지 꼬리표(you ⇄ kr · seoul)에 같이 쓴다
            arc.local -> Unit
            // 화면 왼쪽 끝이면 왼쪽에 쓰면 잘린다 → 점 아래에
            p.x < 44 * density -> label(tm, "you", Offset(max(p.x, 18 * density), p.y + 16 * density), Anchor.Center,
                10.sp, FontWeight.Normal, Term.text, backed = true)
            else -> label(tm, "you", Offset(p.x - 12 * density, p.y), Anchor.Trailing, 10.sp, FontWeight.Normal, Term.text,
                backed = true)
        }
    }

    /** 레이더가 켜질 때 0.35초, 꺼질 때 0.6초에 걸쳐 서서히 */
    private fun radarAlpha(now: Double): Double {
        val fadeIn = RouteMath.smooth(0.0, 0.35, now - scanAt)
        val fadeOut = scanEndAt?.let { 1 - RouteMath.smooth(0.0, 0.6, now - it) } ?: 1.0
        return fadeIn * fadeOut
    }

    /** you 둘레를 도는 레이더: 테두리 원 + 퍼지는 고리 둘 + 꼬리가 옅어지는 부채꼴 */
    private fun drawRadar(s: DrawScope, view: View, now: Double, alpha: Double) = with(s) {
        val p = view.point(origin.world)
        val since = now - scanAt
        val reach = min(110 * density, max(60 * density, size.width * 0.22f))
        val a = alpha.toFloat()
        drawCircle(Term.green.copy(alpha = 0.035f * a), reach, p)
        drawCircle(Term.green.copy(alpha = 0.18f * a), reach, p, style = Stroke(1 * density))
        for (k in 0 until 2) {
            val u = (since / 2.2 + k / 2.0) % 1.0
            val e = RouteMath.easeOut(u)
            drawCircle(Term.green.copy(alpha = (0.4 * (1 - u)).toFloat() * a), (6 * density + (reach - 6 * density) * e).toFloat(), p,
                style = Stroke(1 * density))
        }
        // 한 바퀴 2.6초, 꼬리 66°
        val angle = since * 2 * PI / 2.6
        val trail = 1.15
        val span = (trail / (2 * PI)).toFloat()
        val green = Term.green
        rotate(Math.toDegrees(angle - trail).toFloat(), p) {
            drawCircle(
                Brush.sweepGradient(
                    0f to green.copy(alpha = 0f),
                    span to green.copy(alpha = 0.32f * a),
                    min(span + 0.003f, 1f) to green.copy(alpha = 0f),
                    1f to green.copy(alpha = 0f),
                    center = p,
                ),
                reach, p,
            )
        }
        val tip = Offset(p.x + reach * cos(angle).toFloat(), p.y + reach * sin(angle).toFloat())
        drawLine(green.copy(alpha = 0.8f * a), p, tip, 1.2f * density, cap = StrokeCap.Round)
        drawCircle(green.copy(alpha = a), 2 * density, tip)
    }

    /** 오른쪽 위: 카메라 중심 좌표 · 아래: 도시 → 도시와 거리 */
    private fun drawHud(s: DrawScope, tm: TextMeasurer, view: View) = with(s) {
        val side = 16 * density
        val topY = (top + 6 * density).toFloat()
        val bottomY = (h - bottom - 18 * density).toFloat()
        val lat = RouteMath.lat(view.cam.y - (top - bottom) / 2 / view.k)
        val lon = RouteMath.normalized(view.cam.x)
        val coords = "%.2f°%s %.2f°%s".format(abs(lat), if (lat >= 0) "N" else "S", abs(lon), if (lon >= 0) "E" else "W")
        label(tm, coords, Offset(size.width - side, topY), Anchor.Trailing, 10.sp, FontWeight.Normal, Term.muted, backed = true)
        val to = destination.geo
        val distance = if (arc.local) "local" else "${RouteMath.grouped(origin.km(to).toInt())} km"
        val route = if (stage == RouteStage.Connected) "${origin.city} ══ ${to.city}" else "${origin.city} → ${to.city}"
        label(tm, distance, Offset(size.width - side, bottomY), Anchor.Trailing, 10.sp, FontWeight.Normal, Term.muted, backed = true)
        label(tm, route, Offset(side, bottomY), Anchor.Leading, 10.sp, FontWeight.Normal,
            if (stage == RouteStage.Connected) Term.green else Term.muted, backed = true)
    }

    private enum class Anchor { Leading, Trailing, Center }

    /**
     * [backed]: 글자 뒤에 배경색 판을 옅게 깐다(밑에 깔린 나라 점에 글자가 묻히지 않게).
     * [outline]: 판을 더 진하게 하고 테두리를 둘러 꼬리표처럼(목적지 — 켜진 초록 땅 점 위)
     */
    private fun DrawScope.label(tm: TextMeasurer, text: String, at: Offset, anchor: Anchor, size: TextUnit,
                                weight: FontWeight, color: Color, backed: Boolean = false, outline: Color? = null) {
        val layout = tm.measure(text, Term.mono(size, weight, color))
        val width = layout.size.width
        val left = when (anchor) {
            Anchor.Leading -> at.x
            Anchor.Trailing -> at.x - width
            Anchor.Center -> at.x - width / 2f
        }
        val top = at.y - layout.size.height / 2f
        if (backed) {
            val padX = (if (outline == null) 4 else 6) * density
            val padY = (if (outline == null) 2f else 3.5f) * density
            val corner = androidx.compose.ui.geometry.CornerRadius((if (outline == null) 3 else 4) * density)
            val plateAt = Offset(left - padX, top - padY)
            val plate = Size(width + padX * 2, layout.size.height + padY * 2)
            drawRoundRect(Term.bg.copy(alpha = if (outline == null) 0.75f else 0.9f), plateAt, plate, corner)
            outline?.let { drawRoundRect(it, plateAt, plate, corner, style = Stroke(1 * density)) }
        }
        drawText(layout, topLeft = Offset(left, top))
    }
}
