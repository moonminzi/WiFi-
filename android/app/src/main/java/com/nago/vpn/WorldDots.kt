package com.nago.vpn

import android.content.Context

/**
 * route 지도에 찍는 점 세계 지도(iOS WorldDots.swift와 같은 데이터·방법).
 * 메르카토르 평면을 0.5° 칸으로 나눠 칸마다 바다/땅/나갈 국가를 적었다.
 * 데이터는 assets/worlddots.txt — tools/worlddots-android.py가 iOS의 WorldDotsData.swift에서 옮긴다.
 */
object WorldDots {
    /** 칸 값: 0 바다, 1 땅, 2… [VpnRegion] 순서의 나라 */
    class Level(val stride: Int, val cols: Int, val rows: Int, val cell: Double, private val cells: ByteArray) {
        /** 경도 방향은 지구를 한 바퀴 돌아 이어진다 */
        fun value(col: Int, row: Int): Int = cells[row * cols + ((col % cols) + cols) % cols].toInt()
    }

    var step = 0.5
        private set
    var yTop = 120.0
        private set

    /** 0.5° · 1° · 2° · 4° 네 단계. 화면에서 점 간격이 알맞은 단계를 골라 그린다. */
    @Volatile var levels: List<Level> = emptyList()
        private set

    @Synchronized
    fun load(context: Context) {
        if (levels.isNotEmpty()) return
        val lines = context.assets.open("worlddots.txt").bufferedReader().use { it.readLines() }
        val head = lines.first().split(' ')
        val cols = head[0].toInt()
        val rows = head[1].toInt()
        step = head[2].toDouble()
        yTop = head[3].toDouble()
        val fine = decode(lines.drop(1), cols, rows)
        levels = listOf(1, 2, 4, 8).map { coarsen(fine, cols, rows, it) }
    }

    /** 나라 글자. [VpnRegion] 순서(tools/worldgrid.py의 LETTERS와 같아야 함) */
    private const val LETTERS = "kjugsdfewcbai"

    private fun code(c: Char): Byte {
        if (c == '#') return 1
        val i = LETTERS.indexOf(c)
        return if (i < 0) 0 else (2 + i).toByte()
    }

    private fun decode(lines: List<String>, cols: Int, rows: Int): ByteArray {
        val out = ByteArray(cols * rows)
        lines.take(rows).forEachIndexed { row, line ->
            var i = row * cols
            val end = i + cols
            var k = 0
            while (k < line.length) {
                val value = code(line[k])
                k += 1
                var count = 0
                while (k < line.length && line[k].isDigit()) {
                    count = count * 10 + (line[k] - '0')
                    k += 1
                }
                val stop = minOf(i + maxOf(count, 1), end)
                if (value != 0.toByte()) for (x in i until stop) out[x] = value
                i = stop
            }
        }
        return out
    }

    /** s×s 칸을 점 하나로. 30% 넘게 땅이면 점을 찍고, 그중 한 나라가 20% 넘게 차지하면 그 나라 점. */
    private fun coarsen(fine: ByteArray, cols: Int, rows: Int, s: Int): Level {
        val lc = cols / s
        val lr = rows / s
        if (s == 1) return Level(1, lc, lr, step, fine)
        val cells = ByteArray(lc * lr)
        val counts = IntArray(2 + LETTERS.length)
        val area = s * s
        for (row in 0 until lr) {
            for (col in 0 until lc) {
                counts.fill(0)
                for (b in 0 until s) {
                    val base = (row * s + b) * cols + col * s
                    for (a in 0 until s) counts[fine[base + a].toInt()] += 1
                }
                if ((area - counts[0]) * 10 < area * 3) continue
                var best = 1
                for (c in 2 until counts.size) if (counts[c] > counts[best] && counts[c] * 5 >= area) best = c
                cells[row * lc + col] = best.toByte()
            }
        }
        return Level(s, lc, lr, step * s, cells)
    }
}
