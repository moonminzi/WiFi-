import Foundation

/// 글자 덩어리의 종류(Claude가 알려 준다)
public enum BlockKind: String, Codable, Sendable, CaseIterable {
    case speech, thought, narration, caption, sfx, sign, other
}

/// 페이지에서 번역할 글자 덩어리 하나(그림 좌표)
public struct PageBlock: Sendable, Equatable {
    public var box: IRect
    public var kind: BlockKind
    /// Claude가 본 글자색·테두리색(없으면 그림에서 찾는다)
    public var fill: RGBA?
    public var outline: RGBA?
    /// 원문이 세로쓰기인지
    public var vertical: Bool

    public init(box: IRect, kind: BlockKind, fill: RGBA? = nil, outline: RGBA? = nil, vertical: Bool = false) {
        self.box = box
        self.kind = kind
        self.fill = fill
        self.outline = outline
        self.vertical = vertical
    }
}

/// 원문 글자를 어떻게 덮고, 번역을 어디에 앉힐지
public struct Refined: Sendable {
    public enum Mode: String, Codable, Sendable {
        /// 바탕이 고르다(말풍선·나레이션·빈 바탕) — 원문 글자 픽셀만 지운다
        case clean
        /// 바탕이 복잡하다(사진·그림 위 글자) — 상자를 둘레 색으로 매끈하게 덮는다(구글 렌즈처럼)
        case label
        /// 효과음 — 그림을 지우지 않고 테두리 글자로 겹쳐 쓴다
        case overlay
        /// 말풍선 없이 그림 위에 쓴 글자 — 글자·테두리 픽셀만 지우고 그 밑 그림을 둘레 그림 조각으로 되살린 뒤,
        /// 원문과 같은 색·테두리로 쓴다
        case art
    }

    public var mode: Mode
    /// 원문 글자가 실제로 있는 곳
    public var textBox: IRect
    /// clean: 다시 칠할 픽셀
    public var eraseMask: RegionMask?
    /// clean: 지울 때 색·결을 가져올 깨끗한 바탕 픽셀(글자 둘레 번짐은 뺀 것). nil이면 지울 곳 밖 어디든
    public var eraseSource: RegionMask?
    /// label: 덮을 면
    public var patch: BorderPatch?
    /// 바탕색(라벨·효과음 대비 계산에도 쓴다)
    public var background: RGBA
    /// 원문 글자색
    public var ink: RGBA
    /// 번역을 넣을 모양(말풍선 안쪽에서 가장자리를 뺀 것). 없으면 layoutRect
    public var region: RegionMask?
    public var layoutRect: IRect
    /// 원문 글자 하나의 크기(px) — 번역 글자 크기의 상한
    public var glyphSize: Double
    /// 닫힌 말풍선을 찾았는지
    public var closedBubble: Bool
    /// art: 원문 글자 테두리색(없으면 nil)
    public var outline: RGBA? = nil
    /// 원문이 세로쓰기였는지(그림 위 글자는 한글도 세로로 앉힐 수 있다)
    public var vertical = false

    /// 번역 글자를 앉힐 모양
    public var shape: LayoutShape {
        if let r = region, r.count > 0 { return LayoutShape(region: r) }
        return LayoutShape(rect: layoutRect)
    }
}

public enum Refiner {
    /// 바탕으로 볼 색 거리(제곱)
    static let backgroundTolerance = 52 * 52
    /// 글자(잉크)로 볼 색 거리(제곱)
    static let inkThreshold = 70 * 70

    /// 한 페이지를 맞추는 동안 함께 쓰는 것: 모든 덩어리 상자, 이미 찾은 말풍선 안쪽
    struct Context {
        var boxes: [IRect]
        var bubbles: [RegionMask] = []
    }

    /// 페이지의 모든 덩어리를 원본 그림 기준으로 맞춘다(지우기 전에 한꺼번에).
    /// 한 말풍선에 덩어리가 여럿이면(이어진 말풍선 등) 말풍선을 덩어리마다 나눠 준다.
    public static func refinePage(_ bmp: Bitmap, blocks: [PageBlock]) -> [Refined] {
        let boxes = blocks.map { $0.box.clamped(width: bmp.width, height: bmp.height) }
        var ctx = Context(boxes: boxes)
        var out: [Refined] = []
        for b in blocks { out.append(refine(bmp, block: b, context: &ctx)) }
        splitSharedRegions(&out, boxes: boxes)
        return out
    }

    /// Claude가 준 대략적인 상자를 실제 그림에 맞춘다(덩어리 하나만 볼 때).
    public static func refine(_ bmp: Bitmap, box: IRect, kind: BlockKind) -> Refined {
        refine(bmp, block: PageBlock(box: box, kind: kind))
    }

