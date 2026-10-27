import Foundation

// route 지도의 계산 부분(좌표·경로·카메라·진행). 그리기는 RouteMap.swift.
// 평면 좌표는 (경도°, 메르카토르°) — 위도를 메르카토르로 펴서 경도와 같은 단위로 쓴다.

struct WorldPoint: Equatable {
    var x: Double
    var y: Double
}

/// 위도/경도 한 점과 그곳 이름
struct GeoPoint: Equatable {
    let lat: Double
    let lon: Double
    let city: String

    var world: WorldPoint { WorldPoint(x: lon, y: RouteMath.mercY(lat)) }

    /// 대권 거리(km)
    func km(to other: GeoPoint) -> Double {
        let p1 = lat * .pi / 180, p2 = other.lat * .pi / 180
        let dp = p2 - p1, dl = (other.lon - lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * 6371 * asin(min(1, sqrt(h)))
    }

    /// 이 기기의 대략적인 위치. 위치 권한 없이 시간대의 도시로 어림한다(모르는 시간대면 서울).
    static let here: GeoPoint = zones[TimeZone.current.identifier] ?? seoul

    private static let seoul = GeoPoint(lat: 37.5665, lon: 126.978, city: "seoul")
    private static let zones: [String: GeoPoint] = [
        "Asia/Seoul": seoul,
        "Asia/Tokyo": GeoPoint(lat: 35.6762, lon: 139.6503, city: "tokyo"),
        "Asia/Shanghai": GeoPoint(lat: 31.2304, lon: 121.4737, city: "shanghai"),
        "Asia/Hong_Kong": GeoPoint(lat: 22.3193, lon: 114.1694, city: "hong kong"),
        "Asia/Taipei": GeoPoint(lat: 25.033, lon: 121.5654, city: "taipei"),
        "Asia/Singapore": GeoPoint(lat: 1.3521, lon: 103.8198, city: "singapore"),
        "Asia/Bangkok": GeoPoint(lat: 13.7563, lon: 100.5018, city: "bangkok"),
        "Asia/Ho_Chi_Minh": GeoPoint(lat: 10.8231, lon: 106.6297, city: "ho chi minh"),
        "Asia/Manila": GeoPoint(lat: 14.5995, lon: 120.9842, city: "manila"),
        "Asia/Jakarta": GeoPoint(lat: -6.2088, lon: 106.8456, city: "jakarta"),
        "Asia/Kolkata": GeoPoint(lat: 28.6139, lon: 77.209, city: "new delhi"),
        "Asia/Dubai": GeoPoint(lat: 25.2048, lon: 55.2708, city: "dubai"),
        "Europe/London": GeoPoint(lat: 51.5074, lon: -0.1278, city: "london"),
        "Europe/Paris": GeoPoint(lat: 48.8566, lon: 2.3522, city: "paris"),
        "Europe/Berlin": GeoPoint(lat: 52.52, lon: 13.405, city: "berlin"),
        "Europe/Madrid": GeoPoint(lat: 40.4168, lon: -3.7038, city: "madrid"),
        "Europe/Rome": GeoPoint(lat: 41.9028, lon: 12.4964, city: "rome"),
        "Europe/Amsterdam": GeoPoint(lat: 52.3676, lon: 4.9041, city: "amsterdam"),
        "Europe/Moscow": GeoPoint(lat: 55.7558, lon: 37.6173, city: "moscow"),
        "America/New_York": GeoPoint(lat: 40.7128, lon: -74.006, city: "new york"),
        "America/Chicago": GeoPoint(lat: 41.8781, lon: -87.6298, city: "chicago"),
        "America/Denver": GeoPoint(lat: 39.7392, lon: -104.9903, city: "denver"),
        "America/Los_Angeles": GeoPoint(lat: 34.0522, lon: -118.2437, city: "los angeles"),
        "America/Toronto": GeoPoint(lat: 43.6532, lon: -79.3832, city: "toronto"),
        "America/Vancouver": GeoPoint(lat: 49.2827, lon: -123.1207, city: "vancouver"),
        "America/Mexico_City": GeoPoint(lat: 19.4326, lon: -99.1332, city: "mexico city"),
        "America/Sao_Paulo": GeoPoint(lat: -23.5505, lon: -46.6333, city: "sao paulo"),
        "Australia/Sydney": GeoPoint(lat: -33.8688, lon: 151.2093, city: "sydney"),
        "Australia/Melbourne": GeoPoint(lat: -37.8136, lon: 144.9631, city: "melbourne"),
        "Pacific/Auckland": GeoPoint(lat: -36.8485, lon: 174.7633, city: "auckland"),
        "Pacific/Honolulu": GeoPoint(lat: 21.3069, lon: -157.8583, city: "honolulu"),
    ]
}

extension VPNRegion {
    /// 그 나라 AWS 리전이 있는 곳
    var geo: GeoPoint {
        switch self {
        case .kr: return GeoPoint(lat: 37.5665, lon: 126.978, city: cityName)
        case .jp: return GeoPoint(lat: 35.6762, lon: 139.6503, city: cityName)
        case .us: return GeoPoint(lat: 45.84, lon: -119.70, city: cityName)
        case .uk: return GeoPoint(lat: 51.5074, lon: -0.1278, city: cityName)
        case .sg: return GeoPoint(lat: 1.3521, lon: 103.8198, city: cityName)
        case .de: return GeoPoint(lat: 50.1109, lon: 8.6821, city: cityName)
        case .fr: return GeoPoint(lat: 48.8566, lon: 2.3522, city: cityName)
        case .ie: return GeoPoint(lat: 53.3498, lon: -6.2603, city: cityName)
        case .se: return GeoPoint(lat: 59.3293, lon: 18.0686, city: cityName)
        case .ca: return GeoPoint(lat: 45.5017, lon: -73.5673, city: cityName)
        case .br: return GeoPoint(lat: -23.5505, lon: -46.6333, city: cityName)
        case .au: return GeoPoint(lat: -33.8688, lon: 151.2093, city: cityName)
        case .in: return GeoPoint(lat: 19.0760, lon: 72.8777, city: cityName)
        }
    }

