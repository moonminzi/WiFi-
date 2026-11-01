package com.nago.vpn

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import android.view.HapticFeedbackConstants
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// vpn 탭의 접는 패널과 임시 서버 나라 칸(iOS Console.swift · SpeedPanel.swift와 같은 모양)

/** 잰 값은 빠를수록 초록 → 노랑 → 빨강 */
fun rttTint(ms: Int): Color = when {
    ms < 80 -> Term.green
    ms < 180 -> Term.amber
    else -> Term.red
}

/** 테두리 상자 안의 접는 패널(머리줄을 누르면 접고 편다) */
@Composable
fun FoldBox(folded: Boolean, content: @Composable () -> Unit) {
    Column(
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier
            .fillMaxWidth()
            .background(Term.surface, RoundedCornerShape(8.dp))
            .border(1.dp, Term.border, RoundedCornerShape(8.dp))
            .padding(if (folded) 10.dp else 12.dp),
    ) { content() }
}

// MARK: - 임시 서버 나라

/**
 * 임시 서버 나라 한 칸: 작은 깃발 · 코드 · 왕복 시간 막대. 숫자는 칸에 두지 않고, 누르고 있으면 칸 위에 말풍선으로 뜬다.
 * 키보드 글쇠처럼: 누르고 있으면 말풍선, 떼면 고른다(밀어서 벗어나면 취소). 짧게 탭할 때 번쩍이지 않게 0.15초 넘게 누를 때만.
 */
@Composable
fun RegionChip(
    region: VpnRegion, selected: Boolean, live: Boolean, measured: Int?, enabled: Boolean,
    modifier: Modifier = Modifier, onClick: () -> Unit,
) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    var peeking by remember { mutableStateOf(false) }
    val view = LocalView.current
    LaunchedEffect(pressed) {
        if (!pressed) {
            peeking = false
            return@LaunchedEffect
        }
        delay(150)
        peeking = true
        view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
    }
    val scale by animateFloatAsState(if (pressed) 0.95f else 1f, spring(dampingRatio = 0.6f, stiffness = 900f), label = "chip")
    val border by animateColorAsState(if (selected) Term.green else Term.border, tween(200), label = "chip-border")
    val shape = RoundedCornerShape(6.dp)
    Box(modifier.zIndex(if (peeking || Demo.peek == region) 1f else 0f)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
            modifier = Modifier
                .fillMaxWidth()
                .graphicsLayer { scaleX = scale; scaleY = scale }
                .background(if (selected) Term.green.copy(alpha = 0.08f) else Term.surface, shape)
                .border(if (selected) 1.5.dp else 1.dp, border, shape)
                .clickable(source, indication = null, enabled = enabled, onClick = onClick)
                .padding(horizontal = 7.dp, vertical = 6.dp),
        ) {
            DotFlag(region, 18.dp)
            Text(region.name, style = Term.mono(12.sp, FontWeight.Bold, if (selected) Term.green else Term.num))
            Spacer(Modifier.weight(1f))
            if (live) {
                Box(Modifier.size(5.dp).shadow(3.dp, CircleShape, ambientColor = Term.green, spotColor = Term.green)
                    .background(Term.green, CircleShape))
            } else {
                RttPips(measured ?: estimatedRtt(region), measured != null)
            }
        }
        // 칸 위 끝 가운데에 크기 0인 자리를 두고 말풍선 아래 끝을 거기 맞춘다 → 말풍선이 칸 위로 솟는다(손가락에 가리지 않게)
        Box(
            Modifier
                .align(Alignment.TopCenter)
                .layout { measurable, _ ->
                    val p = measurable.measure(Constraints())
                    layout(0, 0) { p.place(-p.width / 2, -p.height - 6.dp.roundToPx()) }
                },
        ) {
            AnimatedVisibility(
                peeking || Demo.peek == region,
                enter = scaleIn(spring(dampingRatio = 0.7f, stiffness = 700f), 0.6f, TransformOrigin(0.5f, 1f)) + fadeIn(),
                exit = scaleOut(tween(120), 0.6f, TransformOrigin(0.5f, 1f)) + fadeOut(tween(120)),
            ) { RegionPeek(region, live, measured) }
        }
    }
}

