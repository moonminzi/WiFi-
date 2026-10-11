import Foundation

/// 8비트 RGBA 색
public struct RGBA: Equatable, Hashable, Codable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let white = RGBA(255, 255, 255)
    public static let black = RGBA(0, 0, 0)

    /// 밝기(0...255, Rec.601)
    @inline(__always) public var luminance: Int {
        (Int(r) * 299 + Int(g) * 587 + Int(b) * 114) / 1000
    }

    /// 두 색의 거리(RGB 유클리드 제곱)
    @inline(__always) public func distance2(_ o: RGBA) -> Int {
        let dr = Int(r) - Int(o.r)
        let dg = Int(g) - Int(o.g)
        let db = Int(b) - Int(o.b)
        return dr * dr + dg * dg + db * db
    }
}

/// 정수 사각형(왼쪽 위 원점, 아래로 y 증가)
public struct IRect: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(x: Int, y: Int, w: Int, h: Int) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var maxX: Int { x + w }
    public var maxY: Int { y + h }
    public var area: Int { max(0, w) * max(0, h) }
    public var isEmpty: Bool { w <= 0 || h <= 0 }
    public var centerX: Double { Double(x) + Double(w) / 2 }
    public var centerY: Double { Double(y) + Double(h) / 2 }
    public var description: String { "(\(x),\(y) \(w)x\(h))" }

    public func expanded(by d: Int) -> IRect {
        IRect(x: x - d, y: y - d, w: w + 2 * d, h: h + 2 * d)
    }

    public func expanded(dx: Int, dy: Int) -> IRect {
        IRect(x: x - dx, y: y - dy, w: w + 2 * dx, h: h + 2 * dy)
    }

    public func intersection(_ o: IRect) -> IRect {
        let x0 = max(x, o.x), y0 = max(y, o.y)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        return x1 > x0 && y1 > y0 ? IRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0) : IRect(x: x0, y: y0, w: 0, h: 0)
    }

    public func union(_ o: IRect) -> IRect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        let x0 = min(x, o.x), y0 = min(y, o.y)
        return IRect(x: x0, y: y0, w: max(maxX, o.maxX) - x0, h: max(maxY, o.maxY) - y0)
    }

    public func clamped(width: Int, height: Int) -> IRect {
        intersection(IRect(x: 0, y: 0, w: width, h: height))
    }

    public func contains(_ px: Int, _ py: Int) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }

    /// 겹친 넓이 / 합친 넓이
    public func iou(_ o: IRect) -> Double {
        let i = intersection(o).area
        let u = area + o.area - i
        return u > 0 ? Double(i) / Double(u) : 0
    }

    /// 이 상자에서 o가 차지하는 비율
    public func coverage(of o: IRect) -> Double {
        o.area > 0 ? Double(intersection(o).area) / Double(o.area) : 0
    }

    public func scaled(_ s: Double) -> IRect {
        IRect(x: Int((Double(x) * s).rounded()), y: Int((Double(y) * s).rounded()),
              w: Int((Double(w) * s).rounded()), h: Int((Double(h) * s).rounded()))
    }
}

