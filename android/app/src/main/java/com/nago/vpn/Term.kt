package com.nago.vpn

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 터미널 느낌의 테마. 색·글꼴(JetBrains Mono)은 iOS 앱과 같다.
 * 색은 다크·라이트 두 벌이고 [dark]에 따라 바뀐다(App이 settings → appearance와 시스템 설정으로 정함).
 * 라이트는 초록빛 종이색 바탕에, 글자색은 밝은 바탕에서 읽히게(대비 4.5:1 넘게) 한 단계씩 진하게.
 */
object Term {
    var dark by mutableStateOf(true)

    private fun pick(dark: Long, light: Long) = Color(if (this.dark) dark else light)

    val bg get() = pick(0xFF0A0D0A, 0xFFF4F6F1)
    val surface get() = pick(0xFF0D110D, 0xFFFFFFFF)     // 상자 안쪽
    val chrome get() = pick(0xFF141A14, 0xFFE9EEE6)
    val border get() = pick(0xFF1F2A1F, 0xFFD3DCCF)
    val text get() = pick(0xFFC9D4C5, 0xFF1F2B1F)
    val muted get() = pick(0xFF5F6F5F, 0xFF667566)
    val green get() = pick(0xFF4ADE80, 0xFF15803D)
    val amber get() = pick(0xFFFBBF24, 0xFFB45309)
    val red get() = pick(0xFFF87171, 0xFFDC2626)
    val key get() = pick(0xFF67E8F9, 0xFF0E7490)          // 이름/키
    val num get() = pick(0xFFE7ECE5, 0xFF0F1A0F)          // 숫자
    val track get() = pick(0xFF1C261C, 0xFFE3E9E0)        // 막대 빈 칸
    val dot get() = pick(0xFF3A463A, 0xFFC2CCBE)          // 지도 땅 점
    /** 떠 있는 판(시트)의 그림자 */
    val shadow get() = Color.Black.copy(alpha = if (dark) 0.5f else 0.10f)

    val font = FontFamily(
        Font(R.font.jetbrains_mono_regular, FontWeight.Normal),
        Font(R.font.jetbrains_mono_semibold, FontWeight.SemiBold),
        Font(R.font.jetbrains_mono_bold, FontWeight.Bold),
    )

    fun mono(size: TextUnit, weight: FontWeight = FontWeight.Normal, color: Color = text) =
        TextStyle(fontFamily = font, fontSize = size, fontWeight = weight, color = color)
}

/** 누르면 살짝 작아졌다가 튕겨 돌아오는 손맛(버튼·카드) */
@Composable
fun Modifier.pressable(enabled: Boolean = true, onClick: () -> Unit): Modifier {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.96f else 1f, spring(dampingRatio = 0.55f, stiffness = 900f), label = "press")
    return this
        .graphicsLayer { scaleX = scale; scaleY = scale }
        .clickable(interactionSource = source, indication = null, enabled = enabled, onClick = onClick)
}

/** 0 → 1 → 0을 [periodMs]마다 부드럽게 오가는 값(불빛·커서). 꺼져 있으면 0 */
@Composable
fun pulse(periodMs: Int, active: Boolean = true): Float {
    if (!active) return 0f
    val transition = rememberInfiniteTransition(label = "pulse")
    val value by transition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(periodMs / 2), RepeatMode.Reverse), label = "pulse-value",
    )
    return value
}

/** `~/vpn $▌` 머리줄 */
@Composable
fun TermHeader(path: String) {
    val off = pulse(1100)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("~/", style = Term.mono(22.sp, FontWeight.Bold, Term.muted))
        Text(path, style = Term.mono(22.sp, FontWeight.Bold, Term.green))
        Text(" $ ", style = Term.mono(22.sp, FontWeight.Bold, Term.muted))
        // 터미널 커서처럼 대부분 켜져 있다가 짧게 꺼진다
        Box(Modifier.size(11.dp, 22.dp).alpha(if (off > 0.7f) 1f - (off - 0.7f) / 0.3f else 1f).background(Term.green))
    }
}

/** 머리줄 오른쪽 `● secured` 알약. 켜져 있으면 둘레로 빛이 번지고, 연결 중이면 깜빡인다. */
enum class PillKind { On, Busy, Error, Off }

