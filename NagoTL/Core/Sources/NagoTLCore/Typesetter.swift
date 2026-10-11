import Foundation

/// 글자 폭(글자 크기 1 기준). 앱에서는 CoreText 글꼴로, 시험에서는 어림값으로.
public protocol GlyphMetrics: Sendable {
    func advance(_ c: Character) -> Double
}

/// 어림 글자 폭(한글·한자·가나 1, 영문 0.56, 띄어쓰기 0.28)
public struct ApproxMetrics: GlyphMetrics {
    public init() {}

    public func advance(_ c: Character) -> Double {
        guard let s = c.unicodeScalars.first else { return 1 }
        switch s.value {
        case 0x20: return 0.28
        case 0x21, 0x2C, 0x2E, 0x3A, 0x3B, 0x27, 0x22: return 0.32
        case 0x21..<0x7F: return 0.56
        case 0x2026: return 1.0
        case 0x1100...0x11FF, 0x3000...0x9FFF, 0xAC00...0xD7A3, 0xFF00...0xFFEF: return 1.0
        default: return 0.8
        }
    }
}

/// 번역 글자를 앉힐 모양: 행마다 쓸 수 있는 가로 구간
public struct LayoutShape: Sendable {
    public let rect: IRect
    /// 글줄을 가운데 맞출 세로축
    public let centerX: Double
    /// 글 덩어리를 가운데 맞출 높이
    public let centerY: Double
    let starts: [Int]
    let ends: [Int]

    public init(rect: IRect) {
        self.rect = rect
        centerX = rect.centerX
        centerY = rect.centerY
        starts = [Int](repeating: rect.x, count: max(0, rect.h))
        ends = [Int](repeating: rect.maxX, count: max(0, rect.h))
    }

    /// 말풍선 안쪽 모양. 행마다 무게중심 축을 지나는(없으면 가장 긴) 구간을 쓴다.
    public init(region: RegionMask) {
        let bb = region.boundingBox
        rect = bb
        var sx = 0.0, sy = 0.0, n = 0.0
        for ly in 0..<region.rect.h {
            for lx in 0..<region.rect.w where region.bits[ly * region.rect.w + lx] {
                sx += Double(lx + region.rect.x) + 0.5
                sy += Double(ly + region.rect.y) + 0.5
                n += 1
            }
        }
        centerX = n > 0 ? sx / n : bb.centerX
        centerY = n > 0 ? sy / n : bb.centerY
        var st = [Int](repeating: 0, count: max(0, bb.h))
        var en = [Int](repeating: 0, count: max(0, bb.h))
        let axis = Int(centerX)
        for row in 0..<bb.h {
            let y = bb.y + row
            var bestS = 0, bestE = 0
            var x = bb.x
            while x < bb.maxX {
                guard region.get(x, y) else {
                    x += 1
                    continue
                }
                let s = x
                while x < bb.maxX && region.get(x, y) { x += 1 }
                if s <= axis && axis < x {
                    bestS = s
                    bestE = x
                    break
                }
                if x - s > bestE - bestS {
                    bestS = s
                    bestE = x
                }
            }
            st[row] = bestS
            en[row] = bestE
        }
        starts = st
        ends = en
    }

    /// y0..<y1 높이에서 모든 행이 함께 쓸 수 있는 가로 구간
    public func band(_ y0: Double, _ y1: Double) -> (Double, Double)? {
        let a = max(rect.y, Int(y0.rounded(.down))), b = min(rect.maxY, Int(y1.rounded(.up)))
        guard b > a, y0 >= Double(rect.y) - 0.5, y1 <= Double(rect.maxY) + 0.5 else { return nil }
        var s = Int.min, e = Int.max
        for y in a..<b {
            s = max(s, starts[y - rect.y])
            e = min(e, ends[y - rect.y])
        }
        return e > s ? (Double(s), Double(e)) : nil
    }
}

