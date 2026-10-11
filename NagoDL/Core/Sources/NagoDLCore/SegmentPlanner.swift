import Foundation

/// IDM식 동적 분할.
///
/// 처음에는 연결 수만큼 고르게 나누고, 자기 구간을 먼저 끝낸 연결은 아직 많이 남은 구간의
/// 뒤쪽 절반을 가져간다. 그래서 느린 연결 하나 때문에 끝이 늘어지지 않고, 모든 연결이 끝까지 일한다.
public struct SegmentPlanner: Sendable {
    public var minPiece: Int64

    public init(minPiece: Int64 = 256 * 1024) {
        self.minPiece = max(1, minPiece)
    }

    /// 크기를 처음 알았을 때 k조각으로 나눈다(각 조각이 minPiece보다 작아지지 않게).
    public func initialSegments(total: Int64, connections: Int) -> [Segment] {
        guard total > 0 else { return [] }
        let k = Int(max(1, min(Int64(max(1, connections)), total / minPiece)))
        var result: [Segment] = []
        result.reserveCapacity(k)
        for i in 0..<k {
            let start = total * Int64(i) / Int64(k)
            let end = total * Int64(i + 1) / Int64(k) - 1
            result.append(Segment(start: start, end: end))
        }
        return result
    }

    /// 빈 연결이 맡을 구간의 start. 쉬는 구간이 있으면 그것, 없으면 일하는 구간 하나를 반으로 쪼갠다.
    /// - Parameter busy: 지금 연결이 붙어 있는 구간들의 start
    public func pickWork(_ segments: inout [Segment], busy: Set<Int64>) -> Int64? {
        if let idle = segments.first(where: { !$0.isDone && !$0.external && !busy.contains($0.start) }) {
            return idle.start
        }
        return split(&segments, busy: busy)
    }

    /// 일하는 구간 중 가장 많이 남은 것의 뒤쪽 절반을 새 구간으로 떼어 낸다.
    public func split(_ segments: inout [Segment], busy: Set<Int64>) -> Int64? {
        var best: Int?
        var bestRemaining: Int64 = 0
        for (i, s) in segments.enumerated() where busy.contains(s.start) && !s.isDone && !s.external && s.end != Int64.max {
            let r = s.remaining
            if r > bestRemaining {
                bestRemaining = r
                best = i
            }
        }
        guard let i = best, bestRemaining >= 2 * minPiece else { return nil }
        let s = segments[i]
        let mid = s.next + bestRemaining / 2
        let piece = Segment(start: mid, end: s.end)
        segments[i].end = mid - 1
        segments.insert(piece, at: i + 1)
        return mid
    }

    /// 이웃 구간을 합쳐서 목록을 짧게 유지한다.
    /// 앞 구간이 다 찼거나 뒤 구간이 아직 비어 있으면 합쳐도 "앞에서부터 연속으로 받음"이 유지된다.
    public static func compact(_ segments: inout [Segment], busy: Set<Int64>) {
        guard segments.count > 1 else { return }
        segments.sort { $0.start < $1.start }
        var out: [Segment] = []
        out.reserveCapacity(segments.count)
        for s in segments {
            if var last = out.last,
               last.end != Int64.max, last.end + 1 == s.start,
               !busy.contains(last.start), !busy.contains(s.start),
               !last.external, !s.external,
               last.isDone || s.received == 0 {
                let received = last.isDone ? last.length + s.received : last.received
                last.end = s.end
                last.received = received
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        segments = out
    }

    /// 백그라운드로 넘기려고 남은 부분을 chunk 크기 안팎으로 나눈다.
    /// 받은 앞부분은 다 찬 구간으로 남기고, 나머지는 external 표시를 단 새 구간들이 된다.
    public static func chunkForBackground(_ segments: [Segment], chunk: Int64) -> [Segment] {
        var out: [Segment] = []
        let size = max(chunk, 1)
        for s in segments {
            if s.isDone || s.external || s.end == Int64.max {
                out.append(s)
                continue
            }
            if s.received > 0 {
                out.append(Segment(start: s.start, end: s.next - 1, received: s.received))
            }
            var from = s.next
            let remaining = s.end - from + 1
            let pieces = max(1, (remaining + size / 2) / size)
            for i in 0..<pieces {
                let to = i == pieces - 1 ? s.end : from + remaining / pieces - 1
                out.append(Segment(start: from, end: to, received: 0, external: true))
                from = to + 1
            }
        }
        return out
    }
}
