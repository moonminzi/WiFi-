package com.nago.vpn

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

// vpn 탭 콘솔(지도 위로 올라오는 판)의 부품들. iOS Console.swift와 같은 모양.

/** 숫자가 바뀌면 그 글자만 위아래로 굴러 바뀐다(SwiftUI의 numericText처럼). 글꼴이 고정폭이라 자리가 흔들리지 않는다. */
@Composable
fun RollingText(text: String, style: TextStyle, modifier: Modifier = Modifier) {
    Row(modifier) {
        text.forEachIndexed { i, c ->
            // 뒤에서부터 센 자리로 묶어야 자릿수가 늘어도 1의 자리끼리 굴러간다
            androidx.compose.runtime.key(text.length - i) {
                AnimatedContent(
                    targetState = c,
                    transitionSpec = {
                        val up = initialState < targetState
                        (slideInVertically(tween(260)) { if (up) it else -it } + fadeIn(tween(260)))
                            .togetherWith(slideOutVertically(tween(260)) { if (up) -it else it } + fadeOut(tween(200)))
                    },
                    label = "digit",
                ) { Text(it.toString(), style = style) }
            }
        }
    }
}

/** 1:02:03 / 12:34 */
fun clock(seconds: Long): String {
    val s = maxOf(0L, seconds)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s % 3600 / 60, s % 60) else "%02d:%02d".format(s / 60, s % 60)
}

/** 연결된 뒤 지난 시간. 연결된 시각에 맞춰 초마다 바뀐다. */
@Composable
fun SessionClock(since: Long) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(since) {
        while (true) {
            now = System.currentTimeMillis()
            delay(1000 - (now - since).mod(1000L))
        }
    }
    RollingText(clock((now - since) / 1000), Term.mono(22.sp, FontWeight.SemiBold, Term.num))
}

/** 연결 단계 막대: api → boot → tunnel → up. 지금 단계는 노랗게 숨 쉰다. */
@Composable
fun PhasePipeline(index: Int) {
    val labels = listOf("api", "boot", "tunnel", "up")
    val breathe = pulse(1100)
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        labels.forEachIndexed { i, label ->
            val fill by animateColorAsState(
                when {
                    i < index -> Term.green
                    i == index -> Term.amber
                    else -> Term.track
                },
                tween(300), label = "phase-fill",
            )
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(3.dp)
                        .alpha(if (i == index) 1f - 0.65f * breathe else 1f)
                        .background(fill, RoundedCornerShape(50)),
                )
                Text(
                    label,
                    style = Term.mono(
                        10.sp, if (i == index) FontWeight.SemiBold else FontWeight.Normal,
                        when {
                            i == index -> Term.amber
                            i < index -> Term.green
                            else -> Term.muted
                        },
                    ),
                )
            }
        }
    }
}

/** 빛이 광섬유로 1ms에 200km쯤 가니 왕복은 km/100ms. 장비·우회 몫으로 조금 더한다(어림값). */
fun estimatedRtt(region: VpnRegion): Int = Math.round(Geo.here.km(region.geo) / 100 * 1.3 + 6).toInt()

