import Foundation

/// AI가 알려 준 글자 상자는 자주 어긋난다(옆 열로 밀리거나, 글자 일부만 덮거나, 열 하나를 빠뜨리거나).
/// 테두리를 두른 그림 위 글자는 "글자색 덩어리를 테두리색이 감싼 것"이라 그림에서 바로 찾을 수 있으니,
/// 상자 근처의 그런 덩어리(글자 조각)를 모아 상자를 실제 글자 범위로 옮긴다.
public enum Locator {
    /// 글자 조각 하나(글자색 덩어리, 둘레가 테두리색)
    struct Piece {
        var box: IRect
        var count: Int
        /// 획이 굵다(1px 깎아도 남는다) — 그림의 가는 선과 구별
        var thick: Bool
        /// 둘레 2~3px 중 테두리색 비율
        var halo: Double = 0
        var owner = -1
    }

    /// 상자를 실제 글자에 맞춘 결과
    public struct Snap: Sendable, Equatable {
        public var box: IRect
        /// 글자 조각을 찾아 옮겼는지(테두리 글자가 아니거나 못 찾으면 false — 상자 그대로)
        public var located: Bool
        /// 찾은 글자 조각 크기(글자 하나 크기 어림, 못 찾으면 0)
        public var glyph: Double
    }

    /// 페이지의 덩어리 상자들을 실제 글자에 맞춘다. 맞출 수 없는 것은 그대로 둔다.
    public static func snap(_ bmp: Bitmap, blocks: [PageBlock]) -> [Snap] {
        var out = blocks.map { Snap(box: $0.box.clamped(width: bmp.width, height: bmp.height), located: false, glyph: 0) }
        // 글자색·테두리색이 같은 덩어리끼리 한 번에(가까운 덩어리들이 글자 조각을 서로 나눠 갖게)
        var groups: [(fill: RGBA, outline: RGBA, members: [Int])] = []
        for (i, b) in blocks.enumerated() where b.kind != .sfx {
            let box = out[i].box
            // 테두리 없는 글자(말풍선 안 보통 글자 등)는 그대로
            guard box.w >= 4, box.h >= 4, let fh = b.fill, var oh = b.outline else { continue }
            // 테두리색을 글자색과 같다고 했으면(잘못 본 것) 검정 글자엔 흰 테두리, 밝은 글자엔 검정 테두리로 본다
            if oh.distance2(fh) < 100 * 100 { oh = fh.luminance < 128 ? .white : .black }
            // 상자가 글자 사이 빈 곳을 가리켰어도 색은 찾게 조금 넓혀서 본다
            let look = box.expanded(by: max(10, min(box.w, box.h) / 2))
            guard let f = actualColor(bmp, near: fh, in: look), let o = actualColor(bmp, near: oh, in: look),
                  f.distance2(o) >= 100 * 100,
                  // "테두리색"이 상자 둘레 바탕 그대로면 말풍선·빈 바탕 위 보통 글자다(테두리 글자로 보지 않는다)
                  ringShare(bmp, box: box, color: o) < 0.7 else { continue }
            if let k = groups.firstIndex(where: { $0.fill.distance2(f) <= 48 * 48 && $0.outline.distance2(o) <= 48 * 48 }) {
                groups[k].members.append(i)
            } else {
                groups.append((f, o, [i]))
            }
        }
        for g in groups {
            let boxes = g.members.map { out[$0].box }
            // 찾을 범위: 상자 둘레. 글자가 그 끝까지 이어지면(상자가 글자 일부만 가리켰으면) 넓혀서 다시
            var grow = 1
            while true {
                var area = IRect(x: 0, y: 0, w: 0, h: 0)
                for b in boxes {
                    let w = b.expanded(by: max(80, max(b.w, b.h)) * grow).clamped(width: bmp.width, height: bmp.height)
                    area = area.isEmpty ? w : area.union(w)
                }
                let found = locate(bmp, blocks: blocks, members: g.members, boxes: boxes, area: area, fill: g.fill,
                                   outline: g.outline)
                if found.touches, grow < 4, area != bmp.bounds {
                    grow *= 2
                    continue
                }
                for (i, snap) in found.snaps { out[i] = snap }
                break
            }
        }
        return out
    }