    public static func refine(_ bmp: Bitmap, block: PageBlock) -> Refined {
        var ctx = Context(boxes: [block.box.clamped(width: bmp.width, height: bmp.height)])
        return refine(bmp, block: block, context: &ctx)
    }

    static func refine(_ bmp: Bitmap, block: PageBlock, context ctx: inout Context) -> Refined {
        let kind = block.kind
        let box = block.box.clamped(width: bmp.width, height: bmp.height)
        let short = Double(max(1, min(box.w, box.h)))
        guard box.w >= 4, box.h >= 4 else {
            return Refined(mode: .overlay, textBox: box, eraseMask: nil, eraseSource: nil, patch: nil,
                           background: .white, ink: .black, region: nil, layoutRect: box,
                           glyphSize: max(8, short), closedBubble: false)
        }
        if kind == .sfx { return overlay(bmp, box: box) }
        let (bg, uniformity) = dominantColor(bmp, box)
        if uniformity >= 0.35, let r = closedBubble(bmp, box: box, bg: bg, context: &ctx) { return r }
        if uniformity >= 0.55, let r = openText(bmp, box: box, bg: bg) { return r }
        if let r = artText(bmp, block: block, box: box) { return r }
        return label(bmp, box: box)
    }

    /// 원문 글자를 지운다. 모든 덩어리를 refinePage로 원본에서 구한 다음 한꺼번에 부를 것.
    public static func erase(_ bmp: inout Bitmap, _ items: [Refined]) {
        for r in items where r.mode == .clean {
            guard let m = r.eraseMask else { continue }
            Inpaint.fill(&bmp, mask: m, source: r.eraseSource, fallback: r.background)
            if let s = r.eraseSource { Inpaint.texture(&bmp, mask: m, source: s) }
        }
        // 그림 위 글자: 번짐으로 대충 채운 다음 둘레 그림 조각으로 되살린다
        for r in items where r.mode == .art {
            guard let m = r.eraseMask else { continue }
            Inpaint.fill(&bmp, mask: m, source: nil, fallback: r.background)
            Inpaint.patchMatch(&bmp, mask: m)
        }
        for r in items where r.mode == .label { r.patch?.paint(&bmp) }
    }

    // MARK: - 닫힌 말풍선

    static func closedBubble(_ bmp: Bitmap, box: IRect, bg: RGBA, context ctx: inout Context) -> Refined? {
        let interior: RegionMask
        if let found = ctx.bubbles.first(where: { holds($0, box: box, bmp: bmp, bg: bg) }) {
            // 앞 덩어리가 이미 찾은 말풍선(이어진 말풍선의 다른 쪽 등)
            interior = found
        } else if let f = floodBubble(bmp, box: box, bg: bg, reachFactor: 0.8)
                    ?? floodBubble(bmp, box: box, bg: bg, reachFactor: 2.2) {
            // 이어진 말풍선처럼 큰 것은 첫 범위를 넘으므로 한 번 더 넓게 찾아본다
            interior = f
            ctx.bubbles.append(f)
        } else {
            return nil
        }
        // 흰 테두리를 두른 글자(그림 위 글자)의 테두리 그물을 말풍선으로 보지 않게: 말풍선은 안쪽에 넓은 빈 곳이 있다
        let core = interior.eroded(max(4, Int(Double(min(box.w, box.h)) * 0.08)))
        guard core.count * 5 >= interior.count else { return nil }
        let limit = interior.rect
        let filled = fillHoles(interior)
        var holes = RegionMask(rect: limit)
        for i in holes.bits.indices { holes.bits[i] = filled.bits[i] && !interior.bits[i] }
        let comps = maskComponents(holes)
        guard !comps.isEmpty else { return nil }

        let short = Double(min(box.w, box.h))
        func around(_ b: IRect) -> IRect { b.expanded(by: Int(Double(min(b.w, b.h)) * 0.3) + 8) }
        let near = around(box)
        let nearAny = ctx.boxes.map(around)
        var total = 0, nearCount = 0
        var allBox = IRect(x: 0, y: 0, w: 0, h: 0)
        for c in comps {
            total += c.pixels.count
            allBox = allBox.union(c.box)
            if nearAny.contains(where: { $0.coverage(of: c.box) > 0.5 }) { nearCount += c.pixels.count }
        }
        let filledBox = filled.boundingBox
        // 안에 갇힌 것이 거의 다 (이 페이지의 어느) 글자 근처이고, 크기가 글자에 걸맞으면 말풍선.
        // 아니면(그림이 든 흰 칸, 글 한 줄뿐인 빈 페이지) 글자 근처만 지우고 자리는 글자 주변에서 찾는다.
        let isBubble = Double(nearCount) >= Double(total) * 0.85
            && filledBox.area <= 16 * max(box.area, allBox.area)
        var text = RegionMask(rect: limit)
        for c in comps where isBubble || near.coverage(of: c.box) > 0.5 {
            for p in c.pixels { text.bits[p] = true }
        }
        guard text.count > 0 else { return nil }
        let textBox = text.boundingBox
        // 글자 가장자리의 흐린 픽셀·JPEG 번짐까지 3픽셀 넓혀 지우되 말풍선 밖(테두리)은 건드리지 않는다
        var erase = text.dilated(3)
        for i in erase.bits.indices where !filled.bits[i] { erase.bits[i] = false }
        // 색·결은 글자에서 조금 떨어진 깨끗한 바탕에서만 가져온다
        var clean = interior
        let halo = text.dilated(5)
        for i in clean.bits.indices where halo.bits[i] { clean.bits[i] = false }
        let glyph = glyphSize(text, fallback: short)
        let ink = maskColor(bmp, text, background: bg)

        if isBubble {
            let margin = max(3, Int(Double(min(filledBox.w, filledBox.h)) * 0.08))
            let region = filled.eroded(margin)
            if region.count > 0 {
                return Refined(mode: .clean, textBox: textBox, eraseMask: erase, eraseSource: clean, patch: nil,
                               background: bg, ink: ink, region: region, layoutRect: region.boundingBox,
                               glyphSize: glyph, closedBubble: true)
            }
        }
        let layout = grow(bmp, textBox.union(box), bg: bg, ignore: text)
        return Refined(mode: .clean, textBox: textBox, eraseMask: erase, eraseSource: clean, patch: nil,
                       background: bg, ink: ink, region: nil, layoutRect: layout, glyphSize: glyph, closedBubble: false)
    }