/** 나갈 국가 카드 한 장: 깃발, 코드, 도시, 왕복 시간(잰 값이 없으면 ~어림값) */
@Composable
fun RegionCard(
    region: VpnRegion, selected: Boolean, live: Boolean, measured: Int?, fastest: Boolean,
    enabled: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(8.dp)
    val border by animateColorAsState(if (selected) Term.green else Term.border, tween(200), label = "card-border")
    val fill by animateColorAsState(if (selected) Term.green.copy(alpha = 0.08f) else Term.surface, tween(200), label = "card-fill")
    val rttColor = when {
        measured == null -> if (selected) Term.key else Term.muted
        measured < 80 -> Term.green
        measured < 180 -> Term.amber
        else -> Term.red
    }
    Column(
        verticalArrangement = Arrangement.spacedBy(3.dp),
        modifier = modifier
            .background(fill, shape)
            .border(if (selected) 1.5.dp else 1.dp, border, shape)
            .pressable(enabled, onClick)
            .padding(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(region.flag, style = TextStyle(fontSize = 18.sp))
            Spacer(Modifier.weight(1f))
            if (live) {
                Box(
                    Modifier
                        .size(6.dp)
                        .shadow(4.dp, CircleShape, ambientColor = Term.green, spotColor = Term.green)
                        .background(Term.green, CircleShape),
                )
            } else if (fastest) {
                Text(
                    "fast",
                    style = Term.mono(8.5.sp, FontWeight.SemiBold, Term.green),
                    modifier = Modifier
                        .border(1.dp, Term.green.copy(alpha = 0.6f), RoundedCornerShape(3.dp))
                        .padding(horizontal = 4.dp, vertical = 1.dp),
                )
            }
        }
        Text(region.name, style = Term.mono(16.sp, FontWeight.Bold, if (selected) Term.green else Term.num))
        Text(region.geo.city, style = Term.mono(10.sp, color = Term.muted), maxLines = 1, overflow = TextOverflow.Ellipsis)
        RollingText(
            measured?.let { "${it}ms" } ?: "~${estimatedRtt(region)}ms",
            Term.mono(10.sp, if (measured == null) FontWeight.Normal else FontWeight.SemiBold, rttColor),
        )
    }
}

/** `wg/neptun · adblock` 같은 지금 설정을 작은 꼬리표로 */
@Composable
fun FlagRow(flags: List<String>) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.horizontalScroll(rememberScrollState())) {
        flags.forEach { flag ->
            Text(
                flag,
                style = Term.mono(11.sp, color = Term.muted),
                modifier = Modifier
                    .border(1.dp, Term.border, RoundedCornerShape(4.dp))
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }
    }
}

/** 지금 속도(↓ 받은 쪽 · ↑ 보낸 쪽), 누적, 마지막 핸드셰이크, 1분 그래프 */
@Composable
fun TrafficPanel(meter: TrafficMeter, handshakeAgo: Long?) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Speed("↓", meter.current?.down ?: 0.0, Term.green)
            Speed("↑", meter.current?.up ?: 0.0, Term.key)
            Spacer(Modifier.weight(1f))
            Column(horizontalAlignment = Alignment.End) {
                Text(
                    "${TrafficMeter.bytes(meter.totalDown)} ↓ · ${TrafficMeter.bytes(meter.totalUp)} ↑",
                    style = Term.mono(10.5.sp, color = Term.muted), maxLines = 1,
                )
                Text(
                    handshakeAgo?.let { "handshake ${clock(it)} ago" } ?: "no handshake yet",
                    style = Term.mono(10.5.sp, color = if (handshakeAgo == null || handshakeAgo > 180) Term.amber else Term.muted),
                    maxLines = 1,
                )
            }
        }
        Sparkline(meter.history, Modifier.fillMaxWidth().height(34.dp))
    }
}

@Composable
private fun Speed(arrow: String, value: Double, color: Color) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(arrow, style = Term.mono(15.sp, FontWeight.SemiBold, color))
        RollingText(TrafficMeter.speed(value), Term.mono(15.sp, FontWeight.SemiBold, Term.num))
    }
}

