import Foundation

/// 지운 자리를 둘레 바탕색으로 채운다
public enum Inpaint {
    /// 양파 껍질 벗기듯 바깥 둘레부터 안쪽으로, 이미 아는 이웃 색의 평균으로 채운다.
    /// 말풍선 안 같은 평평한 바탕은 그대로, 사진의 완만한 그러데이션도 자연스럽게 이어진다.
    /// - source: 색을 가져와도 되는 픽셀(nil이면 마스크 밖 어디든)
    public static func fill(_ bmp: inout Bitmap, mask: RegionMask, source: RegionMask?, fallback: RGBA) {
        let area = mask.rect.expanded(by: 1).clamped(width: bmp.width, height: bmp.height)
        guard !area.isEmpty else { return }
        let w = area.w, h = area.h
        // 0 = 모름(칠할 곳), 1 = 앎(색을 가져올 수 있음), 2 = 상관없음
        var state = [UInt8](repeating: 2, count: w * h)
        var todo = 0
        for ly in 0..<h {
            for lx in 0..<w {
                let x = lx + area.x, y = ly + area.y
                if mask.get(x, y) {
                    state[ly * w + lx] = 0
                    todo += 1
                } else if source?.get(x, y) ?? true {
                    state[ly * w + lx] = 1
                }
            }
        }
        guard todo > 0 else { return }
        var frontier: [Int] = []
        var queued = [Bool](repeating: false, count: w * h)
        func hasKnown(_ i: Int) -> Bool {
            let lx = i % w, ly = i / w
            for dy in -1...1 {
                let ny = ly + dy
                guard ny >= 0, ny < h else { continue }
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = lx + dx
                    if nx >= 0, nx < w, state[ny * w + nx] == 1 { return true }
                }
            }
            return false
        }
        for i in 0..<(w * h) where state[i] == 0 && hasKnown(i) {
            frontier.append(i)
            queued[i] = true
        }
        var colors: [RGBA] = []
        while !frontier.isEmpty {
            colors.removeAll(keepingCapacity: true)
            for i in frontier {
                let lx = i % w, ly = i / w
                var sr = 0, sg = 0, sb = 0, n = 0
                for dy in -1...1 {
                    let ny = ly + dy
                    guard ny >= 0, ny < h else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = lx + dx
                        guard nx >= 0, nx < w, state[ny * w + nx] == 1 else { continue }
                        // 상하좌우 이웃을 대각선보다 두 배로 친다
                        let wt = (dx == 0 || dy == 0) ? 2 : 1
                        let c = bmp.color(nx + area.x, ny + area.y)
                        sr += Int(c.r) * wt
                        sg += Int(c.g) * wt
                        sb += Int(c.b) * wt
                        n += wt
                    }
                }
                colors.append(n > 0 ? RGBA(UInt8(sr / n), UInt8(sg / n), UInt8(sb / n)) : fallback)
            }
            var next: [Int] = []
            for (k, i) in frontier.enumerated() {
                bmp.set(i % w + area.x, i / w + area.y, colors[k])
                state[i] = 1
                todo -= 1
            }
            for i in frontier {
                let lx = i % w, ly = i / w
                for dy in -1...1 {
                    let ny = ly + dy
                    guard ny >= 0, ny < h else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = lx + dx
                        guard nx >= 0, nx < w else { continue }
                        let n = ny * w + nx
                        if state[n] == 0 && !queued[n] {
                            queued[n] = true
                            next.append(n)
                        }
                    }
                }
            }
            frontier = next
        }
        // 색을 가져올 곳과 이어지지 않은 칸
        if todo > 0 {
            for i in 0..<(w * h) where state[i] == 0 { bmp.set(i % w + area.x, i / w + area.y, fallback) }
        }
    }
}

