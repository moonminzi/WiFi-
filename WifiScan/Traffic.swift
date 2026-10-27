import Foundation
import Observation

/// 연결돼 있는 동안 1초마다 터널이 알려 주는 바이트 수를 받아 속도(바이트/초)를 낸다.
/// wg 터널만 숫자를 준다(ikev2는 시스템 터널이라 없음).
@MainActor
@Observable
final class TrafficMeter {
    struct Rate {
        /// 받은 쪽(내려받기)
        let down: Double
        /// 보낸 쪽(올리기)
        let up: Double
    }

    /// 최근 60초
    private(set) var history: [Rate] = []
    private(set) var current: Rate?
    private(set) var totalDown: UInt64 = 0
    private(set) var totalUp: UInt64 = 0
    /// 이번 연결에서 가장 빨랐던 내려받기
    private(set) var peakDown: Double = 0
    @ObservationIgnored private var last: (at: Date, rx: UInt64, tx: UInt64)?

    static let window = 60

    var hasData: Bool { last != nil }

    func reset() {
        history = []
        current = nil
        totalDown = 0
        totalUp = 0
        peakDown = 0
        last = nil
    }

    /// 터널이 쌓아 둔 최근 속도로 통째로 바꾼다. 앱이 안 보고 있던 동안(다른 탭, 앱 밖)도 이어져 있다.
    func load(history rates: [[Double]], rx: UInt64, tx: UInt64, at now: Date = Date()) {
        history = rates.suffix(Self.window).compactMap { $0.count == 2 ? Rate(down: $0[0], up: $0[1]) : nil }
        current = history.last
        totalDown = rx
        totalUp = tx
        peakDown = max(peakDown, history.map(\.down).max() ?? 0)
        last = (now, rx, tx)
    }

    func add(rx: UInt64, tx: UInt64, at now: Date = Date()) {
        totalDown = rx
        totalUp = tx
        let previous = last
        last = (now, rx, tx)
        // 터널이 다시 뜨면 숫자가 0부터 다시 센다 — 그 한 번은 건너뛴다
        guard let previous, now > previous.at, rx >= previous.rx, tx >= previous.tx else { return }
        let dt = now.timeIntervalSince(previous.at)
        let rate = Rate(down: Double(rx - previous.rx) / dt, up: Double(tx - previous.tx) / dt)
        current = rate
        peakDown = max(peakDown, rate.down)
        history.append(rate)
        if history.count > Self.window { history.removeFirst(history.count - Self.window) }
    }

    /// 스크린샷용: 그럴듯한 1분짜리 물결
    func fillDemo() {
        reset()
        var rx: UInt64 = 48_200_000
        var tx: UInt64 = 3_100_000
        let start = Date().addingTimeInterval(-Double(Self.window))
        for i in 0...Self.window {
            let t = Double(i)
            let burst = max(0, sin(t / 6)) * 2_600_000 + (i % 17 < 3 ? 1_800_000 : 0)
            rx += UInt64(120_000 + burst)
            tx += UInt64(18_000 + burst / 22)
            add(rx: rx, tx: tx, at: start.addingTimeInterval(t))
        }
    }

    /// 2400000 → "2.4 MB/s"
    static func speed(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        if v >= 1e6 { return String(format: "%.1f MB/s", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0f KB/s", v / 1e3) }
        return String(format: "%.0f B/s", v)
    }

    static func bytes(_ n: UInt64) -> String {
        let v = Double(n)
        if v >= 1e9 { return String(format: "%.2f GB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1f MB", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0f KB", v / 1e3) }
        return "\(n) B"
    }
}