/** 받은 양(초록 면)과 보낸 양(하늘색 선). 오른쪽 끝이 지금이다. */
@Composable
fun Sparkline(history: List<TrafficMeter.Rate>, modifier: Modifier) {
    val green = Term.green
    val key = Term.key
    val border = Term.border
    Canvas(modifier) {
        val n = TrafficMeter.WINDOW
        val peak = maxOf(history.maxOfOrNull { maxOf(it.down, it.up) } ?: 0.0, 50_000.0)
        val step = size.width / (n - 1)
        val offset = n - history.size
        fun point(i: Int, v: Double) = Offset((i + offset) * step, size.height - (v / peak).toFloat() * (size.height - 2) - 1)
        drawLine(border, Offset(0f, size.height - 0.5f), Offset(size.width, size.height - 0.5f), 1.dp.toPx())
        if (history.size < 2) return@Canvas
        val down = Path()
        val area = Path()
        history.forEachIndexed { i, rate ->
            val p = point(i, rate.down)
            if (i == 0) {
                down.moveTo(p.x, p.y)
                area.moveTo(p.x, size.height)
            }
            down.lineTo(p.x, p.y)
            area.lineTo(p.x, p.y)
        }
        area.lineTo(point(history.size - 1, 0.0).x, size.height)
        area.close()
        drawPath(area, Brush.verticalGradient(listOf(green.copy(alpha = 0.35f), green.copy(alpha = 0.02f))))
        drawPath(down, green, style = Stroke(1.3.dp.toPx(), join = StrokeJoin.Round))
        val up = Path()
        history.forEachIndexed { i, rate ->
            val p = point(i, rate.up)
            if (i == 0) up.moveTo(p.x, p.y) else up.lineTo(p.x, p.y)
        }
        drawPath(up, key.copy(alpha = 0.8f), style = Stroke(1.dp.toPx(), join = StrokeJoin.Round))
        drawCircle(green, 2.5.dp.toPx(), point(history.size - 1, history.last().down))
    }
}

/** `+  3.2s ✓ jp: up` 진행 기록 한 줄 */
@Composable
fun LogLine(offsetSeconds: Double?, symbol: String, symbolColor: Color, text: String, color: Color) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
        Text(offsetSeconds?.let { "+%5.1fs".format(maxOf(0.0, it)) } ?: "       ", style = Term.mono(12.sp, color = Term.muted))
        Text(symbol, style = Term.mono(12.sp, color = symbolColor))
        Text(text, style = Term.mono(12.sp, color = color), maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

/** 연결 중 버튼 위를 훑고 지나가는 빛 */
@Composable
fun Modifier.sweep(active: Boolean, tint: Color): Modifier {
    if (!active) return this
    val transition = rememberInfiniteTransition(label = "sweep")
    val x by transition.animateFloat(
        -0.4f, 1.4f, infiniteRepeatable(tween(1600, easing = LinearEasing), RepeatMode.Restart), label = "sweep-x",
    )
    return drawWithContent {
        drawContent()
        val band = size.width * 0.35f
        val center = size.width * x
        drawRoundRect(
            Brush.horizontalGradient(
                listOf(Color.Transparent, tint.copy(alpha = 0.18f), Color.Transparent),
                startX = center - band / 2, endX = center + band / 2,
            ),
            cornerRadius = CornerRadius(6.dp.toPx()),
        )
    }
}

/** 지도 위로 겹쳐 올라오는 판: 위쪽만 둥글고, 위로 그림자가 지고, 손잡이가 달렸다. */
@Composable
fun Modifier.consoleSheet(): Modifier {
    val bg = Term.bg
    val border = Term.border
    val shadow = Term.shadow
    return drawBehind {
        val r = 18.dp.toPx()
        val fade = 18.dp.toPx()
        drawRect(Brush.verticalGradient(listOf(Color.Transparent, shadow), startY = -fade, endY = r), Offset(0f, -fade),
            Size(size.width, fade + r))
        val edge = Path().apply {
            moveTo(0f, size.height)
            lineTo(0f, r)
            arcTo(Rect(0f, 0f, 2 * r, 2 * r), 180f, 90f, false)
            lineTo(size.width - r, 0f)
            arcTo(Rect(size.width - 2 * r, 0f, size.width, 2 * r), 270f, 90f, false)
            lineTo(size.width, size.height)
        }
        val fill = Path().apply {
            addPath(edge)
            close()
        }
        drawPath(fill, bg)
        drawPath(edge, border, style = Stroke(1.dp.toPx()))
        val handle = Size(36.dp.toPx(), 4.dp.toPx())
        drawRoundRect(border, Offset((size.width - handle.width) / 2, 7.dp.toPx()), handle, CornerRadius(handle.height / 2))
    }
}