@Composable
fun StatusPill(kind: PillKind, text: String) {
    val target = when (kind) {
        PillKind.On -> Term.green
        PillKind.Busy -> Term.amber
        PillKind.Error -> Term.red
        PillKind.Off -> Term.muted
    }
    val color by animateColorAsState(target, tween(300), label = "pill")
    val phase = pulse(if (kind == PillKind.Busy) 1100 else 2600, kind == PillKind.On || kind == PillKind.Busy)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        modifier = Modifier
            .background(Term.surface.copy(alpha = 0.85f), RoundedCornerShape(50))
            .border(1.dp, if (kind == PillKind.Off) Term.border else color.copy(alpha = 0.45f), RoundedCornerShape(50))
            .padding(horizontal = 10.dp, vertical = 6.dp),
    ) {
        Box(Modifier.size(15.dp), contentAlignment = Alignment.Center) {
            if (kind == PillKind.On) {
                val ring = 7f + 8f * phase
                Box(Modifier.size(ring.dp).background(color.copy(alpha = 0.35f * (1 - phase)), CircleShape))
            }
            Box(Modifier.size(7.dp).alpha(if (kind == PillKind.Busy) 1f - 0.6f * phase else 1f).background(color, CircleShape))
        }
        Text(text, style = Term.mono(12.sp, FontWeight.SemiBold, if (kind == PillKind.Off) Term.muted else color))
    }
}

/** 지도 위 머리줄 쪽에서 번지는 상태 빛(secured 초록 · linking 노랑이 숨 쉼 · failed 빨강, exposed는 없음) */
@Composable
fun Modifier.stateGlow(kind: PillKind): Modifier {
    val target = when (kind) {
        PillKind.On -> Term.green
        PillKind.Busy -> Term.amber
        PillKind.Error -> Term.red
        PillKind.Off -> Color.Transparent
    }
    val color by animateColorAsState(target, tween(900), label = "glow")
    val strength by animateFloatAsState(if (kind == PillKind.Off) 0f else 1f, tween(900), label = "glow-strength")
    val breathe = pulse(1800, kind == PillKind.Busy)
    val alpha = 0.22f * strength * (if (kind == PillKind.Busy) 0.55f + 0.45f * breathe else 1f)
    return drawBehind {
        if (alpha <= 0.001f) return@drawBehind
        drawRect(
            Brush.radialGradient(
                colors = listOf(color.copy(alpha = alpha), color.copy(alpha = 0f)),
                center = Offset(size.width * 0.82f, 0f),
                radius = 340.dp.toPx(),
            ),
        )
    }
}

/** `// label` 주석 머리가 달린 테두리 상자 */
@Composable
fun TermBlock(label: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("// $label", style = Term.mono(12.sp, color = Term.muted))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(Term.surface, RoundedCornerShape(8.dp))
                .border(1.dp, Term.border, RoundedCornerShape(8.dp))
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            content = content,
        )
    }
}

