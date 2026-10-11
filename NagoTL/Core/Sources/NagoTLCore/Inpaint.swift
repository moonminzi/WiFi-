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