    /// 이미 찾은 말풍선 안쪽이 이 상자를 품고 있나(상자 가운데의 바탕색 픽셀이 거의 다 그 안쪽인가)
    static func holds(_ interior: RegionMask, box: IRect, bmp: Bitmap, bg: RGBA) -> Bool {
        let core = IRect(x: box.x + box.w / 5, y: box.y + box.h / 5,
                         w: max(1, box.w - 2 * (box.w / 5)), h: max(1, box.h - 2 * (box.h / 5)))
        let step = max(1, min(core.w, core.h) / 12)
        var total = 0, inside = 0
        for y in stride(from: core.y, to: core.maxY, by: step) {
            for x in stride(from: core.x, to: core.maxX, by: step) where bmp.color(x, y).distance2(bg) <= backgroundTolerance {
                total += 1
                if interior.get(x, y) { inside += 1 }
            }
        }
        return total > 0 && inside * 10 >= total * 8
    }

    /// 상자 가운데의 바탕색 픽셀에서 바탕색끼리 번져, 상자를 감싸면서 닫힌 곳을 찾는다.
    /// 상자가 조금 어긋나 첫 씨앗이 글자 획 안(口의 안쪽 등)이나 말풍선 밖에 떨어져도 다음 씨앗을 써 본다.
    static func floodBubble(_ bmp: Bitmap, box: IRect, bg: RGBA, reachFactor: Double) -> RegionMask? {
        let reach = Int(Double(max(box.w, box.h)) * reachFactor) + 16
        let limit = box.expanded(by: reach).clamped(width: bmp.width, height: bmp.height)
        let lw = limit.w
        var isBg = [Bool](repeating: false, count: limit.area)
        for ly in 0..<limit.h {
            for lx in 0..<lw where bmp.color(lx + limit.x, ly + limit.y).distance2(bg) <= backgroundTolerance {
                isBg[ly * lw + lx] = true
            }
        }
        let core = IRect(x: box.x + box.w / 5, y: box.y + box.h / 5,
                         w: max(1, box.w - 2 * (box.w / 5)), h: max(1, box.h - 2 * (box.h / 5)))
        let cx = box.x + box.w / 2, cy = box.y + box.h / 2
        let step = max(1, min(core.w, core.h) / 24)
        var seeds: [(Int, Int)] = []
        for y in stride(from: core.y, to: core.maxY, by: step) {
            for x in stride(from: core.x, to: core.maxX, by: step) {
                let i = (y - limit.y) * lw + (x - limit.x)
                if isBg[i] { seeds.append(((x - cx) * (x - cx) + (y - cy) * (y - cy), i)) }
            }
        }
        seeds.sort { $0.0 < $1.0 }

        var label = [Int32](repeating: 0, count: limit.area)
        var stack: [Int] = []
        var tries: Int32 = 0
        for (_, s) in seeds where label[s] == 0 {
            tries += 1
            if tries > 10 { break }
            label[s] = tries
            stack.append(s)
            var leaked = false
            var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
            while let i = stack.popLast() {
                let lx = i % lw, ly = i / lw
                if lx < x0 { x0 = lx }
                if lx > x1 { x1 = lx }
                if ly < y0 { y0 = ly }
                if ly > y1 { y1 = ly }
                if lx == 0 || ly == 0 || lx == lw - 1 || ly == limit.h - 1 {
                    // 페이지 끝에 닿은 건 잘린 말풍선일 수 있어 괜찮다. 탐색 범위 끝에 닿으면 열린 곳.
                    let gx = lx + limit.x, gy = ly + limit.y
                    if (lx == 0 && gx > 0) || (ly == 0 && gy > 0)
                        || (lx == lw - 1 && gx < bmp.width - 1) || (ly == limit.h - 1 && gy < bmp.height - 1) {
                        leaked = true
                    }
                }
                if lx > 0, label[i - 1] == 0, isBg[i - 1] { label[i - 1] = tries; stack.append(i - 1) }
                if lx < lw - 1, label[i + 1] == 0, isBg[i + 1] { label[i + 1] = tries; stack.append(i + 1) }
                if ly > 0, label[i - lw] == 0, isBg[i - lw] { label[i - lw] = tries; stack.append(i - lw) }
                if ly < limit.h - 1, label[i + lw] == 0, isBg[i + lw] { label[i + lw] = tries; stack.append(i + lw) }
            }
            if leaked { continue }
            let comp = IRect(x: limit.x + x0, y: limit.y + y0, w: x1 - x0 + 1, h: y1 - y0 + 1)
            // 말풍선이라면 글자 상자를 (거의) 감싼다
            if comp.intersection(box).area * 10 >= box.area * 8 {
                var m = RegionMask(rect: limit)
                for i in 0..<limit.area where label[i] == tries { m.bits[i] = true }
                return m
            }
        }
        return nil
    }

