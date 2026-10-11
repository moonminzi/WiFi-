import Foundation
@testable import NagoTLCore

/// 시험용 그리기 도구(그린 글자 픽셀을 정답 마스크로 기억한다)
struct Canvas {
    var bmp: Bitmap
    var truth: [Bool]

    init(width: Int, height: Int, fill: RGBA = .white) {
        bmp = Bitmap(width: width, height: height, fill: fill)
        truth = [Bool](repeating: false, count: width * height)
    }

    mutating func dot(_ x: Int, _ y: Int, _ c: RGBA, text: Bool = false) {
        guard x >= 0, y >= 0, x < bmp.width, y < bmp.height else { return }
        bmp.set(x, y, c)
        truth[y * bmp.width + x] = text
    }

    mutating func rect(_ r: IRect, _ c: RGBA, text: Bool = false) {
        for y in r.y..<r.maxY {
            for x in r.x..<r.maxX { dot(x, y, c, text: text) }
        }
    }

    /// 타원(안쪽 채우기 + 테두리)
    mutating func ellipse(cx: Double, cy: Double, rx: Double, ry: Double, outline: Double, line: RGBA, fill: RGBA) {
        let x0 = Int(cx - rx - outline - 1), x1 = Int(cx + rx + outline + 1)
        let y0 = Int(cy - ry - outline - 1), y1 = Int(cy + ry + outline + 1)
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = (Double(x) + 0.5 - cx), dy = (Double(y) + 0.5 - cy)
                let outer = (dx * dx) / ((rx + outline / 2) * (rx + outline / 2)) + (dy * dy) / ((ry + outline / 2) * (ry + outline / 2))
                let inner = (dx * dx) / ((rx - outline / 2) * (rx - outline / 2)) + (dy * dy) / ((ry - outline / 2) * (ry - outline / 2))
                if inner <= 1 { dot(x, y, fill) } else if outer <= 1 { dot(x, y, line) }
            }
        }
    }

    mutating func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, width: Int, _ c: RGBA) {
        let n = max(abs(x1 - x0), abs(y1 - y0), 1)
        for k in 0...n {
            let x = x0 + (x1 - x0) * k / n, y = y0 + (y1 - y0) * k / n
            for dy in 0..<width {
                for dx in 0..<width { dot(x + dx - width / 2, y + dy - width / 2, c) }
            }
        }
    }

    /// 한자 비슷한 글자 하나(口 모양 안쪽 빈칸 포함) — 크기 s 칸
    mutating func glyph(_ x: Int, _ y: Int, _ s: Int, seed: Int, ink: RGBA = .black) {
        let t = max(2, s / 9)
        var rng = seed &* 2654435761 &+ 12345
        func next() -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) & 0x7FFF_FFFF)
        }
        switch next() % 3 {
        case 0:
            // 口 + 가운데 세로획
            rect(IRect(x: x, y: y, w: s, h: t), ink, text: true)
            rect(IRect(x: x, y: y + s - t, w: s, h: t), ink, text: true)
            rect(IRect(x: x, y: y, w: t, h: s), ink, text: true)
            rect(IRect(x: x + s - t, y: y, w: t, h: s), ink, text: true)
            rect(IRect(x: x + s / 2 - t / 2, y: y + s / 4, w: t, h: s / 2), ink, text: true)
        case 1:
            // 三 + 丨
            for k in 0..<3 { rect(IRect(x: x + 1, y: y + k * (s - t) / 2, w: s - 2, h: t), ink, text: true) }
            rect(IRect(x: x + s / 2 - t / 2, y: y, w: t, h: s), ink, text: true)
        default:
            // 가나 비슷한 두 덩어리
            rect(IRect(x: x + s / 5, y: y, w: t, h: s * 3 / 5), ink, text: true)
            rect(IRect(x: x, y: y + s / 3, w: s * 4 / 5, h: t), ink, text: true)
            rect(IRect(x: x + s / 2, y: y + s / 2, w: t, h: s / 2), ink, text: true)
            rect(IRect(x: x + s / 2, y: y + s - t, w: s / 2, h: t), ink, text: true)
        }
    }

    /// 세로쓰기 글줄들(오른쪽 칸부터). 글자 상자를 돌려준다.
    @discardableResult
    mutating func verticalText(right: Int, top: Int, columns: [Int], size: Int, seed: Int, ink: RGBA = .black) -> IRect {
        var box = IRect(x: 0, y: 0, w: 0, h: 0)
        var x = right
        for (ci, n) in columns.enumerated() {
            for k in 0..<n {
                let gx = x - size, gy = top + k * (size + 3)
                glyph(gx, gy, size, seed: seed * 100 + ci * 10 + k, ink: ink)
                box = box.union(IRect(x: gx, y: gy, w: size, h: size))
            }
            x -= size + size / 4
        }
        return box
    }

    /// 정답 글자 픽셀이 몇 % 지워졌나(바탕색과 가까워졌나)
    func erasedFraction(_ after: Bitmap, background: RGBA) -> Double {
        var total = 0, gone = 0
        for i in truth.indices where truth[i] {
            total += 1
            if after.color(i % after.width, i / after.width).distance2(background) <= 40 * 40 { gone += 1 }
        }
        return total > 0 ? Double(gone) / Double(total) : 1
    }
}

/// 같은 값이 나오는 난수(시험 재현용)
struct SeededRandom {
    var state: UInt64

    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }
}