/// 배치된 한 줄
public struct LaidLine: Sendable, Equatable, Codable {
    public var text: String
    /// 줄 왼쪽
    public var x: Double
    /// 줄 상자 위(줄 상자 높이 = lineHeight, 글자는 그 가운데)
    public var y: Double
    public var width: Double
}

public struct TextLayout: Sendable, Equatable, Codable {
    public var fontSize: Double
    public var lineHeight: Double
    /// 가로쓰기: 줄(x=왼쪽, y=줄 상자 위, width=줄 길이)
    /// 세로쓰기: 열(x=열 왼쪽, y=열 위, width=열 길이, 열 폭=lineHeight). 오른쪽 열부터 읽는다
    public var lines: [LaidLine]
    /// 가장 작은 크기로도 모양 안에 다 못 넣었다(글자가 말풍선 밖으로 조금 나갈 수 있다)
    public var overflow: Bool
    public var vertical = false

    public init(fontSize: Double, lineHeight: Double, lines: [LaidLine], overflow: Bool, vertical: Bool = false) {
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.lines = lines
        self.overflow = overflow
        self.vertical = vertical
    }

    public var bounds: (x: Double, y: Double, w: Double, h: Double) {
        guard !lines.isEmpty else { return (0, 0, 0, 0) }
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for l in lines {
            if vertical {
                x0 = min(x0, l.x)
                x1 = max(x1, l.x + lineHeight)
                y0 = min(y0, l.y)
                y1 = max(y1, l.y + l.width)
            } else {
                x0 = min(x0, l.x)
                x1 = max(x1, l.x + l.width)
                y0 = min(y0, l.y)
                y1 = max(y1, l.y + lineHeight)
            }
        }
        return (x0, y0, x1 - x0, y1 - y0)
    }
}

/// 세로쓰기 글자 폭: 한 글자가 한 칸(띄어쓰기는 짧게)
public struct VerticalMetrics: GlyphMetrics {
    public init() {}

    public func advance(_ c: Character) -> Double { c == " " ? 0.35 : 1.0 }
}

/// 세로쓰기에서 글자 하나를 칸에 어떻게 세울지
public enum VerticalGlyph: Equatable, Sendable {
    /// 그대로 세운다(한글·한자·가나·영문·숫자) — 글자 몸통 가운데를 열 가운데에
    case upright
    /// 시계 방향으로 90° 돌린다(괄호·줄표·물결·말줄임표·쌍점): ( → ︵, ~ → ≀, … → ︙
    case rotated
    /// 칸 오른쪽 위(쉼표·마침표)
    case corner
    /// 칸 한가운데(느낌표·물음표·하트 같은 기호)
    case centered

    public static func of(_ c: Character) -> VerticalGlyph {
        switch c {
        case ",", ".", "、", "。", "，", "．", "､", "｡":
            return .corner
        case "(", ")", "[", "]", "{", "}", "<", ">", "「", "」", "『", "』", "《", "》", "〈", "〉", "【", "】", "〔", "〕",
             "（", "）", "［", "］", "｛", "｝", "＜", "＞", "-", "—", "–", "―", "‐", "~", "～", "〜", "ー", "…", "‥",
             ":", ";", "：", "；", "=", "＝", "_", "/", "|":
            return .rotated
        case "!", "?", "！", "？", "‼", "⁉", "⁈", "♡", "♥", "❤", "♪", "♫", "★", "☆", "·", "・", "'", "*":
            return .centered
        default:
            return .upright
        }
    }
}

public enum Typesetter {
    /// 줄 간격(글자 크기 배수)
    public static let lineSpacing = 1.2
    /// 줄 머리에 오면 안 되는 글자
    static let noStart: Set<Character> = [".", ",", "!", "?", "…", "~", ")", "]", "}", "」", "』", "》", "〉", "'", "\"",
                                          "’", "”", ":", ";", "·", "-", "—", "♡", "♥", "♪", "、", "。"]
    /// 줄 끝에 오면 안 되는 글자
    static let noEnd: Set<Character> = ["(", "[", "{", "「", "『", "《", "〈", "‘", "“"]