    /// 한 색 무리(같은 글자색·테두리색 덩어리들)의 상자를 범위 안의 글자 조각으로 맞춘다.
    /// touches: 가진 조각이 범위 끝에 닿았다(범위를 넓혀 다시 봐야 한다)
    static func locate(_ bmp: Bitmap, blocks: [PageBlock], members: [Int], boxes: [IRect], area: IRect, fill: RGBA,
                       outline: RGBA) -> (snaps: [Int: Snap], touches: Bool) {
        var pieces = findPieces(bmp, in: area, fill: fill, outline: outline)
        let vertical = members.indices.map { blocks[members[$0]].vertical || boxes[$0].h > boxes[$0].w * 2 }
        let seeds = pieces.filter { p in boxes.contains { $0.intersection(p.box).area > 0 } }
        guard let piece = Refiner.upperMedian(seeds.map { Double(max($0.box.w, $0.box.h)) }), piece >= 4 else {
            return ([:], false)
        }
        // 글자 하나 크기: 획이 떨어진 글자(가나·한자)는 조각이 글자보다 작으니 열 폭(가로쓰기면 줄 높이)으로 본다
        let typical = max(piece, lineThickness(seeds, vertical: vertical.filter { $0 }.count * 2 >= vertical.count) ?? 0)
        // 글자 크기를 크게 넘는 덩어리(그림의 면)와 가는 선(그림 윤곽)은 글자 조각이 아니다.
        // 줄표(——)처럼 한쪽으로만 긴 것은 괜찮다
        pieces = pieces.filter { p in
            let long = Double(max(p.box.w, p.box.h)), short = Double(min(p.box.w, p.box.h))
            let sized = long <= typical * 2.2 || (short <= typical * 0.5 && long <= typical * 6)
            // 가는 것은 줄표처럼 곧고 긴 것만(이을 때 열·줄에 나란한지 한 번 더 본다)
            return sized && (typical < 24 || p.thick || long >= short * 4)
        }
        // 옆으로 넓힐 수 있는 거리: 글자 1.5개. 원문 글자 수에 비해 상자가 너무 작으면(글자 일부만 가리켰으면) 더
        let sides = members.indices.map { k -> Int in
            let expected = Double(blocks[members[k]].chars) * (typical * 1.15) * (typical * 1.15)
            let short = max(1.0, (expected / Double(max(1, boxes[k].area))).squareRoot())
            return Int(typical * 1.5 * min(4, short))
        }
        assign(&pieces, boxes: boxes, vertical: vertical, sides: sides, typical: typical)
        let pad = max(2, Int((typical * 0.12).rounded()))
        var snaps: [Int: Snap] = [:]
        var touches = false
        for (k, i) in members.enumerated() {
            let mine = pieces.filter { $0.owner == k }
            guard !mine.isEmpty else { continue }
            var u = mine[0].box
            for p in mine.dropFirst() { u = u.union(p.box) }
            if (u.x <= area.x && area.x > 0) || (u.y <= area.y && area.y > 0)
                || (u.maxX >= area.maxX && area.maxX < bmp.width) || (u.maxY >= area.maxY && area.maxY < bmp.height) {
                touches = true
            }
            let snapped = u.expanded(by: pad).clamped(width: bmp.width, height: bmp.height)
            // 상자에 비해 아주 작은 것만 찾았으면(AI가 말한 색이 글자색이 아니고 우연히 비슷한 점만 찾았으면) 옮기지 않는다
            if snapped.area * 4 < boxes[k].area { continue }
            // 원문 글자 수로 본 넓이보다 터무니없이 크면(그림까지 딸려 왔으면) 옮기지 않는다
            let chars = blocks[i].chars
            if chars > 0 {
                let expected = Double(chars) * (typical * 1.25) * (typical * 1.25)
                if Double(snapped.area) > expected * 3, snapped.area > boxes[k].area * 2 { continue }
            }
            snaps[i] = Snap(box: snapped, located: true, glyph: typical)
        }
        return (snaps, touches)
    }