extension Inpaint {
    /// 지운 자리에 둘레 바탕의 결(종이 질감·스캔 잡음)을 입힌다: 칸마다 가까운 깨끗한 바탕 픽셀 하나를 골라 옮긴다.
    /// 평평한 디지털 바탕이면 그대로이고, 스캔본이면 매끈한 얼룩 대신 종이 결이 이어진다.
    /// 바탕 픽셀을 못 찾은 칸은 fill이 채운 색을 둔다.
    public static func texture(_ bmp: inout Bitmap, mask: RegionMask, source: RegionMask) {
        let r = mask.rect
        for ly in 0..<r.h {
            for lx in 0..<r.w where mask.bits[ly * r.w + lx] {
                let x = lx + r.x, y = ly + r.y
                guard x >= 0, y >= 0, x < bmp.width, y < bmp.height else { continue }
                // 자리마다 같은 난수(같은 그림이면 늘 같은 결과)
                var seed = UInt32(truncatingIfNeeded: (x &* 73_856_093) ^ (y &* 19_349_663)) | 1
                func next(_ n: Int) -> Int {
                    seed ^= seed << 13
                    seed ^= seed >> 17
                    seed ^= seed << 5
                    return Int(seed % UInt32(n))
                }
                var found: RGBA?
                for radius in [6, 12, 24, 40] where found == nil {
                    for _ in 0..<10 {
                        let sx = x + next(2 * radius + 1) - radius, sy = y + next(2 * radius + 1) - radius
                        guard sx >= 0, sy >= 0, sx < bmp.width, sy < bmp.height,
                              source.get(sx, sy), !mask.get(sx, sy) else { continue }
                        found = bmp.color(sx, sy)
                        break
                    }
                }
                if let c = found { bmp.set(x, y, c) }
            }
        }
    }
}

/// 사각형 둘레 색으로 안쪽을 매끈하게 잇는 면(쿤스 패치). 사진·그림 위 글자를 덮을 때 쓴다.
public struct BorderPatch: Sendable {
    public let rect: IRect
    let top: [RGBA]
    let bottom: [RGBA]
    let left: [RGBA]
    let right: [RGBA]

    public init(_ bmp: Bitmap, rect r: IRect) {
        rect = r
        func sample(_ x: Int, _ y: Int, alongX: Bool, outward: Int) -> RGBA {
            // 둘레 바로 바깥 3줄 × 앞뒤 5칸에서 채널별 중앙값(지나가는 가는 선은 무시된다)
            var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
            for o in 1...3 {
                for s in -2...2 {
                    var px = alongX ? x + s : x + outward * o
                    var py = alongX ? y + outward * o : y + s
                    px = min(max(px, 0), bmp.width - 1)
                    py = min(max(py, 0), bmp.height - 1)
                    let c = bmp.color(px, py)
                    rs.append(c.r)
                    gs.append(c.g)
                    bs.append(c.b)
                }
            }
            rs.sort()
            gs.sort()
            bs.sort()
            return RGBA(rs[rs.count / 2], gs[gs.count / 2], bs[bs.count / 2])
        }
        func smooth(_ a: [RGBA]) -> [RGBA] {
            let rad = max(1, a.count / 16)
            return a.indices.map { i in
                var sr = 0, sg = 0, sb = 0, n = 0
                for j in max(0, i - rad)...min(a.count - 1, i + rad) {
                    sr += Int(a[j].r)
                    sg += Int(a[j].g)
                    sb += Int(a[j].b)
                    n += 1
                }
                return RGBA(UInt8(sr / n), UInt8(sg / n), UInt8(sb / n))
            }
        }
        let w = max(1, r.w), h = max(1, r.h)
        top = smooth((0..<w).map { sample(r.x + $0, r.y, alongX: true, outward: -1) })
        bottom = smooth((0..<w).map { sample(r.x + $0, r.maxY - 1, alongX: true, outward: 1) })
        left = smooth((0..<h).map { sample(r.x, r.y + $0, alongX: false, outward: -1) })
        right = smooth((0..<h).map { sample(r.maxX - 1, r.y + $0, alongX: false, outward: 1) })
    }

    /// 패치 안 한 점의 색
    public func color(_ x: Int, _ y: Int) -> RGBA {
        let w = top.count, h = left.count
        let i = min(max(x - rect.x, 0), w - 1), j = min(max(y - rect.y, 0), h - 1)
        let t = (Double(i) + 0.5) / Double(w), u = (Double(j) + 0.5) / Double(h)
        func ch(_ k: KeyPath<RGBA, UInt8>) -> UInt8 {
            func v(_ c: RGBA) -> Double { Double(c[keyPath: k]) }
            let p00 = (v(top[0]) + v(left[0])) / 2
            let p10 = (v(top[w - 1]) + v(right[0])) / 2
            let p01 = (v(bottom[0]) + v(left[h - 1])) / 2
            let p11 = (v(bottom[w - 1]) + v(right[h - 1])) / 2
            let c = (1 - u) * v(top[i]) + u * v(bottom[i]) + (1 - t) * v(left[j]) + t * v(right[j])
                - ((1 - t) * (1 - u) * p00 + t * (1 - u) * p10 + (1 - t) * u * p01 + t * u * p11)
            return UInt8(min(255, max(0, c.rounded())))
        }
        return RGBA(ch(\.r), ch(\.g), ch(\.b))
    }