    struct Word {
        var chars: [Character]
        var widths: [Double]
        var width: Double { widths.reduce(0, +) }
    }

    /// 모양 안에 들어가는 가장 큰 크기로 배치한다. 줄은 띄어쓰기에서 나누고,
    /// 낱말 중간을 자르는 건 그렇게 해야 글자가 눈에 띄게 커질 때만(좁은 말풍선의 긴 낱말).
    public static func layout(_ text: String, shape: LayoutShape, maxSize: Double, minSize: Double,
                              metrics: GlyphMetrics) -> TextLayout {
        let paras = paragraphs(text, metrics: metrics)
        let space = metrics.advance(" ")
        let lo0 = max(4, min(minSize, maxSize))
        let hi0 = max(lo0, maxSize)
        guard !paras.allSatisfy({ $0.isEmpty }) else {
            return TextLayout(fontSize: hi0, lineHeight: hi0 * lineSpacing, lines: [], overflow: false)
        }
        let whole = largest(paras, shape: shape, lo: lo0, hi: hi0, space: space, split: false)
        if let w = whole, w.fontSize >= hi0 - 0.01 { return w }
        let split = largest(paras, shape: shape, lo: lo0, hi: hi0, space: space, split: true)
        switch (whole, split) {
        case let (w?, s?): return w.fontSize >= s.fontSize * 0.75 ? w : s
        case let (w?, nil): return w
        case let (nil, s?): return s
        default: return overflowLayout(paras, shape: shape, size: lo0, space: space)
        }
    }

    /// lo~hi 사이에서 들어가는 가장 큰 크기(0.25px 단위)
    static func largest(_ paras: [[Word]], shape: LayoutShape, lo lo0: Double, hi hi0: Double, space: Double,
                        split: Bool) -> TextLayout? {
        if let l = attempt(paras, shape: shape, size: hi0, space: space, split: split) { return l }
        guard attempt(paras, shape: shape, size: lo0, space: space, split: split) != nil else { return nil }
        var lo = lo0, hi = hi0
        for _ in 0..<14 {
            let mid = (lo + hi) / 2
            if attempt(paras, shape: shape, size: mid, space: space, split: split) != nil { lo = mid } else { hi = mid }
        }
        let size = max(lo0, (lo * 4).rounded(.down) / 4)
        return attempt(paras, shape: shape, size: size, space: space, split: split)
            ?? attempt(paras, shape: shape, size: lo, space: space, split: split)
    }

    /// 세로쓰기(오른쪽 열부터, 위→아래)로 사각형 안에 들어가는 가장 큰 크기. 열을 줄처럼 다루려고
    /// 가로·세로를 바꾼 사각형에 가로쓰기로 앉힌 뒤 되돌린다.
    public static func layoutVertical(_ text: String, rect: IRect, maxSize: Double, minSize: Double) -> TextLayout {
        let t = IRect(x: 0, y: 0, w: rect.h, h: rect.w)
        var l = layout(verticalForm(text), shape: LayoutShape(rect: t), maxSize: maxSize, minSize: minSize,
                       metrics: VerticalMetrics())
        let lh = l.lineHeight
        // 바꾼 사각형의 줄(y = 오른쪽 끝에서 왼쪽으로 얼마나, x = 위에서 아래로 얼마나) → 원래 그림의 열.
        // 세로쓰기는 열 머리를 맞춘다(덩어리 전체는 가운데)
        let longest = l.lines.map(\.width).max() ?? 0
        let top = Double(rect.y) + max(0, (Double(rect.h) - longest) / 2)
        l.lines = l.lines.map { line in
            LaidLine(text: line.text, x: Double(rect.maxX) - line.y - lh, y: l.overflow ? Double(rect.y) + line.x : top,
                     width: line.width)
        }
        l.vertical = true
        return l
    }