/** 왕복 시간 막대 3칸(신호 세기처럼 많을수록 빠름): 80ms 미만 3 · 180ms 미만 2 · 그 위 1. 어림값은 회색 */
@Composable
fun RttPips(ms: Int, measured: Boolean) {
    val lit = if (ms < 80) 3 else if (ms < 180) 2 else 1
    val tint = if (measured) rttTint(ms) else Term.muted
    Row(horizontalArrangement = Arrangement.spacedBy(1.5.dp), verticalAlignment = Alignment.Bottom) {
        for (bar in 0 until 3) {
            Box(
                Modifier
                    .size(2.5.dp, (4 + bar * 2.5f).dp)
                    .background(if (bar < lit) tint else Term.track, RoundedCornerShape(0.75.dp)),
            )
        }
    }
}

/** 임시 나라 칸을 누르고 있으면 칸 위에 뜨는 말풍선: 도시 · 왕복 시간 */
@Composable
fun RegionPeek(region: VpnRegion, live: Boolean, measured: Int?) {
    val shape = RoundedCornerShape(8.dp)
    Column(
        verticalArrangement = Arrangement.spacedBy(1.dp),
        modifier = Modifier
            .shadow(8.dp, shape, ambientColor = Color.Black.copy(alpha = 0.3f), spotColor = Color.Black.copy(alpha = 0.3f))
            .background(Term.chrome, shape)
            .border(1.dp, Term.border, shape)
            .padding(horizontal = 10.dp, vertical = 6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            if (live) Box(Modifier.size(5.dp).background(Term.green, CircleShape))
            Text(region.city, style = Term.mono(10.sp, color = Term.muted), maxLines = 1)
        }
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(measured?.toString() ?: "~${estimatedRtt(region)}",
                style = Term.mono(17.sp, FontWeight.Bold, measured?.let(::rttTint) ?: Term.num))
            Text(if (measured == null) "ms est." else "ms", style = Term.mono(10.sp, color = Term.muted),
                modifier = Modifier.padding(bottom = 2.dp))
        }
    }
}