    /// WorldDots 칸 값(2부터 allCases 순서)
    var mapCode: UInt8 {
        UInt8(2 + (Self.allCases.firstIndex(of: self) ?? 0))
    }
}

enum RouteMath {
    static func mercY(_ lat: Double) -> Double {
        let l = min(85, max(-85, lat)) * .pi / 180
        return log(tan(.pi / 4 + l / 2)) * 180 / .pi
    }

    static func lat(mercY y: Double) -> Double {
        (2 * atan(exp(y * .pi / 180)) - .pi / 2) * 180 / .pi
    }

    /// ref에서 180° 안쪽으로 경도를 편다. 태평양을 건너는 경로가 지도 끝으로 돌아가지 않게.
    static func unwrap(_ lon: Double, near ref: Double) -> Double {
        var x = lon
        while x - ref > 180 { x -= 360 }
        while x - ref < -180 { x += 360 }
        return x
    }

    /// -180..<180
    static func normalized(_ lon: Double) -> Double {
        let x = (lon + 180).truncatingRemainder(dividingBy: 360)
        return (x < 0 ? x + 360 : x) - 180
    }

    static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    static func easeOut(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }

    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// 1149 → "1,149"
    static func grouped(_ n: Int) -> String {
        let digits = Array(String(n))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }
}

/// 출발점에서 도착점까지 북쪽으로 휜 2차 곡선. 길이 비율(0…1)로 점을 찾아서 웨이포인트가 고르게 찍힌다.
/// 둘이 거의 같은 곳이면(서울에서 kr) `local` — 지도에서는 도착점을 도는 고리로 그린다.
struct RouteArc {
    let a: WorldPoint
    let b: WorldPoint
    let local: Bool
    private let control: WorldPoint
    private let lengths: [Double]
    private static let samples = 64

    init(from: GeoPoint, to: GeoPoint) {
        let a = from.world
        let b = WorldPoint(x: RouteMath.unwrap(to.lon, near: from.lon), y: RouteMath.mercY(to.lat))
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1e-9)
        var nx = -dy / len, ny = dx / len
        if ny < 0 || (ny == 0 && nx < 0) {
            nx = -nx
            ny = -ny
        }
        let control = WorldPoint(x: (a.x + b.x) / 2 + nx * len * 0.22, y: (a.y + b.y) / 2 + ny * len * 0.22)
        var lengths = [0.0]
        var p = a
        for i in 1...Self.samples {
            let q = Self.bezier(a, control, b, Double(i) / Double(Self.samples))
            lengths.append(lengths[i - 1] + hypot(q.x - p.x, q.y - p.y))
            p = q
        }
        self.a = a
        self.b = b
        self.local = len < 2.5
        self.control = control
        self.lengths = lengths
    }

    func point(at f: Double) -> WorldPoint {
        let n = Self.samples
        let total = lengths[n]
        guard total > 0 else { return a }
        let target = min(1, max(0, f)) * total
        var i = 1
        while i < n && lengths[i] < target { i += 1 }
        let l0 = lengths[i - 1], l1 = lengths[i]
        let t = (Double(i - 1) + (l1 > l0 ? (target - l0) / (l1 - l0) : 0)) / Double(n)
        return Self.bezier(a, control, b, t)
    }