    /// 세로쓰기용 글자로: 따옴표는 낫표(“ ” → 「 」, ‘ ’ → 『 』), 점 여러 개는 말줄임표 한 칸
    public static func verticalForm(_ text: String) -> String {
        var out = ""
        var openDouble = true
        var dots = 0
        func flushDots() {
            if dots >= 2 {
                out.append("…")
            } else if dots == 1 {
                out.append(".")
            }
            dots = 0
        }
        for c in text {
            if c == "." {
                dots += 1
                continue
            }
            flushDots()
            switch c {
            case "“": out.append("「")
            case "”": out.append("」")
            case "‘": out.append("『")
            case "’": out.append("』")
            case "\"":
                out.append(openDouble ? "「" : "」")
                openDouble.toggle()
            case "…":
                // …… 처럼 겹친 말줄임표도 한 칸
                if out.last != "…" { out.append("…") }
            default: out.append(c)
            }
        }
        flushDots()
        return out
    }

    /// 크기 하나로 배치해 본다: 1줄부터 늘려 가며, 들어가면 줄 길이를 고르게 다시 나눈다.
    static func attempt(_ paras: [[Word]], shape: LayoutShape, size: Double, space: Double, split: Bool) -> TextLayout? {
        let lh = size * lineSpacing
        let maxLines = Int(Double(shape.rect.h) / lh)
        guard maxLines >= 1 else { return nil }
        // 강제 줄바꿈 수만큼은 줄이 있어야 한다
        guard maxLines >= max(1, paras.count) else { return nil }
        let total = paras.reduce(0.0) { acc, p in acc + p.reduce(0.0) { $0 + $1.width * size } }
        for n in max(1, paras.count)...maxLines {
            var top = shape.centerY - Double(n) * lh / 2
            top = min(max(top, Double(shape.rect.y)), Double(shape.rect.maxY) - Double(n) * lh)
            var spans: [(Double, Double)] = []
            var room = 0.0
            for k in 0..<n {
                // 글자가 실제로 차지하는 높이(줄 상자 가운데 글자 크기만큼)만 모양 안에 있으면 된다
                let y0 = top + Double(k) * lh + (lh - size) / 2
                guard let b = shape.band(y0, y0 + size) else {
                    spans.append((0, 0))
                    continue
                }
                let inset = size * 0.08
                let s = (b.0 + inset, b.1 - inset)
                spans.append(s.1 > s.0 ? s : (0, 0))
                room += max(0, s.1 - s.0)
            }
            if room < total { continue }
            let widths = spans.map { max(0, $0.1 - $0.0) }
            guard let lines = wrap(paras, widths: widths, size: size, space: space, split: split) else { continue }
            // 고르게: 줄 폭을 줄여도 n줄에 들어가는 한 가장 좁게
            var best = lines
            var lo = 0.4, hi = 1.0
            for _ in 0..<8 {
                let f = (lo + hi) / 2
                if let l = wrap(paras, widths: widths.map { $0 * f }, size: size, space: space, split: split),
                   l.count <= lines.count, splits(l) <= splits(lines) {
                    best = l
                    hi = f
                } else {
                    lo = f
                }
            }
            return place(best.map { ($0.0, $0.1) }, spans: spans, axis: shape.centerX, top: top, lh: lh, size: size,
                         overflow: false)
        }
        return nil
    }

    static func splits(_ lines: [(String, Double, Bool)]) -> Int { lines.reduce(0) { $0 + ($1.2 ? 1 : 0) } }

    static func place(_ lines: [(String, Double)], spans: [(Double, Double)], axis: Double, top: Double,
                      lh: Double, size: Double, overflow: Bool) -> TextLayout {
        var out: [LaidLine] = []
        for (k, line) in lines.enumerated() {
            let (s, e) = k < spans.count ? spans[k] : (axis - line.1 / 2, axis + line.1 / 2)
            var x = axis - line.1 / 2
            if e - s >= line.1 { x = min(max(x, s), e - line.1) }
            out.append(LaidLine(text: line.0, x: x, y: top + Double(k) * lh, width: line.1))
        }
        return TextLayout(fontSize: size, lineHeight: lh, lines: out, overflow: overflow)
    }