    /// 상자 바로 바깥 띠에서 그 색에 아주 가까운 픽셀 비율
    static func ringShare(_ bmp: Bitmap, box: IRect, color: RGBA) -> Double {
        let ring = box.expanded(by: max(6, min(box.w, box.h) / 4)).clamped(width: bmp.width, height: bmp.height)
        var n = 0, near = 0
        for y in ring.y..<ring.maxY {
            for x in ring.x..<ring.maxX where !box.contains(x, y) {
                n += 1
                if bmp.color(x, y).distance2(color) <= 36 * 36 { near += 1 }
            }
        }
        return n > 0 ? Double(near) / Double(n) : 0
    }

    /// 상자 안에서 알려 준 색에 가까운 실제 픽셀들의 대표색(AI가 말한 색은 대략이라). 그런 픽셀이 거의 없으면 nil
    static func actualColor(_ bmp: Bitmap, near hint: RGBA, in box: IRect) -> RGBA? {
        let r = box.clamped(width: bmp.width, height: bmp.height)
        guard !r.isEmpty else { return nil }
        var hist = [Int](repeating: 0, count: 4096)
        var sums = [(Int, Int, Int)](repeating: (0, 0, 0), count: 4096)
        var n = 0
        for y in r.y..<r.maxY {
            for x in r.x..<r.maxX {
                let c = bmp.color(x, y)
                guard c.distance2(hint) <= 90 * 90 else { continue }
                let b = Refiner.colorBin(c)
                hist[b] += 1
                sums[b].0 += Int(c.r)
                sums[b].1 += Int(c.g)
                sums[b].2 += Int(c.b)
                n += 1
            }
        }
        guard n >= max(30, r.area / 200), let best = hist.indices.max(by: { hist[$0] < hist[$1] }) else { return nil }
        let k = hist[best]
        return RGBA(UInt8(sums[best].0 / k), UInt8(sums[best].1 / k), UInt8(sums[best].2 / k))
    }

