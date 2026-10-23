package com.nago.vpn

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** 터미널 느낌의 다크 테마. 색은 GitHub Dark 팔레트(iOS 앱과 같은 값). */
object Term {
    val bg = Color(0xFF0D1117)
    val surface = Color(0xFF161B22)
    val border = Color(0xFF30363D)
    val text = Color(0xFFE6EDF3)
    val muted = Color(0xFF7D8590)
    val green = Color(0xFF3FB950)
    val amber = Color(0xFFD29922)
    val red = Color(0xFFF85149)

    fun mono(size: TextUnit, weight: FontWeight = FontWeight.Normal, color: Color = text) =
        TextStyle(fontFamily = FontFamily.Monospace, fontSize = size, fontWeight = weight, color = color)
}

/** `~/vpn $▌` 머리줄 */
@Composable
fun TermHeader(path: String) {
    val blink = rememberInfiniteTransition(label = "cursor")
    val alpha by blink.animateFloat(
        initialValue = 1f, targetValue = 0f,
        animationSpec = infiniteRepeatable(tween(550), RepeatMode.Reverse), label = "cursor-alpha",
    )
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("~/", style = Term.mono(22.sp, FontWeight.Bold, Term.muted))
        Text(path, style = Term.mono(22.sp, FontWeight.Bold, Term.green))
        Text(" $ ", style = Term.mono(22.sp, FontWeight.Bold, Term.muted))
        Box(Modifier.size(11.dp, 22.dp).alpha(alpha).background(Term.green))
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
                    .clickable(enabled = enabled) { onSelect(value) }
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
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
    )
}

/** 초록 꽉 찬 버튼(위험한 동작이면 빨간 테두리) */
@Composable
fun TermButton(label: String, danger: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val accent = if (danger) Term.red else Term.green
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxWidth()
            .alpha(if (enabled) 1f else 0.35f)
            .background(if (danger) Term.surface else accent, RoundedCornerShape(6.dp))
            .border(1.dp, accent, RoundedCornerShape(6.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 12.dp),
    ) {
        Text(
            label,
            style = Term.mono(14.sp, FontWeight.SemiBold, if (danger) accent else Term.bg),
        )
    }
}