/** `user  wifiscan` 처럼 왼쪽에 키, 오른쪽에 값 */
@Composable
fun TermField(
    key: String, value: String, onChange: (String) -> Unit, placeholder: String,
    secure: Boolean = false, enabled: Boolean = true,
) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.alpha(if (enabled) 1f else 0.5f)) {
        Text(key, style = Term.mono(15.sp, color = Term.muted), modifier = Modifier.width(56.dp))
        Box(Modifier.fillMaxWidth()) {
            if (value.isEmpty()) {
                Text(placeholder, style = Term.mono(15.sp, color = Term.muted.copy(alpha = 0.5f)))
            }
            BasicTextField(
                value = value,
                onValueChange = onChange,
                enabled = enabled,
                singleLine = true,
                textStyle = Term.mono(15.sp),
                cursorBrush = SolidColor(Term.green),
                visualTransformation = if (secure) PasswordVisualTransformation() else VisualTransformation.None,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
fun TermDivider() {
    Box(Modifier.fillMaxWidth().size(1.dp).background(Term.border))
}

/** `[kr] jp us uk` 처럼 하나를 고르는 줄 */
@Composable
fun <T> TermChoice(options: List<Pair<String, T>>, selected: T, enabled: Boolean, onSelect: (T) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.alpha(if (enabled) 1f else 0.5f)) {
        options.forEach { (label, value) ->
            val on = value == selected
            Text(
                label,
                style = Term.mono(13.sp, if (on) FontWeight.Bold else FontWeight.Normal, if (on) Term.bg else Term.muted),
                modifier = Modifier
                    .background(if (on) Term.green else Color.Transparent, RoundedCornerShape(5.dp))
                    .border(1.dp, if (on) Term.green else Term.border, RoundedCornerShape(5.dp))
                    .pressable(enabled) { onSelect(value) }
                    .padding(horizontal = 10.dp, vertical = 6.dp),
            )
        }
    }
}

/** `> 진행 중`, `✓ 성공`, `✗ 실패` 한 줄 */
@Composable
fun StatusLine(kind: Char, text: String) {
    val color = when (kind) {
        '✓' -> Term.green
        '✗' -> Term.red
        '!' -> Term.amber
        else -> Term.muted
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(kind.toString(), style = Term.mono(13.sp, color = color))
        Text(text, style = Term.mono(13.sp, color = if (kind == '>') Term.muted else color))
    }
}

/** `[ copy ]` 같은 작은 테두리 버튼 */
@Composable
fun TermSmallButton(label: String, danger: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    Text(
        label,
        style = Term.mono(13.sp, color = if (danger) Term.red else Term.text),
        modifier = Modifier
            .alpha(if (enabled) 1f else 0.4f)
            .border(1.dp, Term.border, RoundedCornerShape(5.dp))
            .pressable(enabled, onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
    )
}

/** 초록 꽉 찬 버튼(위험한 동작이면 빨간 테두리, 진행 중이면 테두리만) */
@Composable
fun TermButton(label: String, danger: Boolean, enabled: Boolean, busy: Boolean = false, onClick: () -> Unit) {
    val accent = when {
        busy -> Term.amber
        danger -> Term.red
        else -> Term.green
    }
    val filled = !danger && !busy
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxWidth()
            .alpha(if (enabled) 1f else 0.35f)
            .background(if (filled) accent else Term.surface, RoundedCornerShape(6.dp))
            .border(1.dp, accent, RoundedCornerShape(6.dp))
            .pressable(enabled, onClick)
            .padding(vertical = 15.dp),
    ) {
        Text(label, style = Term.mono(14.sp, FontWeight.SemiBold, if (filled) Term.bg else accent))
    }
}

/** iOS 토글처럼 생긴 스위치(초록 판 + 흰 손잡이). 누르면 손잡이가 미끄러진다 */
@Composable
fun TermSwitch(checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    val knob by animateFloatAsState(if (checked) 1f else 0f, spring(dampingRatio = 0.75f, stiffness = 600f), label = "switch")
    val track by animateColorAsState(
        if (checked) Term.green else if (Term.dark) Color(0x52787880) else Color(0x29787880),
        tween(200), label = "switch-track",
    )
    Box(
        modifier = Modifier
            .alpha(if (enabled) 1f else 0.5f)
            .size(51.dp, 31.dp)
            .background(track, RoundedCornerShape(50))
            .clickable(remember { MutableInteractionSource() }, indication = null, enabled = enabled) { onChange(!checked) }
            .padding(2.dp),
    ) {
        Box(
            Modifier
                .graphicsLayer { translationX = knob * 20.dp.toPx() }
                .size(27.dp)
                .shadow(2.dp, CircleShape)
                .background(Color.White, CircleShape),
        )
    }
}

/** `--nagoing ············ (●)` 한 줄 */
@Composable
fun ToggleRow(label: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(label, style = Term.mono(13.sp, color = Term.muted), modifier = Modifier.weight(1f))
        TermSwitch(checked, enabled, onChange)
    }
}

/** 상자 안 `key  [a] b c` 한 줄 */
@Composable
fun KeyRow(key: String, content: @Composable () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(key, style = Term.mono(13.sp, color = Term.muted))
        content()
    }
}

/** 꽉 찬 너비의 테두리 버튼(`view ········· 42 lines`) */
@Composable
fun TermWideButton(onClick: () -> Unit, content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .background(Term.surface, RoundedCornerShape(6.dp))
            .border(1.dp, Term.border, RoundedCornerShape(6.dp))
            .pressable(true, onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        content = content,
    )
}

/** 한 줄에 다 들어가게 글자 크기를 [minScale]배까지 줄인다(SwiftUI minimumScaleFactor처럼). 그래도 넘치면 말줄임 */
@Composable
fun FitText(text: String, style: TextStyle, minScale: Float = 0.7f, modifier: Modifier = Modifier) {
    androidx.compose.foundation.layout.BoxWithConstraints(modifier) {
        val measurer = androidx.compose.ui.text.rememberTextMeasurer()
        val density = androidx.compose.ui.platform.LocalDensity.current
        val available = with(density) { maxWidth.toPx() }
        val width = remember(text, style) { measurer.measure(text, style, maxLines = 1, softWrap = false).size.width }
        val scale = if (width <= available || width == 0) 1f else (available / width).coerceAtLeast(minScale)
        Text(text, style = style.copy(fontSize = style.fontSize * scale), maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, softWrap = false)
    }
}