    /// 둘레의 평균색
    public var average: RGBA {
        let all = top + bottom + left + right
        var sr = 0, sg = 0, sb = 0
        for c in all {
            sr += Int(c.r)
            sg += Int(c.g)
            sb += Int(c.b)
        }
        let n = max(1, all.count)
        return RGBA(UInt8(sr / n), UInt8(sg / n), UInt8(sb / n))
    }

    public func paint(_ bmp: inout Bitmap) {
        let r = rect.clamped(width: bmp.width, height: bmp.height)
        guard !r.isEmpty else { return }
        for y in r.y..<r.maxY {
            for x in r.x..<r.maxX { bmp.set(x, y, color(x, y)) }
        }
    }
}

extension Inpaint {
    /// 글자 밑 그림 되살리기(PatchMatch 인페인팅): 지운 자리를 둘레 그림에서 찾은 비슷한 조각들로 채운다.
    /// 거친 단계(작게 줄인 그림)부터 고운 단계로, 조각 찾기(전파 + 무작위 탐색) → 겹친 조각 투표를 되풀이한다.
    /// 지운 자리는 미리 fill로 대충 채워 둘 것(가장 거친 단계에서 다시 번짐으로 채운다).
    public static func patchMatch(_ bmp: inout Bitmap, mask: RegionMask, patch: Int = 7, iterations: Int = 5) {
        let hb = mask.boundingBox
        guard !hb.isEmpty, patch >= 3 else { return }
        let r = patch / 2
        let margin = max(4 * patch, Int(Double(max(hb.w, hb.h)) * 0.12))
        let area = hb.expanded(by: margin).clamped(width: bmp.width, height: bmp.height)
        let w0 = area.w, h0 = area.h
        guard w0 > 3 * patch, h0 > 3 * patch else { return }

        var base = PMLevel(w: w0, h: h0)
        for y in 0..<h0 {
            for x in 0..<w0 {
                let c = bmp.color(x + area.x, y + area.y)
                let i = (y * w0 + x) * 3
                base.px[i] = Float(c.r)
                base.px[i + 1] = Float(c.g)
                base.px[i + 2] = Float(c.b)
                base.hole[y * w0 + x] = mask.get(x + area.x, y + area.y)
            }
        }
        // 구멍이 두꺼우면 더 거친 단계부터(가장 거친 단계에서 구멍 두께가 조각 반지름 정도가 되게)
        let thick = base.holeThickness()
        var count = 1
        while count < 4 && (thick >> (count - 1)) > r && (w0 >> count) > 3 * patch && (h0 >> count) > 3 * patch {
            count += 1
        }
        var levels = [base]
        for _ in 1..<count { levels.append(levels[levels.count - 1].down()) }
        levels[count - 1].diffuse()
        for l in stride(from: count - 1, through: 0, by: -1) {
            if l < count - 1 { levels[l].initHole(from: levels[l + 1]) }
            // 조각은 가까운 데서만 가져온다(피부 옆 구멍엔 피부, 옷 옆엔 옷)
            let window = max(4 * patch, 3 * (thick >> l) + 2 * patch)
            levels[l].solve(patch: patch, iterations: iterations + (l > 0 ? 2 : 0), seed: UInt64(77 + l),
                            window: window, sharpen: l == 0)
        }
        let fine = levels[0]
        for y in 0..<h0 {
            for x in 0..<w0 where fine.hole[y * w0 + x] {
                let i = (y * w0 + x) * 3
                func c(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
                bmp.set(x + area.x, y + area.y, RGBA(c(fine.px[i]), c(fine.px[i + 1]), c(fine.px[i + 2])))
            }
        }
    }
}

/// PatchMatch 한 단계(실수 RGB + 구멍 표시)
struct PMLevel {
    let w: Int
    let h: Int
    var px: [Float]
    var hole: [Bool]

