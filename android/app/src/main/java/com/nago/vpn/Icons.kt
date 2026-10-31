package com.nago.vpn

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate as rotateModifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * iOS 화면에 쓰는 SF Symbols 몇 개를 같은 모양으로 그린다(머티리얼 아이콘은 생김새가 달라서 쓰지 않는다).
 * 모두 24칸 격자에 그리고 [size]에 맞춰 늘린다.
 */
enum class Glyph {
    /** 탭: vpn (lock.shield.fill) */
    Shield,
    /** 탭: settings (gearshape.fill) */
    Gear,
    /** 연결 버튼 (bolt.horizontal) */
    Bolt,
    /** 끊기 버튼 (stop.circle) */
    Stop,
    /** 취소 (xmark) */
    Close,
    /** 검사 단추 (dot.radiowaves.left.and.right) */
    Radio,
    /** 다시 검사 (arrow.clockwise) */
    Refresh,
    /** 접고 펴기 (chevron.right) */
    Chevron,
}

@Composable
fun TermIcon(glyph: Glyph, size: Dp, color: Color, modifier: Modifier = Modifier, hole: Color = Term.bg) {
    Canvas(modifier.size(size)) {
        val u = this.size.minDimension / 24f
        when (glyph) {
            Glyph.Shield -> shield(u, color, hole)
            Glyph.Gear -> gear(u, color, hole)
            Glyph.Bolt -> bolt(u, color)
            Glyph.Stop -> stop(u, color)
            Glyph.Close -> close(u, color)
            Glyph.Radio -> radio(u, color)
            Glyph.Refresh -> refresh(u, color)
            Glyph.Chevron -> chevron(u, color)
        }
    }
}

private fun DrawScope.shield(u: Float, color: Color, hole: Color) {
    val p = Path().apply {
        moveTo(12 * u, 1.8f * u)
        cubicTo(15 * u, 3.4f * u, 18 * u, 4.2f * u, 20.6f * u, 4.4f * u)
        lineTo(20.6f * u, 11f * u)
        cubicTo(20.6f * u, 16.4f * u, 17 * u, 20.2f * u, 12 * u, 22.4f * u)
        cubicTo(7 * u, 20.2f * u, 3.4f * u, 16.4f * u, 3.4f * u, 11f * u)
        lineTo(3.4f * u, 4.4f * u)
        cubicTo(6 * u, 4.2f * u, 9 * u, 3.4f * u, 12 * u, 1.8f * u)
        close()
    }
    drawPath(p, color)
    // 자물쇠: 고리 + 몸통(바탕색으로 뚫는다)
    drawArc(hole, 180f, 180f, false, Offset(9.4f * u, 7.4f * u), Size(5.2f * u, 5.6f * u), style = Stroke(1.5f * u))
    drawLine(hole, Offset(9.4f * u, 10.2f * u), Offset(9.4f * u, 11.4f * u), 1.5f * u)
    drawLine(hole, Offset(14.6f * u, 10.2f * u), Offset(14.6f * u, 11.4f * u), 1.5f * u)
    drawRoundRect(hole, Offset(8.2f * u, 11.2f * u), Size(7.6f * u, 5.8f * u), CornerRadius(1.2f * u))
}

private fun DrawScope.gear(u: Float, color: Color, hole: Color) {
    val c = Offset(12 * u, 12 * u)
    for (i in 0 until 8) {
        rotate(i * 45f, c) {
            drawRoundRect(color, Offset(10 * u, 1.4f * u), Size(4 * u, 5 * u), CornerRadius(1 * u))
        }
    }
    drawCircle(color, 8 * u, c)
    drawCircle(hole, 3.4f * u, c)
}

private fun DrawScope.bolt(u: Float, color: Color) {
    val p = Path().apply {
        moveTo(1.5f * u, 14.8f * u)
        lineTo(8.6f * u, 7.4f * u)
        lineTo(10.6f * u, 11.2f * u)
        lineTo(22.5f * u, 9.2f * u)
        lineTo(15.4f * u, 16.6f * u)
        lineTo(13.4f * u, 12.8f * u)
        close()
    }
    drawPath(p, color, style = Stroke(1.7f * u, join = StrokeJoin.Round))
}

private fun DrawScope.stop(u: Float, color: Color) {
    drawCircle(color, 9.6f * u, Offset(12 * u, 12 * u), style = Stroke(1.8f * u))
    drawRoundRect(color, Offset(8.6f * u, 8.6f * u), Size(6.8f * u, 6.8f * u), CornerRadius(1.4f * u))
}

private fun DrawScope.close(u: Float, color: Color) {
    drawLine(color, Offset(5.5f * u, 5.5f * u), Offset(18.5f * u, 18.5f * u), 2.2f * u, StrokeCap.Round)
    drawLine(color, Offset(18.5f * u, 5.5f * u), Offset(5.5f * u, 18.5f * u), 2.2f * u, StrokeCap.Round)
}

private fun DrawScope.radio(u: Float, color: Color) {
    val c = Offset(12 * u, 12 * u)
    drawCircle(color, 2.4f * u, c)
    for ((r, sweep) in listOf(5.6f to 76f, 9.6f to 84f)) {
        val box = Rect(c.x - r * u, c.y - r * u, c.x + r * u, c.y + r * u)
        val style = Stroke(1.9f * u, cap = StrokeCap.Round)
        drawArc(color, -sweep / 2, sweep, false, box.topLeft, box.size, style = style)
        drawArc(color, 180 - sweep / 2, sweep, false, box.topLeft, box.size, style = style)
    }
}

private fun DrawScope.refresh(u: Float, color: Color) {
    val r = 8.2f * u
    val c = Offset(12 * u, 12.8f * u)
    drawArc(color, -60f, 300f, false, Offset(c.x - r, c.y - r), Size(r * 2, r * 2), style = Stroke(2.1f * u, cap = StrokeCap.Round))
    // 화살촉: 호의 끝(-60°)에서 시계 방향으로
    val a = -60.0 * PI / 180
    val tip = Offset(c.x + r * cos(a).toFloat(), c.y + r * sin(a).toFloat())
    val head = Path().apply {
        moveTo(tip.x + 3.6f * u, tip.y + 0.6f * u)
        lineTo(tip.x - 1.4f * u, tip.y - 3.4f * u)
        lineTo(tip.x - 1.2f * u, tip.y + 3.2f * u)
        close()
    }
    drawPath(head, color)
}

private fun DrawScope.chevron(u: Float, color: Color) {
    val p = Path().apply {
        moveTo(8.5f * u, 4.5f * u)
        lineTo(16 * u, 12 * u)
        lineTo(8.5f * u, 19.5f * u)
    }
    drawPath(p, color, style = Stroke(3.2f * u, cap = StrokeCap.Round, join = StrokeJoin.Round))
}

/** 접었다 펴는 패널 머리줄의 화살표(▸ 접힘 · ▾ 펼침) */
@Composable
fun FoldChevron(folded: Boolean) {
    val angle by animateFloatAsState(if (folded) 0f else 90f, tween(300), label = "chevron")
    TermIcon(Glyph.Chevron, 9.dp, Term.muted, Modifier.rotateModifier(angle))
}