/** 칸을 최소 [min] 너비로 한 줄에 들어가는 만큼 나눠 담는다(SwiftUI adaptive 격자처럼) */
@Composable
fun <T> AdaptiveGrid(items: List<T>, min: androidx.compose.ui.unit.Dp, spacing: androidx.compose.ui.unit.Dp,
                     cell: @Composable (T, Modifier) -> Unit) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val columns = maxOf(1, ((maxWidth + spacing) / (min + spacing)).toInt())
        Column(verticalArrangement = Arrangement.spacedBy(spacing)) {
            items.chunked(columns).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(spacing)) {
                    row.forEach { cell(it, Modifier.weight(1f)) }
                    repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

// MARK: - net scan

/** 네트워크 검사 결과: 등급 + 한 줄 판정 + 검사마다 한 줄. 접으면 머리줄(등급·한마디)만 */
@Composable
fun ScanPanel(scan: NetScan, vpnOn: Boolean, folded: Boolean, hideIP: Boolean, onFold: () -> Unit, rescan: () -> Unit) {
    val gradeColor = when {
        scan.running -> Term.amber
        scan.grade == "A" || scan.grade == "B" -> Term.green
        scan.grade == "C" -> Term.amber
        else -> Term.red
    }
    val verdict = when {
        scan.running -> "probing this network"
        scan.grade == "A" -> "clean network"
        scan.grade == "B" -> "mostly fine"
        scan.grade == "C" -> "risky network"
        else -> "hostile network"
    }
    FoldBox(folded) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.fillMaxWidth().clickable(remember { MutableInteractionSource() }, null, onClick = onFold),
        ) {
            FoldChevron(folded)
            Text("// net scan", style = Term.mono(11.sp, color = Term.muted))
            if (folded && !scan.running) {
                Text(scan.grade, style = Term.mono(11.sp, FontWeight.Bold, gradeColor))
                Text(verdict, style = Term.mono(11.sp, color = gradeColor), maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false))
            }
            Spacer(Modifier.weight(1f))
            if (scan.running) {
                Text("scanning ${scan.current ?: ""}…", style = Term.mono(11.sp, color = Term.amber), maxLines = 1)
            } else if (!folded) {
                scan.finishedAt?.let { Ago(it) }
            }
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.size(26.dp, 22.dp)
                    .clickable(remember { MutableInteractionSource() }, null, enabled = !scan.running, onClick = rescan),
            ) { TermIcon(Glyph.Refresh, 13.dp, if (scan.running) Term.muted else Term.text) }
        }
        AnimatedVisibility(!folded, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                        modifier = Modifier
                            .size(54.dp)
                            .background(gradeColor.copy(alpha = 0.08f), RoundedCornerShape(10.dp))
                            .border(1.2.dp, gradeColor.copy(alpha = 0.6f), RoundedCornerShape(10.dp)),
                    ) {
                        Text(if (scan.running) "…" else scan.grade, style = Term.mono(28.sp, FontWeight.Bold, gradeColor))
                        Text(if (scan.running) "--" else "${scan.score}", style = Term.mono(9.5.sp, color = Term.muted))
                    }
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(verdict, style = Term.mono(14.sp, FontWeight.SemiBold, if (scan.running) Term.text else gradeColor))
                        Text(
                            when {
                                scan.running -> "dns · tls · portal · ipv6 · exit · quality"
                                vpnOn -> "checked through the tunnel"
                                scan.hasProblems -> "connect to route around it"
                                else -> "nothing odd · the router still sees where you go"
                            },
                            style = Term.mono(11.sp, color = Term.muted),
                        )
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    scan.checks.forEach { check ->
                        val (symbol, color) = when (check.level) {
                            NetScan.Level.Pass -> "✓" to Term.green
                            NetScan.Level.Info -> "·" to Term.muted
                            NetScan.Level.Warn -> "!" to Term.amber
                            NetScan.Level.Fail -> "✗" to Term.red
                        }
                        val bad = check.level == NetScan.Level.Warn || check.level == NetScan.Level.Fail
                        ScanRow(symbol, color, check.id,
                            if (hideIP && check.id == "exit") ExitInfo.maskIPs(check.detail) else check.detail,
                            if (bad) color else Term.text)
                    }
                    if (scan.running) {
                        NetScan.order.filter { id -> scan.checks.none { it.id == id } }.forEach { id ->
                            val now = id == scan.current
                            ScanRow(if (now) ">" else "·", if (now) Term.amber else Term.muted, id, if (now) "…" else "", Term.muted)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ScanRow(symbol: String, symbolColor: Color, id: String, detail: String, detailColor: Color) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
        Text(symbol, style = Term.mono(11.5.sp, color = symbolColor), modifier = Modifier.width(10.dp))
        Text(id, style = Term.mono(11.5.sp, color = Term.key), modifier = Modifier.width(66.dp))
        Text(detail, style = Term.mono(11.5.sp, color = detailColor), maxLines = 2)
    }
}

/** `12s ago` — 초마다 바뀐다 */
@Composable
private fun Ago(at: Long) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(at) {
        while (true) {
            now = System.currentTimeMillis()
            delay(1_000)
        }
    }
    val s = maxOf(0L, (now - at) / 1000)
    val text = when {
        s < 60 -> "$s sec"
        s < 3600 -> "${s / 60} min"
        else -> "${s / 3600} hr"
    }
    Text("$text ago", style = Term.mono(11.sp, color = Term.muted), maxLines = 1)
}