/// RGBA8 그림(행 우선, 한 줄 = width*4바이트)
public struct Bitmap: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: RGBA = .white) {
        self.width = width
        self.height = height
        var p = [UInt8](repeating: 0, count: width * height * 4)
        var i = 0
        while i < p.count {
            p[i] = fill.r
            p[i + 1] = fill.g
            p[i + 2] = fill.b
            p[i + 3] = fill.a
            i += 4
        }
        pixels = p
    }

    public var bounds: IRect { IRect(x: 0, y: 0, w: width, h: height) }

    @inline(__always) public func color(_ x: Int, _ y: Int) -> RGBA {
        let i = (y * width + x) * 4
        return RGBA(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    @inline(__always) public mutating func set(_ x: Int, _ y: Int, _ c: RGBA) {
        let i = (y * width + x) * 4
        pixels[i] = c.r
        pixels[i + 1] = c.g
        pixels[i + 2] = c.b
        pixels[i + 3] = c.a
    }

    @inline(__always) public func luminance(_ x: Int, _ y: Int) -> Int {
        let i = (y * width + x) * 4
        return (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
    }

    public mutating func fill(_ r: IRect, _ c: RGBA) {
        let rr = r.clamped(width: width, height: height)
        guard !rr.isEmpty else { return }
        for y in rr.y..<rr.maxY {
            for x in rr.x..<rr.maxX { set(x, y, c) }
        }
    }

    /// 사각형 안의 평균 색
    public func average(_ r: IRect) -> RGBA {
        let rr = r.clamped(width: width, height: height)
        guard !rr.isEmpty else { return .white }
        var sr = 0, sg = 0, sb = 0
        for y in rr.y..<rr.maxY {
            var i = (y * width + rr.x) * 4
            for _ in rr.x..<rr.maxX {
                sr += Int(pixels[i])
                sg += Int(pixels[i + 1])
                sb += Int(pixels[i + 2])
                i += 4
            }
        }
        let n = rr.area
        return RGBA(UInt8(sr / n), UInt8(sg / n), UInt8(sb / n))
    }

    /// 파일 형식(시험용): 너비·높이(각 4바이트 little-endian) + RGBA
    public static func load(raw data: Data) -> Bitmap? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        let w = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        let h = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        guard bytes.count == 8 + w * h * 4 else { return nil }
        return Bitmap(width: w, height: h, pixels: Array(bytes[8...]))
    }

    public func rawData() -> Data {
        var out = Data()
        var w = UInt32(width).littleEndian
        var h = UInt32(height).littleEndian
        withUnsafeBytes(of: &w) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { out.append(contentsOf: $0) }
        out.append(contentsOf: pixels)
        return out
    }
}

/// 한 영역 안의 0/1 마스크(영역 기준 좌표)
public struct RegionMask: Sendable, Equatable {
    public let rect: IRect
    public var bits: [Bool]

    public init(rect: IRect, value: Bool = false) {
        self.rect = rect
        bits = [Bool](repeating: value, count: max(0, rect.area))
    }

    @inline(__always) public func get(_ x: Int, _ y: Int) -> Bool {
        guard rect.contains(x, y) else { return false }
        return bits[(y - rect.y) * rect.w + (x - rect.x)]
    }

    @inline(__always) public mutating func put(_ x: Int, _ y: Int, _ v: Bool) {
        guard rect.contains(x, y) else { return }
        bits[(y - rect.y) * rect.w + (x - rect.x)] = v
    }

    public var count: Int { bits.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// 켜진 칸을 감싸는 상자(전체 좌표)
    public var boundingBox: IRect {
        var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
        for ly in 0..<rect.h {
            let row = ly * rect.w
            for lx in 0..<rect.w where bits[row + lx] {
                x0 = min(x0, lx)
                x1 = max(x1, lx)
                y0 = min(y0, ly)
                y1 = max(y1, ly)
            }
        }
        guard x0 != Int.max else { return IRect(x: rect.x, y: rect.y, w: 0, h: 0) }
        return IRect(x: rect.x + x0, y: rect.y + y0, w: x1 - x0 + 1, h: y1 - y0 + 1)
    }

    /// r칸만큼 넓힌다(정사각 이웃)
    public func dilated(_ r: Int) -> RegionMask {
        guard r > 0 else { return self }
        // 가로로 한 번, 세로로 한 번(분리 가능한 최대 필터)
        var tmp = RegionMask(rect: rect)
        for ly in 0..<rect.h {
            let row = ly * rect.w
            var last = -1_000_000
            // 왼쪽에서 오른쪽으로 가장 가까운 켜진 칸까지 거리
            var dist = [Int](repeating: Int.max, count: rect.w)
            for lx in 0..<rect.w {
                if bits[row + lx] { last = lx }
                dist[lx] = lx - last
            }
            last = 1_000_000
            for lx in stride(from: rect.w - 1, through: 0, by: -1) {
                if bits[row + lx] { last = lx }
                if min(dist[lx], last - lx) <= r { tmp.bits[row + lx] = true }
            }
        }
        var out = RegionMask(rect: rect)
        for lx in 0..<rect.w {
            var last = -1_000_000
            var dist = [Int](repeating: Int.max, count: rect.h)
            for ly in 0..<rect.h {
                if tmp.bits[ly * rect.w + lx] { last = ly }
                dist[ly] = ly - last
            }
            last = 1_000_000
            for ly in stride(from: rect.h - 1, through: 0, by: -1) {
                if tmp.bits[ly * rect.w + lx] { last = ly }
                if min(dist[ly], last - ly) <= r { out.bits[ly * rect.w + lx] = true }
            }
        }
        return out
    }

    /// r칸만큼 깎는다
    public func eroded(_ r: Int) -> RegionMask {
        var inv = self
        for i in inv.bits.indices { inv.bits[i].toggle() }
        var grown = inv.dilated(r)
        for i in grown.bits.indices { grown.bits[i].toggle() }
        // 바깥 테두리도 바깥으로 본다
        for ly in 0..<rect.h {
            for lx in 0..<rect.w where lx < r || ly < r || lx >= rect.w - r || ly >= rect.h - r {
                grown.bits[ly * rect.w + lx] = false
            }
        }
        return grown
    }
}