    /// 한 말풍선을 덩어리 여럿이 나눠 쓰면(이어진 말풍선, 한 풍선에 두 문단) 가까운 덩어리에게 준다.
    static func splitSharedRegions(_ out: inout [Refined], boxes: [IRect]) {
        let idx = out.indices.filter { out[$0].region != nil }
        guard idx.count > 1 else { return }
        var updates: [(Int, RegionMask?)] = []
        for i in idx {
            guard let ri = out[i].region else { continue }
            let rivals = idx.filter { j in j != i && shares(ri, out[j].region!) }
            guard !rivals.isEmpty else { continue }
            var r = ri
            let gap = 4.0
            for ly in 0..<r.rect.h {
                let py = Double(ly + r.rect.y) + 0.5
                for lx in 0..<r.rect.w where r.bits[ly * r.rect.w + lx] {
                    let px = Double(lx + r.rect.x) + 0.5
                    let di = distance(px, py, boxes[i])
                    for j in rivals where distance(px, py, boxes[j]) < di + gap {
                        r.bits[ly * r.rect.w + lx] = false
                        break
                    }
                }
            }
            updates.append((i, r.count > 0 ? r : nil))
        }
        for (i, r) in updates {
            out[i].region = r
            out[i].layoutRect = r?.boundingBox ?? out[i].textBox
        }
    }

    static func shares(_ a: RegionMask, _ b: RegionMask) -> Bool {
        let both = a.rect.intersection(b.rect)
        guard !both.isEmpty else { return false }
        for y in both.y..<both.maxY {
            for x in both.x..<both.maxX where a.get(x, y) && b.get(x, y) { return true }
        }
        return false
    }