    /// 가장 작은 크기로도 안 들어갈 때: 모양의 사각형 폭으로 나누고 필요한 만큼 위아래로 넘친다
    static func overflowLayout(_ paras: [[Word]], shape: LayoutShape, size: Double, space: Double) -> TextLayout {
        let lh = size * lineSpacing
        let width = max(Double(shape.rect.w), size * 2)
        var n = 1
        var lines: [(String, Double)] = []
        while n < 400 {
            if let l = wrap(paras, widths: [Double](repeating: width, count: n), size: size, space: space, split: true) {
                lines = l.map { ($0.0, $0.1) }
                break
            }
            n += 1
        }
        let top = shape.centerY - Double(lines.count) * lh / 2
        let spans = [(Double, Double)](repeating: (shape.centerX - width / 2, shape.centerX + width / 2), count: lines.count)
        return place(lines, spans: spans, axis: shape.centerX, top: top, lh: lh, size: size, overflow: true)
    }

    static func paragraphs(_ text: String, metrics: GlyphMetrics) -> [[Word]] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{3000}" }).map { w in
                let chars = Array(w)
                return Word(chars: chars, widths: chars.map { metrics.advance($0) })
            }
        }.filter { !$0.isEmpty }
    }

    /// 줄 폭 목록에 맞춰 낱말을 채운다. 줄이 모자라면 nil. 결과는 (줄, 폭, 낱말 중간에서 끊겼나)
    static func wrap(_ paras: [[Word]], widths: [Double], size: Double, space: Double,
                     split: Bool) -> [(String, Double, Bool)]? {
        var lines: [(String, Double, Bool)] = []
        var cur: [Character] = []
        var curW = 0.0
        var k = 0
        func commit(broken: Bool = false) {
            lines.append((String(cur), curW, broken))
            cur = []
            curW = 0
            k += 1
        }
        for para in paras {
            for word in para {
                var w = word
                while true {
                    guard k < widths.count else { return nil }
                    let lim = widths[k] + 0.01
                    let ww = w.width * size
                    if cur.isEmpty {
                        if ww <= lim {
                            cur = w.chars
                            curW = ww
                            break
                        }
                        if widths[k] <= 0 {
                            // 모양이 끊긴 줄은 비워 둔다
                            commit()
                            continue
                        }
                        guard split else { return nil }
                        // 빈 줄에도 안 들어가는 긴 낱말: 글자 단위로 자른다
                        var fit = 0
                        var acc = 0.0
                        while fit < w.chars.count && acc + w.widths[fit] * size <= lim {
                            acc += w.widths[fit] * size
                            fit += 1
                        }
                        // 줄 머리 금지 글자는 앞줄에 붙이지 않고 한 글자 덜 넣어 같이 넘긴다
                        while fit > 1 && fit < w.chars.count && noStart.contains(w.chars[fit]) { fit -= 1 }
                        while fit > 1 && noEnd.contains(w.chars[fit - 1]) { fit -= 1 }
                        guard fit > 0 else { return nil }
                        cur = Array(w.chars[0..<fit])
                        curW = w.widths[0..<fit].reduce(0, +) * size
                        commit(broken: true)
                        w = Word(chars: Array(w.chars[fit...]), widths: Array(w.widths[fit...]))
                        if w.chars.isEmpty { break }
                        continue
                    }
                    if curW + space * size + ww <= lim {
                        cur.append(" ")
                        cur.append(contentsOf: w.chars)
                        curW += space * size + ww
                        break
                    }
                    commit()
                }
            }
            if !cur.isEmpty { commit() }
        }
        // 끝의 빈 줄은 버린다
        while let last = lines.last, last.0.isEmpty { lines.removeLast() }
        return lines
    }
}