    init(w: Int, h: Int) {
        self.w = w
        self.h = h
        px = [Float](repeating: 0, count: w * h * 3)
        hole = [Bool](repeating: false, count: w * h)
    }

    /// 구멍 픽셀에서 가장 가까운 구멍 아닌 픽셀까지 거리(체스판)의 최댓값
    func holeThickness() -> Int {
        let big = Int32.max / 4
        var d = [Int32](repeating: 0, count: w * h)
        for i in 0..<(w * h) where hole[i] { d[i] = big }
        for y in 0..<h {
            for x in 0..<w where hole[y * w + x] {
                var m = d[y * w + x]
                if x > 0 { m = min(m, d[y * w + x - 1] + 1) }
                if y > 0 {
                    m = min(m, d[(y - 1) * w + x] + 1)
                    if x > 0 { m = min(m, d[(y - 1) * w + x - 1] + 1) }
                    if x < w - 1 { m = min(m, d[(y - 1) * w + x + 1] + 1) }
                }
                d[y * w + x] = m
            }
        }
        var best: Int32 = 0
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) where hole[y * w + x] {
                var m = d[y * w + x]
                if x < w - 1 { m = min(m, d[y * w + x + 1] + 1) }
                if y < h - 1 {
                    m = min(m, d[(y + 1) * w + x] + 1)
                    if x < w - 1 { m = min(m, d[(y + 1) * w + x + 1] + 1) }
                    if x > 0 { m = min(m, d[(y + 1) * w + x - 1] + 1) }
                }
                d[y * w + x] = m
                best = max(best, m)
            }
        }
        return Int(min(best, 1 << 20))
    }

    /// 반으로 줄인 단계(2×2 평균, 자식 중 하나라도 구멍이면 구멍)
    func down() -> PMLevel {
        var o = PMLevel(w: (w + 1) / 2, h: (h + 1) / 2)
        for y in 0..<o.h {
            for x in 0..<o.w {
                var s: (Float, Float, Float) = (0, 0, 0)
                var n: Float = 0
                var isHole = false
                for dy in 0...1 {
                    for dx in 0...1 {
                        let cx = 2 * x + dx, cy = 2 * y + dy
                        guard cx < w, cy < h else { continue }
                        let i = cy * w + cx
                        if hole[i] { isHole = true }
                        s.0 += px[i * 3]
                        s.1 += px[i * 3 + 1]
                        s.2 += px[i * 3 + 2]
                        n += 1
                    }
                }
                let j = y * o.w + x
                o.hole[j] = isHole
                o.px[j * 3] = s.0 / n
                o.px[j * 3 + 1] = s.1 / n
                o.px[j * 3 + 2] = s.2 / n
            }
        }
        return o
    }

    /// 구멍을 바깥 둘레부터 안쪽으로 이웃 평균으로 채운다(시작값)
    mutating func diffuse() {
        var known = hole.map { !$0 }
        var frontier: [Int] = []
        var queued = [Bool](repeating: false, count: w * h)
        func neighbors(_ i: Int, _ body: (Int, Bool) -> Void) {
            let x = i % w, y = i / w
            for dy in -1...1 {
                let ny = y + dy
                guard ny >= 0, ny < h else { continue }
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx
                    guard nx >= 0, nx < w else { continue }
                    body(ny * w + nx, dx == 0 || dy == 0)
                }
            }
        }
        for i in 0..<(w * h) where hole[i] {
            var hasKnown = false
            neighbors(i) { n, _ in if known[n] { hasKnown = true } }
            if hasKnown {
                frontier.append(i)
                queued[i] = true
            }
        }
        while !frontier.isEmpty {
            var values: [(Float, Float, Float)] = []
            values.reserveCapacity(frontier.count)
            for i in frontier {
                var s: (Float, Float, Float) = (0, 0, 0)
                var n: Float = 0
                neighbors(i) { j, straight in
                    guard known[j] else { return }
                    let wt: Float = straight ? 2 : 1
                    s.0 += px[j * 3] * wt
                    s.1 += px[j * 3 + 1] * wt
                    s.2 += px[j * 3 + 2] * wt
                    n += wt
                }
                values.append(n > 0 ? (s.0 / n, s.1 / n, s.2 / n) : (128, 128, 128))
            }
            var next: [Int] = []
            for (k, i) in frontier.enumerated() {
                px[i * 3] = values[k].0
                px[i * 3 + 1] = values[k].1
                px[i * 3 + 2] = values[k].2
                known[i] = true
            }
            for i in frontier {
                neighbors(i) { j, _ in
                    if hole[j] && !known[j] && !queued[j] {
                        queued[j] = true
                        next.append(j)
                    }
                }
            }
            frontier = next
        }
    }

    /// 거친 단계의 결과를 키워 구멍 시작값으로(쌍선형)
    mutating func initHole(from c: PMLevel) {
        for y in 0..<h {
            for x in 0..<w where hole[y * w + x] {
                let u = max(0, min(Float(c.w - 1), (Float(x) + 0.5) / 2 - 0.5))
                let v = max(0, min(Float(c.h - 1), (Float(y) + 0.5) / 2 - 0.5))
                let x0 = Int(u), y0 = Int(v)
                let x1 = min(x0 + 1, c.w - 1), y1 = min(y0 + 1, c.h - 1)
                let fx = u - Float(x0), fy = v - Float(y0)
                for ch in 0..<3 {
                    let a = c.px[(y0 * c.w + x0) * 3 + ch], b = c.px[(y0 * c.w + x1) * 3 + ch]
                    let d = c.px[(y1 * c.w + x0) * 3 + ch], e = c.px[(y1 * c.w + x1) * 3 + ch]
                    px[(y * w + x) * 3 + ch] = (a * (1 - fx) + b * fx) * (1 - fy) + (d * (1 - fx) + e * fx) * fy
                }
            }
        }
    }

    /// 조각 찾기 + 투표
    /// - window: 짝을 찾는 거리 한도(표적 둘레), sharpen: 마지막에 평균 대신 가장 잘 맞는 조각의 가운데 픽셀로(흐림 줄이기)
    mutating func solve(patch: Int, iterations: Int, seed: UInt64, window: Int = .max, sharpen: Bool = false) {
        let r = patch / 2
        guard w > 2 * r + 1, h > 2 * r + 1 else { return }
        let w = self.w, h = self.h
        // 조각 안 구멍 수(적분 영상)
        var integral = [Int32](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row: Int32 = 0
            for x in 0..<w {
                row += hole[y * w + x] ? 1 : 0
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        func holesIn(_ x: Int, _ y: Int) -> Int32 {
            let x0 = x - r, y0 = y - r, x1 = x + r + 1, y1 = y + r + 1
            return integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0]
                + integral[y0 * (w + 1) + x0]
        }
        var valid = [Bool](repeating: false, count: w * h)
        var validList: [Int] = []
        var targets: [Int] = []
        for y in r..<(h - r) {
            for x in r..<(w - r) {
                let n = holesIn(x, y)
                if n == 0 {
                    valid[y * w + x] = true
                    validList.append(y * w + x)
                } else {
                    targets.append(y * w + x)
                }
            }
        }
        guard !validList.isEmpty, !targets.isEmpty else { return }
        var rng = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func rand(_ n: Int) -> Int {
            rng ^= rng << 13
            rng ^= rng >> 7
            rng ^= rng << 17
            return Int(rng % UInt64(n))
        }
        var nnf = [Int](repeating: -1, count: w * h)
        var dist = [Float](repeating: .infinity, count: w * h)
        let win = min(window, max(w, h))
        for t in targets {
            // 처음 짝: 둘레 창 안의 아무 조각(못 찾으면 아무 데서나)
            let tx = t % w, ty = t / w
            var pick = -1
            for _ in 0..<24 {
                let cx = tx + rand(2 * win + 1) - win, cy = ty + rand(2 * win + 1) - win
                if cx >= r && cx < w - r && cy >= r && cy < h - r && valid[cy * w + cx] {
                    pick = cy * w + cx
                    break
                }
            }
            nnf[t] = pick >= 0 ? pick : validList[rand(validList.count)]
        }
        let rowLen = patch * 3

        for it in 0..<iterations {
            px.withUnsafeBufferPointer { p in
                func patchDist(_ t: Int, _ s: Int, _ limit: Float) -> Float {
                    let tx = t % w, ty = t / w, sx = s % w, sy = s / w
                    var sum: Float = 0
                    for dy in -r...r {
                        var ti = ((ty + dy) * w + tx - r) * 3
                        var si = ((sy + dy) * w + sx - r) * 3
                        for _ in 0..<rowLen {
                            let d = p[ti] - p[si]
                            sum += d * d
                            ti += 1
                            si += 1
                        }
                        if sum >= limit { return sum }
                    }
                    return sum
                }
                for t in targets { dist[t] = patchDist(t, nnf[t], .infinity) }
                let forward = it % 2 == 0
                let step = forward ? 1 : -1
                var k = forward ? 0 : targets.count - 1
                while k >= 0 && k < targets.count {
                    let t = targets[k]
                    k += step
                    var best = nnf[t], bestD = dist[t]
                    let tx = t % w
                    // 전파: 이웃 표적의 짝을 한 칸 옮겨 본다
                    let side = t - step, vert = t - step * w
                    if tx - step >= r && tx - step < w - r, nnf[side] >= 0 {
                        let c = nnf[side] + step
                        let cx = c % w
                        if cx >= r && cx < w - r && valid[c] {
                            let d = patchDist(t, c, bestD)
                            if d < bestD {
                                best = c
                                bestD = d
                            }
                        }
                    }
                    if vert >= 0 && vert < w * h, nnf[vert] >= 0 {
                        let c = nnf[vert] + step * w
                        if c >= 0 && c < w * h && valid[c] {
                            let d = patchDist(t, c, bestD)
                            if d < bestD {
                                best = c
                                bestD = d
                            }
                        }
                    }
                    // 무작위 탐색: 지금 짝 둘레를 반경을 반씩 줄이며(표적에서 창 밖으로는 안 간다)
                    var radius = win
                    let bx = best % w, by = best / w
                    let ty = t / w
                    while radius >= 1 {
                        let cx = bx + rand(2 * radius + 1) - radius, cy = by + rand(2 * radius + 1) - radius
                        if cx >= r && cx < w - r && cy >= r && cy < h - r
                            && abs(cx - tx) <= win && abs(cy - ty) <= win {
                            let c = cy * w + cx
                            if valid[c] {
                                let d = patchDist(t, c, bestD)
                                if d < bestD {
                                    best = c
                                    bestD = d
                                }
                            }
                        }
                        radius /= 2
                    }
                    nnf[t] = best
                    dist[t] = bestD
                }
            }
            // 투표: 구멍 픽셀마다 덮는 조각들의 짝 색을 (잘 맞는 짝일수록 훨씬 크게) 평균
            var ds = targets.map { dist[$0] }
            ds.sort()
            let sigma2 = max(ds[min(ds.count - 1, ds.count / 4)], 1)
            var acc = [Float](repeating: 0, count: w * h * 3)
            var wsum = [Float](repeating: 0, count: w * h)
            for t in targets {
                let s = nnf[t]
                let wt = max(Float(exp(Double(-dist[t] / (2 * sigma2)))), 1e-6)
                for dy in -r...r {
                    for dx in -r...r {
                        let pidx = t + dy * w + dx
                        guard hole[pidx] else { continue }
                        let q = s + dy * w + dx
                        acc[pidx * 3] += px[q * 3] * wt
                        acc[pidx * 3 + 1] += px[q * 3 + 1] * wt
                        acc[pidx * 3 + 2] += px[q * 3 + 2] * wt
                        wsum[pidx] += wt
                    }
                }
            }
            for i in 0..<(w * h) where hole[i] && wsum[i] > 0 {
                px[i * 3] = acc[i * 3] / wsum[i]
                px[i * 3 + 1] = acc[i * 3 + 1] / wsum[i]
                px[i * 3 + 2] = acc[i * 3 + 2] / wsum[i]
            }
        }
        // 마지막: 구멍 픽셀은 자기를 가운데에 둔 조각의 짝 가운데 픽셀로(평균하면 흐려진다)
        if sharpen {
            var out = px
            for t in targets where hole[t] && nnf[t] >= 0 {
                let s = nnf[t]
                // 평균값과 너무 다르면(이음매) 평균 쪽으로 반쯤
                for ch in 0..<3 { out[t * 3 + ch] = px[s * 3 + ch] * 0.7 + px[t * 3 + ch] * 0.3 }
            }
            px = out
        }
    }
}