    private static func bezier(_ a: WorldPoint, _ c: WorldPoint, _ b: WorldPoint, _ t: Double) -> WorldPoint {
        let u = 1 - t
        return WorldPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                          y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
}

/// 연결 한 번의 진행. 단계(phase)가 바뀔 때마다 경로에 웨이포인트가 하나 찍히고, 머리(커서)가 거기까지 간다.
/// 다음 단계를 기다리는 동안 머리는 다음 자리 쪽으로 천천히 기어간다(서버가 켜지는 데 몇 분 걸려도 멈춰 보이지 않게).
struct RouteRun {
    struct Stop {
        let f: Double
        let time: Date
    }

    struct Mark {
        let f: Double
        let time: Date
    }

    private(set) var stops: [Stop]
    /// 연결됨: 그때 머리 자리에서 끝까지 그린다
    private(set) var finish: Mark?
    /// 실패: 머리가 그 자리에 멈추고 빨갛게
    private(set) var failure: Mark?
    /// 이 시각부터 경로가 사라진다
    var gone: Date?
    private var hops = 0

    /// 머리가 이동하는 시간(초)
    static let travel = 0.6
    /// 연결되기 전까지 머리가 갈 수 있는 끝. 보통 단계 수(4)만큼 고르게 나누고, 넘치면 남은 길을 줄여 가며 찍는다.
    private static let span = 0.88, usualHops = 4

    static func next(after f: Double, index i: Int) -> Double {
        i <= usualHops ? span * Double(i) / Double(usualHops + 1) : f + (0.95 - f) * 0.4
    }

    init(start: Date) {
        stops = [Stop(f: 0, time: start)]
    }

    /// 첫 단계(서버 확인)는 출발점이다. 그다음 단계부터 웨이포인트를 찍는다.
    mutating func hop(_ now: Date) {
        hops += 1
        guard hops > 1, finish == nil, failure == nil, stops.count < 8, let last = stops.last else { return }
        stops.append(Stop(f: Self.next(after: last.f, index: stops.count), time: now))
    }

    mutating func complete(_ now: Date) {
        guard finish == nil else { return }
        finish = Mark(f: head(now), time: now)
    }

    mutating func fail(_ now: Date) {
        guard finish == nil, failure == nil else { return }
        failure = Mark(f: head(now), time: now)
    }

    /// 지금 머리 자리(0…1)
    func head(_ now: Date) -> Double {
        if let finish {
            let u = min(1, max(0, now.timeIntervalSince(finish.time) / 0.8))
            return finish.f + (1 - finish.f) * RouteMath.easeOut(u)
        }
        if let failure { return failure.f }
        let last = stops[stops.count - 1]
        let prev = stops.count > 1 ? stops[stops.count - 2] : last
        let since = max(0, now.timeIntervalSince(last.time))
        if since < Self.travel {
            return prev.f + (last.f - prev.f) * RouteMath.easeOut(since / Self.travel)
        }
        let creep = 1 - exp(-(since - Self.travel) / 6)
        return last.f + (Self.next(after: last.f, index: stops.count) - last.f) * 0.5 * creep
    }
}

/// 지도 카메라. z = log2(1°당 pt)
struct Camera: Equatable {
    var x: Double
    var y: Double
    var z: Double

    var scale: Double { pow(2, z) }
}

/// 한 카메라에서 지금 목표로 날아가는 중. 멀리 갈 때는 중간에 한 번 멀어졌다가 다가간다.
struct Flight {
    let from: Camera
    let start: Date
    let duration: Double
    let bump: Double

    init(from: Camera, to: Camera, width: Double, start: Date) {
        let k = pow(2, min(from.z, to.z))
        let dist = hypot(to.x - from.x, to.y - from.y) * k
        self.from = from
        self.start = start
        self.duration = 0.9 + 0.6 * min(1, dist / width)
        self.bump = min(1.4, log2(1 + dist / width))
    }

    /// 끝났으면 nil
    func camera(to: Camera, at now: Date) -> Camera? {
        let u = now.timeIntervalSince(start) / duration
        guard u < 1 else { return nil }
        let e = RouteMath.easeInOut(max(0, u))
        return Camera(x: from.x + (to.x - from.x) * e,
                      y: from.y + (to.y - from.y) * e,
                      z: from.z + (to.z - from.z) * e - bump * sin(.pi * e))
    }
}