    /// 점에서 사각형까지 거리(안이면 0)
    static func distance(_ px: Double, _ py: Double, _ r: IRect) -> Double {
        let dx = max(Double(r.x) - px, 0, px - Double(r.maxX))
        let dy = max(Double(r.y) - py, 0, py - Double(r.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - 테두리 없는 글자

    /// 바탕이 고른 곳의 글자: 상자 근처의 글자 크기 잉크 덩어리만 지운다(옆의 그림 선은 남긴다)
    static func openText(_ bmp: Bitmap, box: IRect, bg: RGBA) -> Refined? {
        let short = Double(min(box.w, box.h))
        let pad = Int(short * 0.3) + 6
        let search = box.expanded(by: pad).clamped(width: bmp.width, height: bmp.height)
        let ink = inkMask(bmp, in: search, background: bg)
        let comps = maskComponents(ink)
        let inside = comps.filter { !touchesBorder($0.box, search) && box.coverage(of: $0.box) > 0.5 }
        guard !inside.isEmpty else { return nil }
        let typical = upperMedian(inside.map { Double(max($0.box.w, $0.box.h)) }) ?? short
        let near = box.expanded(by: pad / 2)
        var text = RegionMask(rect: search)
        for c in comps where !touchesBorder(c.box, search) && Double(max(c.box.w, c.box.h)) <= typical * 3
            && near.coverage(of: c.box) > 0.5 {
            for p in c.pixels { text.bits[p] = true }
        }
        // 상자 안 잉크를 거의 다 잡았어야 한다(그림과 엉킨 글자면 라벨로 덮는 편이 낫다)
        var inkIn = 0, keptIn = 0
        for y in box.y..<box.maxY {
            for x in box.x..<box.maxX where ink.get(x, y) {
                inkIn += 1
                if text.get(x, y) { keptIn += 1 }
            }
        }
        guard inkIn > 0, keptIn * 10 >= inkIn * 7 else { return nil }
        let textBox = text.boundingBox
        let erase = text.dilated(2)
        // 색·결은 잉크가 아니고 글자에서 조금 떨어진 곳에서만 가져온다
        var source = RegionMask(rect: search)
        let halo = text.dilated(4)
        for i in source.bits.indices { source.bits[i] = !ink.bits[i] && !halo.bits[i] }
        let layout = grow(bmp, textBox.union(box), bg: bg, ignore: text)
        return Refined(mode: .clean, textBox: textBox, eraseMask: erase, eraseSource: source, patch: nil,
                       background: bg, ink: maskColor(bmp, text, background: bg), region: nil, layoutRect: layout,
                       glyphSize: glyphSize(text, fallback: typical), closedBubble: false)
    }

    /// 번역(가로쓰기)이 들어갈 자리를 바탕이 이어지는 만큼 넓힌다. 세로쓰기 원문이면 옆으로 먼저.
    static func grow(_ bmp: Bitmap, _ rect: IRect, bg: RGBA, ignore: RegionMask?) -> IRect {
        var r = rect.clamped(width: bmp.width, height: bmp.height)
        let maxArea = rect.area * 2 + 400
        func clean(_ strip: IRect) -> Bool {
            guard strip.x >= 0, strip.y >= 0, strip.maxX <= bmp.width, strip.maxY <= bmp.height, !strip.isEmpty else {
                return false
            }
            var bad = 0
            for y in strip.y..<strip.maxY {
                for x in strip.x..<strip.maxX where !(ignore?.get(x, y) ?? false)
                    && bmp.color(x, y).distance2(bg) > backgroundTolerance {
                    bad += 1
                }
            }
            return bad * 50 <= strip.area
        }
        let step = 2
        var growX = true, growY = true
        while r.area < maxArea && (growX || growY) {
            if growX && Double(r.w) < Double(r.h) * 1.3 {
                let left = IRect(x: r.x - step, y: r.y, w: step, h: r.h)
                let right = IRect(x: r.maxX, y: r.y, w: step, h: r.h)
                if clean(left) && clean(right) {
                    r = r.expanded(dx: step, dy: 0)
                    continue
                }
                growX = false
            } else {
                growX = false
            }
            if growY {
                let top = IRect(x: r.x, y: r.y - step, w: r.w, h: step)
                let bottom = IRect(x: r.x, y: r.maxY, w: r.w, h: step)
                if clean(top) && clean(bottom) {
                    r = r.expanded(dx: 0, dy: step)
                } else {
                    growY = false
                }
            }
        }
        return r
    }

    // MARK: - 라벨·효과음

    // MARK: - 그림 위 글자

    /// 4비트씩 묶은 색 칸
    @inline(__always) static func colorBin(_ c: RGBA) -> Int { Int(c.r >> 4) << 8 | Int(c.g >> 4) << 4 | Int(c.b >> 4) }

    static func binCenter(_ b: Int) -> RGBA {
        RGBA(UInt8((b >> 8) * 16 + 8), UInt8(((b >> 4) & 15) * 16 + 8), UInt8((b & 15) * 16 + 8))
    }

    /// 말풍선 없이 그림 위에 쓴 글자: 글자 상자 안에는 흔한데 둘레(바깥 띠)에는 드문 색 = 글자·테두리 색.
    /// Claude가 본 글자색·테두리색이 있으면 그 근처 색도 글자로 친다. 못 가려내면 nil(라벨로 덮는다).
    static func artText(_ bmp: Bitmap, block: PageBlock, box: IRect) -> Refined? {
        let short = Double(min(box.w, box.h))
        let inner = box.expanded(by: max(4, Int(short * 0.12))).clamped(width: bmp.width, height: bmp.height)
        let outer = inner.expanded(by: max(10, Int(short * 0.3))).clamped(width: bmp.width, height: bmp.height)
        var hin = [Int](repeating: 0, count: 4096), hring = [Int](repeating: 0, count: 4096)
        var nin = 0, nring = 0
        for y in outer.y..<outer.maxY {
            for x in outer.x..<outer.maxX {
                let b = colorBin(bmp.color(x, y))
                if inner.contains(x, y) {
                    hin[b] += 1
                    nin += 1
                } else {
                    hring[b] += 1
                    nring += 1
                }
            }
        }
        guard nin > 0, nring > 0 else { return nil }
        let hints = [block.fill, block.outline].compactMap { $0 }
        // 둘레에 "비슷한" 색이 얼마나 있나(이웃 칸까지 — 그러데이션으로 칸이 조금 달라도 같은 색으로)
        var ringNear = [Int](repeating: 0, count: 4096)
        for b in 0..<4096 where hin[b] > 0 {
            let r0 = b >> 8, g0 = (b >> 4) & 15, b0 = b & 15
            var n = 0
            for r in max(0, r0 - 1)...min(15, r0 + 1) {
                for g in max(0, g0 - 1)...min(15, g0 + 1) {
                    for bb in max(0, b0 - 1)...min(15, b0 + 1) { n += hring[r << 8 | g << 4 | bb] }
                }
            }
            ringNear[b] = n
        }
        var isText = [Bool](repeating: false, count: 4096)
        var any = false
        for b in 0..<4096 where hin[b] > 0 {
            let pin = Double(hin[b]) / Double(nin), pr = Double(ringNear[b]) / Double(nring)
            // 글자색은 둘레에 거의 없다(그림 색은 둘레에도 있다)
            var ok = pin >= 0.003 && (pr <= 0.004 || pin >= 10 * pr)
            if !ok, pin >= 0.001, pin >= 1.5 * pr + 0.0002,
               hints.contains(where: { $0.distance2(binCenter(b)) <= 56 * 56 }) {
                ok = true
            }
            isText[b] = ok
            any = any || ok
        }
        guard any else { return nil }
        var mask = RegionMask(rect: inner)
        for ly in 0..<inner.h {
            for lx in 0..<inner.w where isText[colorBin(bmp.color(lx + inner.x, ly + inner.y))] {
                mask.bits[ly * inner.w + lx] = true
            }
        }
        // 작은 점(그림의 반짝임 등) 빼기
        let minComp = max(6, Int(short * short / 2500))
        for c in maskComponents(mask) where c.pixels.count < minComp {
            for p in c.pixels { mask.bits[p] = false }
        }
        let total = mask.count
        guard total >= max(30, inner.area / 60), total * 100 <= inner.area * 85 else { return nil }
        let mbox = mask.boundingBox
        guard box.intersection(mbox).area * 4 >= box.area else { return nil }

        // 글자색은 획 안쪽, 테두리색은 가장자리 띠에서
        let core = mask.eroded(2)
        func dominant(_ m: RegionMask, where keep: (Int, Int) -> Bool) -> RGBA? {
            var hist = [Int](repeating: 0, count: 4096)
            var sums = [(Int, Int, Int)](repeating: (0, 0, 0), count: 4096)
            var n = 0
            for ly in 0..<m.rect.h {
                for lx in 0..<m.rect.w where m.bits[ly * m.rect.w + lx] && keep(lx + m.rect.x, ly + m.rect.y) {
                    let c = bmp.color(lx + m.rect.x, ly + m.rect.y)
                    let b = colorBin(c)
                    hist[b] += 1
                    sums[b].0 += Int(c.r)
                    sums[b].1 += Int(c.g)
                    sums[b].2 += Int(c.b)
                    n += 1
                }
            }
            guard n > 0, let best = hist.indices.max(by: { hist[$0] < hist[$1] }), hist[best] > 0 else { return nil }
            let k = hist[best]
            return RGBA(UInt8(sums[best].0 / k), UInt8(sums[best].1 / k), UInt8(sums[best].2 / k))
        }
        let fill = block.fill ?? dominant(core.count > 0 ? core : mask) { _, _ in true }
            ?? dominant(mask) { _, _ in true } ?? .black
        var outline = block.outline ?? dominant(mask) { x, y in !core.get(x, y) }
        if let o = outline, o.distance2(fill) < 80 * 80 { outline = nil }

        // 글자 크기: 글자색 획 덩어리의 크기(테두리로 이어진 줄 전체가 아니라)
        var fillMask = RegionMask(rect: inner)
        for ly in 0..<inner.h {
            for lx in 0..<inner.w where mask.bits[ly * inner.w + lx]
                && bmp.color(lx + inner.x, ly + inner.y).distance2(fill) <= 70 * 70 {
                fillMask.bits[ly * inner.w + lx] = true
            }
        }
        var glyph = upperMedian(maskComponents(fillMask).filter { $0.pixels.count >= minComp }
            .map { Double(max($0.box.w, $0.box.h)) }) ?? short * 0.4
        glyph = min(max(glyph, short * 0.25), max(short, 12))
        let vertical = block.vertical || Double(box.h) > Double(box.w) * 1.6
        let ringAvg = Refiner.ringAverage(bmp, inner: inner, outer: outer)
        // 글자 가장자리의 번진 픽셀(JPEG 테두리 번짐 포함)까지 2px 넓혀 지운다 — 밑 그림은 되살리므로 조금 넓어도 괜찮다
        return Refined(mode: .art, textBox: mbox, eraseMask: mask.dilated(2), eraseSource: nil, patch: nil,
                       background: ringAvg, ink: fill, region: nil, layoutRect: box.union(mbox),
                       glyphSize: glyph, closedBubble: false, outline: outline, vertical: vertical)
    }

    /// 바깥 띠의 평균색
    static func ringAverage(_ bmp: Bitmap, inner: IRect, outer: IRect) -> RGBA {
        var sr = 0, sg = 0, sb = 0, n = 0
        for y in outer.y..<outer.maxY {
            for x in outer.x..<outer.maxX where !inner.contains(x, y) {
                let c = bmp.color(x, y)
                sr += Int(c.r)
                sg += Int(c.g)
                sb += Int(c.b)
                n += 1
            }
        }
        return n > 0 ? RGBA(UInt8(sr / n), UInt8(sg / n), UInt8(sb / n)) : .white
    }

    static func label(_ bmp: Bitmap, box: IRect) -> Refined {
        let rect = box.expanded(by: 3).clamped(width: bmp.width, height: bmp.height)
        let patch = BorderPatch(bmp, rect: rect)
        let avg = patch.average
        // 글자색: 덮을 면과 많이 다른 픽셀들의 평균. 대비가 약하면 흑/백
        var sr = 0, sg = 0, sb = 0, n = 0
        for y in box.y..<box.maxY {
            for x in box.x..<box.maxX {
                let c = bmp.color(x, y)
                if c.distance2(patch.color(x, y)) > inkThreshold {
                    sr += Int(c.r)
                    sg += Int(c.g)
                    sb += Int(c.b)
                    n += 1
                }
            }
        }
        var ink = n > 0 ? RGBA(UInt8(sr / n), UInt8(sg / n), UInt8(sb / n)) : (avg.luminance > 128 ? .black : .white)
        if abs(ink.luminance - avg.luminance) < 100 { ink = avg.luminance > 128 ? .black : .white }
        return Refined(mode: .label, textBox: box, eraseMask: nil, eraseSource: nil, patch: patch,
                       background: avg, ink: ink, region: nil, layoutRect: rect,
                       glyphSize: Double(min(box.w, box.h)), closedBubble: false)
    }

    static func overlay(_ bmp: Bitmap, box: IRect) -> Refined {
        let avg = bmp.average(box)
        return Refined(mode: .overlay, textBox: box, eraseMask: nil, eraseSource: nil, patch: nil,
                       background: avg, ink: avg.luminance > 110 ? .black : .white, region: nil, layoutRect: box,
                       glyphSize: Double(min(box.w, box.h)), closedBubble: false)
    }

    // MARK: - 도구

    /// 상자 안에서 가장 많은 색(4비트씩 묶음)과 그 색에 가까운 픽셀 비율
    static func dominantColor(_ bmp: Bitmap, _ box: IRect) -> (RGBA, Double) {
        var hist = [Int](repeating: 0, count: 4096)
        for y in box.y..<box.maxY {
            for x in box.x..<box.maxX {
                let c = bmp.color(x, y)
                hist[Int(c.r >> 4) << 8 | Int(c.g >> 4) << 4 | Int(c.b >> 4)] += 1
            }
        }
        let best = hist.indices.max { hist[$0] < hist[$1] } ?? 4095
        var sr = 0, sg = 0, sb = 0, n = 0
        for y in box.y..<box.maxY {
            for x in box.x..<box.maxX {
                let c = bmp.color(x, y)
                if Int(c.r >> 4) << 8 | Int(c.g >> 4) << 4 | Int(c.b >> 4) == best {
                    sr += Int(c.r)
                    sg += Int(c.g)
                    sb += Int(c.b)
                    n += 1
                }
            }
        }
        let bg = n > 0 ? RGBA(UInt8(sr / n), UInt8(sg / n), UInt8(sb / n)) : .white
        var close = 0
        for y in box.y..<box.maxY {
            for x in box.x..<box.maxX where bmp.color(x, y).distance2(bg) <= backgroundTolerance { close += 1 }
        }
        return (bg, Double(close) / Double(max(1, box.area)))
    }

    /// 원문 글자색: 바탕과 가장 먼(획 가운데) 픽셀 30%의 평균. 스캔본은 획 가장자리가 흐려서 전체 평균은 회색이 된다.
    static func maskColor(_ bmp: Bitmap, _ m: RegionMask, background: RGBA) -> RGBA {
        var samples: [(Int, RGBA)] = []
        for ly in 0..<m.rect.h {
            for lx in 0..<m.rect.w where m.bits[ly * m.rect.w + lx] {
                let c = bmp.color(lx + m.rect.x, ly + m.rect.y)
                let d = c.distance2(background)
                if d > inkThreshold { samples.append((d, c)) }
            }
        }
        if samples.isEmpty { return background.luminance > 128 ? .black : .white }
        samples.sort { $0.0 > $1.0 }
        let top = samples.prefix(max(1, samples.count * 3 / 10))
        var sr = 0, sg = 0, sb = 0
        for (_, c) in top {
            sr += Int(c.r)
            sg += Int(c.g)
            sb += Int(c.b)
        }
        let n = top.count
        return RGBA(UInt8(sr / n), UInt8(sg / n), UInt8(sb / n))
    }

    /// 바탕과 확실히 다른 픽셀
    static func inkMask(_ bmp: Bitmap, in r: IRect, background: RGBA) -> RegionMask {
        var m = RegionMask(rect: r)
        for ly in 0..<r.h {
            for lx in 0..<r.w where bmp.color(lx + r.x, ly + r.y).distance2(background) > inkThreshold {
                m.bits[ly * r.w + lx] = true
            }
        }
        return m
    }

    /// 마스크의 구멍(바깥과 이어지지 않은 빈 칸)까지 채운 것
    static func fillHoles(_ m: RegionMask) -> RegionMask {
        let r = m.rect
        var outside = [Bool](repeating: false, count: r.area)
        var stack: [Int] = []
        func push(_ i: Int) {
            if !m.bits[i] && !outside[i] {
                outside[i] = true
                stack.append(i)
            }
        }
        for lx in 0..<r.w {
            push(lx)
            push((r.h - 1) * r.w + lx)
        }
        for ly in 0..<r.h {
            push(ly * r.w)
            push(ly * r.w + r.w - 1)
        }
        while let i = stack.popLast() {
            let lx = i % r.w, ly = i / r.w
            if lx > 0 { push(i - 1) }
            if lx < r.w - 1 { push(i + 1) }
            if ly > 0 { push(i - r.w) }
            if ly < r.h - 1 { push(i + r.w) }
        }
        var out = m
        for i in out.bits.indices where !outside[i] { out.bits[i] = true }
        return out
    }

    struct Component {
        var box: IRect
        /// 마스크 영역 기준 인덱스
        var pixels: [Int]
    }

    /// 켜진 칸의 연결 덩어리(8방향)
    static func maskComponents(_ m: RegionMask) -> [Component] {
        let r = m.rect
        var seen = [Bool](repeating: false, count: r.area)
        var out: [Component] = []
        var stack: [Int] = []
        for start in 0..<r.area where m.bits[start] && !seen[start] {
            seen[start] = true
            stack.append(start)
            var pixels: [Int] = []
            var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
            while let i = stack.popLast() {
                pixels.append(i)
                let lx = i % r.w, ly = i / r.w
                x0 = min(x0, lx)
                x1 = max(x1, lx)
                y0 = min(y0, ly)
                y1 = max(y1, ly)
                for dy in -1...1 {
                    let ny = ly + dy
                    guard ny >= 0, ny < r.h else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = lx + dx
                        guard nx >= 0, nx < r.w else { continue }
                        let n = ny * r.w + nx
                        if m.bits[n] && !seen[n] {
                            seen[n] = true
                            stack.append(n)
                        }
                    }
                }
            }
            out.append(Component(box: IRect(x: r.x + x0, y: r.y + y0, w: x1 - x0 + 1, h: y1 - y0 + 1), pixels: pixels))
        }
        return out
    }

    static func touchesBorder(_ b: IRect, _ r: IRect) -> Bool {
        b.x <= r.x || b.y <= r.y || b.maxX >= r.maxX || b.maxY >= r.maxY
    }

    /// 큰 쪽 절반의 중앙값(한자의 떨어진 획 조각·후리가나·점은 작다)
    static func upperMedian(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let upper = values.sorted().suffix(max(1, values.count / 2))
        return upper[upper.startIndex + upper.count / 2]
    }

    /// 원문 글자 하나의 크기
    static func glyphSize(_ mask: RegionMask, fallback: Double) -> Double {
        upperMedian(maskComponents(mask).map { Double(max($0.box.w, $0.box.h)) }) ?? fallback
    }
}