// MARK: - speed test

/**
 * `// speed test`: 받기·올리기 Mbps, 쉬는 동안·받는 동안 핑, 최근 결과(어떤 설정이었는지와 함께).
 * settings에서 loops·engine을 바꿔 가며 같은 나라로 재 보면 어느 쪽이 빠른지 바로 비교된다.
 */
@Composable
fun SpeedPanel(test: SpeedTest, via: String, folded: Boolean, onFold: () -> Unit, run: () -> Unit) {
    fun arrow(phase: SpeedTest.Phase) = when (phase) {
        SpeedTest.Phase.Upload -> "↑"
        SpeedTest.Phase.Ping -> "·"
        else -> "↓"
    }
    FoldBox(folded) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.fillMaxWidth().clickable(remember { MutableInteractionSource() }, null, onClick = onFold),
        ) {
            FoldChevron(folded)
            Text("// speed test", style = Term.mono(11.sp, color = Term.muted))
            if (folded) {
                val last = test.last
                when {
                    test.running -> Text("${arrow(test.phase)} ${SpeedTest.mbps(test.liveMbps)} Mbps",
                        style = Term.mono(11.sp, color = Term.amber), maxLines = 1)
                    test.phase == SpeedTest.Phase.Failed -> Text("✗ failed", style = Term.mono(11.sp, color = Term.red))
                    last != null -> Text("↓${Math.round(last.downMbps)} ↑${Math.round(last.upMbps)} Mbps",
                        style = Term.mono(11.sp, color = Term.num), maxLines = 1)
                }
            }
            Spacer(Modifier.weight(1f))
            val tint = if (test.running) Term.amber else Term.green
            Text(
                if (test.running) test.phase.name.lowercase() + "…" else "run ▸",
                style = Term.mono(11.sp, color = tint),
                modifier = Modifier
                    .border(1.dp, tint.copy(alpha = if (test.running) 0.5f else 0.6f), RoundedCornerShape(4.dp))
                    .pressable(!test.running, run)
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            )
        }
        AnimatedVisibility(!folded, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                val last = test.last
                if (test.running) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(arrow(test.phase), style = Term.mono(24.sp, FontWeight.Bold,
                                if (test.phase == SpeedTest.Phase.Upload) Term.key else Term.green))
                            RollingText(SpeedTest.mbps(test.liveMbps), Term.mono(24.sp, FontWeight.Bold, Term.num))
                            Text("Mbps", style = Term.mono(11.sp, color = Term.muted), modifier = Modifier.padding(bottom = 4.dp))
                        }
                        Box(Modifier.fillMaxWidth().height(3.dp).background(Term.track, CircleShape)) {
                            Box(Modifier.fillMaxWidth(test.progress.toFloat().coerceIn(0.02f, 1f)).height(3.dp)
                                .background(Term.amber.copy(alpha = 0.8f), CircleShape))
                        }
                        Text(
                            when (test.phase) {
                                SpeedTest.Phase.Ping -> "ping · idle latency"
                                SpeedTest.Phase.Download -> "download · 4 connections · 7s"
                                SpeedTest.Phase.Upload -> "upload · 4 connections · 7s"
                                else -> ""
                            },
                            style = Term.mono(10.5.sp, color = Term.muted),
                        )
                    }
                } else if (last != null) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.Bottom) {
                            Figure("↓", last.downMbps, Term.green)
                            Figure("↑", last.upMbps, Term.key)
                        }
                        Text(pingText(last), style = Term.mono(11.sp, color = Term.muted))
                    }
                }
                if (test.phase == SpeedTest.Phase.Failed) {
                    test.errorText?.let { Text("✗ $it", style = Term.mono(11.5.sp, color = Term.red)) }
                }
                if (test.history.size > 1) {
                    val best = test.history.maxOf { it.downMbps }
                    val clock = remember { SimpleDateFormat("HH:mm", Locale.US) }
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        test.history.forEach { r ->
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                                val style = Term.mono(10.5.sp, color = Term.muted)
                                Text(clock.format(Date(r.at)), style = style)
                                Text(r.via, style = Term.mono(10.5.sp, color = if (r.downMbps == best) Term.green else Term.text),
                                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                                Text("↓${Math.round(r.downMbps)}", style = Term.mono(10.5.sp, color = Term.num))
                                Text("↑${Math.round(r.upMbps)}", style = style)
                                Text(r.loadedMs?.let { "${Math.round(it)}ms" } ?: "--", style = style)
                            }
                        }
                    }
                }
                Text("via $via · speed.cloudflare.com · up to ~${SpeedTest.MAX_USAGE_MB} MB",
                    style = Term.mono(10.sp, color = Term.muted.copy(alpha = 0.8f)), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun Figure(arrow: String, value: Double, color: Color) {
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(arrow, style = Term.mono(20.sp, FontWeight.Bold, color))
        RollingText(SpeedTest.mbps(value), Term.mono(20.sp, FontWeight.Bold, Term.num))
        Text("Mbps", style = Term.mono(10.5.sp, color = Term.muted), modifier = Modifier.padding(bottom = 3.dp))
    }
}