    /// 글자색 덩어리 중 바로 바깥(2~3px)이 대부분(70% 이상) 테두리색인 것
    static func findPieces(_ bmp: Bitmap, in r: IRect, fill: RGBA, outline: RGBA) -> [Piece] {
        guard !r.isEmpty else { return [] }
        let n = r.area
        var isFill = RegionMask(rect: r)
        var isOutline = [Bool](repeating: false, count: n)
        for ly in 0..<r.h {
            for lx in 0..<r.w {
                let c = bmp.color(lx + r.x, ly + r.y)
                let i = ly * r.w + lx
                if c.distance2(fill) <= 80 * 80 {
                    isFill.bits[i] = true
                } else if c.distance2(outline) <= 80 * 80 {
                    isOutline[i] = true
                }
            }
        }
        let comps = Refiner.maskComponents(isFill).filter { $0.pixels.count >= 8 }
        guard !comps.isEmpty else { return [] }
        // 덩어리마다 둘레 2~3px 띠: 가장 가까운 덩어리 번호를 3px까지 퍼뜨린다
        var label = [Int32](repeating: -1, count: n)
        var dist = [UInt8](repeating: 255, count: n)
        var frontier: [Int] = []
        for (k, c) in comps.enumerated() {
            for p in c.pixels {
                label[p] = Int32(k)
                dist[p] = 0
                frontier.append(p)
            }
        }
        var ringAll = [Int](repeating: 0, count: comps.count), ringOut = [Int](repeating: 0, count: comps.count)
        for d in 1...3 {
            var next: [Int] = []
            for p in frontier {
                let lx = p % r.w, ly = p / r.w
                for dy in -1...1 {
                    let ny = ly + dy
                    guard ny >= 0, ny < r.h else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = lx + dx
                        guard nx >= 0, nx < r.w else { continue }
                        let q = ny * r.w + nx
                        guard dist[q] == 255, !isFill.bits[q] else { continue }
                        dist[q] = UInt8(d)
                        label[q] = label[p]
                        next.append(q)
                        // 바로 옆 한 줄은 글자색과 섞인 번진 픽셀이라 건너뛴다
                        if d >= 2 {
                            let k = Int(label[p])
                            ringAll[k] += 1
                            if isOutline[q] { ringOut[k] += 1 }
                        }
                    }
                }
            }
            frontier = next
        }
        var out: [Piece] = []
        for (k, c) in comps.enumerated() where ringAll[k] > 0 && ringOut[k] * 100 >= ringAll[k] * 70 {
            // 굵기: 상하좌우가 모두 글자색인 픽셀이 조금이라도 있으면 1px 선이 아니다
            var core = 0
            for p in c.pixels {
                let lx = p % r.w, ly = p / r.w
                if lx > 0, ly > 0, lx < r.w - 1, ly < r.h - 1, isFill.bits[p - 1], isFill.bits[p + 1],
                   isFill.bits[p - r.w], isFill.bits[p + r.w] {
                    core += 1
                }
            }
            out.append(Piece(box: c.box, count: c.pixels.count, thick: core * 5 >= c.pixels.count,
                             halo: Double(ringOut[k]) / Double(ringAll[k])))
        }
        return out
    }

    /// 열 폭(세로쓰기) 또는 줄 높이(가로쓰기)의 중앙값: 조각들을 그 축에 비춰 겹치는 것끼리 묶는다
    static func lineThickness(_ pieces: [Piece], vertical: Bool) -> Double? {
        let spans = pieces.map { vertical ? ($0.box.x, $0.box.maxX) : ($0.box.y, $0.box.maxY) }.sorted { $0.0 < $1.0 }
        var lines: [(Int, Int, Int)] = []
        for (a, b) in spans {
            if let last = lines.last, a < last.1 {
                lines[lines.count - 1] = (last.0, max(last.1, b), last.2 + 1)
            } else {
                lines.append((a, b, 1))
            }
        }
        let widths = lines.filter { $0.2 >= 3 }.map { Double($0.1 - $0.0) }.sorted()
        guard !widths.isEmpty else { return nil }
        return widths[widths.count / 2]
    }

    /// 두 상자 사이 거리(겹치면 0)
    static func gap(_ a: IRect, _ b: IRect) -> Int {
        let dx = max(0, max(a.x - b.maxX, b.x - a.maxX))
        let dy = max(0, max(a.y - b.maxY, b.y - a.maxY))
        return max(dx, dy)
    }

    /// 글자 조각을 덩어리에 나눠 준다: 상자와 겹치는 조각은 가장 많이 겹치는 덩어리로, 그 뒤로는 가까운 조각을
    /// 이어 붙인다(열·줄을 따라가면 끝까지, 옆으로는 원래 상자에서 sides 거리까지 — 그림 선까지 번지지 않게)
    static func assign(_ pieces: inout [Piece], boxes: [IRect], vertical: [Bool], sides: [Int], typical: Double) {
        guard !pieces.isEmpty else { return }
        // 가는 조각은 상자 안에 있어도 바로 갖지 않는다(상자를 지나가는 그림 선일 수 있다 — 줄표는 아래에서 열을 따라 붙는다)
        // 작은 조각(점·획 끝)도 바로 갖지 않는다 — 열을 따라 이을 때 같은 열이면 붙는다
        for i in pieces.indices where (pieces[i].thick || typical < 24)
            && Double(max(pieces[i].box.w, pieces[i].box.h)) >= typical * 0.4 {
            var best = 0, who = -1
            for (k, b) in boxes.enumerated() {
                let a = b.expanded(by: 2).intersection(pieces[i].box).area
                if a > best {
                    best = a
                    who = k
                }
            }
            pieces[i].owner = who
        }
        func allowed(_ p: Piece, _ k: Int) -> Bool {
            let b = boxes[k], side = sides[k]
            if vertical[k] { return p.box.x >= b.x - side && p.box.maxX <= b.maxX + side }
            return p.box.y >= b.y - side && p.box.maxY <= b.maxY + side
        }
        // 가는 조각(줄표)은 이미 가진 조각과 같은 열(가로쓰기면 같은 줄) 안에 있어야 한다 — 그림의 가는 선이 아니게
        func aligned(_ p: Piece, k: Int) -> Bool {
            // 그 열(줄)의 폭 = 이 조각과 겹치는, 이미 가진 굵은 조각들의 범위
            var lo = Int.max, hi = Int.min
            for q in pieces where q.owner == k && q.thick {
                let (a0, a1, b0, b1) = vertical[k] ? (p.box.x, p.box.maxX, q.box.x, q.box.maxX)
                    : (p.box.y, p.box.maxY, q.box.y, q.box.maxY)
                guard a0 < b1 && b0 < a1 else { continue }
                lo = min(lo, b0)
                hi = max(hi, b1)
            }
            guard lo < hi else { return false }
            return vertical[k] ? (p.box.x >= lo - 3 && p.box.maxX <= hi + 3) : (p.box.y >= lo - 3 && p.box.maxY <= hi + 3)
        }
        // 이미 가진 조각과 같은 열(가로쓰기면 같은 줄)에 걸치는가
        func inLine(_ p: Piece, k: Int) -> Bool {
            pieces.contains { q in
                guard q.owner == k else { return false }
                if vertical[k] { return p.box.x < q.box.maxX && q.box.x < p.box.maxX }
                return p.box.y < q.box.maxY && q.box.y < p.box.maxY
            }
        }
        // 아무 조각과도 겹치지 않는 상자는 가장 가까운 조각에서 시작한다(열 사이 빈 곳을 가리킨 상자)
        for k in boxes.indices where !pieces.contains(where: { $0.owner == k }) {
            var best = Int.max, pick = -1
            for (i, p) in pieces.enumerated() where p.owner < 0 {
                let d = gap(p.box, boxes[k])
                if d < best {
                    best = d
                    pick = i
                }
            }
            if pick >= 0, Double(best) <= typical * 0.8 { pieces[pick].owner = k }
        }
        // 같은 덩어리의 열 사이는 굵은 테두리 때문에 글자 하나만큼 벌어지기도 한다(다른 덩어리 사이는 보통 그보다 넓다)
        let reach = Int(typical * 1.25)
        var changed = true
        var rounds = 0
        while changed && rounds < 200 {
            changed = false
            rounds += 1
            var claims: [(Int, Int, Int)] = []
            for (i, p) in pieces.enumerated() where p.owner < 0 {
                var best = Int.max, who = -1
                for q in pieces where q.owner >= 0 {
                    let d = gap(p.box, q.box)
                    if d < best || (d == best && q.owner < who) {
                        best = d
                        who = q.owner
                    }
                }
                // 이어 붙이는 조각은 테두리가 또렷해야 하고(옷 주름 같은 그림 선은 둘레가 흐리다), 이미 가진 열(줄) 밖이면
                // 글자 조각만 한 크기여야 한다(새 열은 작은 점 하나로 시작하지 않는다)
                guard who >= 0, best <= reach, p.halo >= 0.75, allowed(p, who) else { continue }
                guard p.thick || typical < 24 || aligned(p, k: who) else { continue }
                guard Double(max(p.box.w, p.box.h)) >= typical * 0.4 || inLine(p, k: who) else { continue }
                claims.append((i, who, best))
            }
            for (i, who, _) in claims {
                pieces[i].owner = who
                changed = true
            }
        }
    }
}