private fun pingText(r: SpeedTest.Result): String {
    val idle = r.idleMs ?: return "ping --"
    var text = "ping ${Math.round(idle)} ms idle"
    r.loadedMs?.let { text += " · ${Math.round(it)} ms loaded (+${Math.round(maxOf(it - idle, 0.0))})" }
    return text
}

/** 실패 이유 한 줄: `✗ 이유  log ›` — 누르면 연결 기록 */
@Composable
fun FailureLine(message: String, onOpen: () -> Unit) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth().clickable(remember { MutableInteractionSource() }, null, onClick = onOpen),
    ) {
        Text("✗", style = Term.mono(12.sp, color = Term.red))
        Text(message, style = Term.mono(12.sp, color = Term.red), maxLines = 2, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f))
        Text("log ›", style = Term.mono(12.sp, color = Term.muted))
    }
}

/** 고른 임시 나라가 있으면 그 나라 왕복 시간을 숫자로(칸에는 막대만 있다), 없으면 누르는 법 */
@Composable
fun OnDemandFootnote(shown: VpnRegion, measured: Int?) {
    val style = Term.mono(10.sp, color = Term.muted.copy(alpha = 0.8f))
    if (!shown.onDemand) {
        Text("hold a chip for rtt · wg only · gone after 30m idle", style = style, maxLines = 1, overflow = TextOverflow.Ellipsis)
        return
    }
    Text(
        buildAnnotatedString {
            withStyle(SpanStyle(color = Term.text)) { append("› ${shown.name} ${shown.city} ") }
            withStyle(SpanStyle(color = measured?.let(::rttTint) ?: Term.muted)) {
                append(measured?.let { "${it}ms" } ?: "~${estimatedRtt(shown)}ms")
            }
            append(" · gone after 30m idle")
        },
        style = style, maxLines = 1, overflow = TextOverflow.Ellipsis,
    )
}

/** 접을 수 있는 머리줄 `▸ // on demand +9 · new server ~1m` */
@Composable
fun OnDemandHeader(folded: Boolean, count: Int, trailing: @Composable () -> Unit, onFold: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 22.dp)
            .clickable(remember { MutableInteractionSource() }, null, onClick = onFold),
    ) {
        FoldChevron(folded)
        Text("// on demand", style = Term.mono(11.sp, color = Term.muted))
        Text("+$count · new server ~1m", style = Term.mono(11.sp, color = Term.muted.copy(alpha = 0.7f)), maxLines = 1,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
        Spacer(Modifier.weight(1f))
        trailing()
    }
}

/** 잠긴 동안 흐리게 */
fun Modifier.dimmed(on: Boolean) = alpha(if (on) 0.55f else 1f)
