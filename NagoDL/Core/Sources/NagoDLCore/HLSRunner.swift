import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HLS 조각 위치(트랙 + 번호, -1은 init)
struct HLSWork: Hashable {
    var track: HLSTrack
    var index: Int

    /// 막대에 쓸 키
    var key: Int64 { Int64(track.rawValue) * 10_000_000 + Int64(index + 1) }
}

extension HLSJob {
    func part(_ w: HLSWork) -> HLSPart? {
        switch (w.track, w.index) {
        case (.main, -1): return initSegment
        case (.audio, -1): return audioInit
        case (.main, let i): return parts.indices.contains(i) ? parts[i] : nil
        case (.audio, let i): return audioParts.indices.contains(i) ? audioParts[i] : nil
        }
    }

    mutating func update(_ w: HLSWork, _ change: (inout HLSPart) -> Void) {
        switch (w.track, w.index) {
        case (.main, -1): if initSegment != nil { change(&initSegment!) }
        case (.audio, -1): if audioInit != nil { change(&audioInit!) }
        case (.main, let i): if parts.indices.contains(i) { change(&parts[i]) }
        case (.audio, let i): if audioParts.indices.contains(i) { change(&audioParts[i]) }
        }
    }

    /// 받을 순서: init → 본 조각 → 오디오 조각
    var allWork: [HLSWork] {
        var out: [HLSWork] = []
        if initSegment != nil { out.append(HLSWork(track: .main, index: -1)) }
        if audioInit != nil { out.append(HLSWork(track: .audio, index: -1)) }
        let n = max(parts.count, audioParts.count)
        for i in 0..<n {
            if i < parts.count { out.append(HLSWork(track: .main, index: i)) }
            if i < audioParts.count { out.append(HLSWork(track: .audio, index: i)) }
        }
        return out
    }

    var isComplete: Bool { allWork.allSatisfy { part($0)?.done == true } }
}

/// HLS: 조각들을 여러 연결로 동시에 받아 폴더에 모은다. 다 모이면 매니저가 MP4로 합친다.
final class HLSRunner: Runner {
    private final class Conn {
        let id: Int
        let channel: HTTPChannel
        var work: HLSWork?
        var sink: FileSink?
        var tmpURL: URL?
        var received: Int64 = 0
        var status = 0
        var failures = 0
        var meter = SpeedMeter(window: 3)
        var retry: DispatchWorkItem?

        init(id: Int, channel: HTTPChannel) {
            self.id = id
            self.channel = channel
        }
    }

    private weak var manager: DownloadManager?
    private let item: DownloadManager.Item
    private let queue: DispatchQueue
    private let settings: EngineSettings
    private let paths: EnginePaths
    private var conns: [Conn] = []
    private var nextID = 1
    private var stopped = true
    private var partFailures: [HLSWork: Int] = [:]
    private var waiting: Set<HLSWork> = []

    init(manager: DownloadManager, item: DownloadManager.Item, settings: EngineSettings, paths: EnginePaths) {
        self.manager = manager
        self.item = item
        self.queue = manager.queue
        self.settings = settings
        self.paths = paths
    }

    private var limit: Int { max(1, min(item.record.maxConnections, 8)) }

    var activeConnections: Int { conns.filter { $0.work != nil }.count }

    var busyKeys: Set<Int64> { Set(conns.compactMap { $0.work?.key }) }

    var inFlightBytes: Int64 { conns.reduce(0) { $0 + ($1.work == nil ? 0 : $1.received) } }

    func start() {
        guard stopped else { return }
        stopped = false
        do {
            try FileManager.default.createDirectory(at: paths.hlsDir(item.record.id), withIntermediateDirectories: true)
        } catch {
            fail(error.localizedDescription)
            return
        }
        guard let job = item.record.hls else {
            fail("HLS 정보가 없어요")
            return
        }
        // 완료로 적혀 있는데 파일이 없으면 다시 받는다
        var fixed = job
        for w in job.allWork where job.part(w)?.done == true {
            let url = paths.hlsPartURL(item.record.id, track: w.track, index: w.index)
            if !FileManager.default.fileExists(atPath: url.path) {
                fixed.update(w) { $0.done = false; $0.bytes = 0 }
            }
        }
        item.record.hls = fixed
        if fixed.isComplete {
            finish()
            return
        }
        fill()
    }

    func stop() {
        stopped = true
        for c in conns {
            c.retry?.cancel()
            c.channel.invalidate()
            c.sink?.close()
            if let tmp = c.tmpURL { try? FileManager.default.removeItem(at: tmp) }
        }
        conns.removeAll()
        waiting.removeAll()
    }

    private func makeConn() -> Conn {
        let record = item.record
        let options = ChannelOptions(timeout: settings.requestTimeout, allowsCellular: settings.allowsCellular,
                                     useCookieStore: record.headers["Cookie"] == nil)
        let c = Conn(id: nextID, channel: HTTPChannel(queue: queue, options: options))
        nextID += 1
        conns.append(c)
        return c
    }

    private func close(_ c: Conn) {
        c.retry?.cancel()
        c.channel.invalidate()
        c.sink?.close()
        conns.removeAll { $0 === c }
    }

    private func nextWork() -> HLSWork? {
        guard let job = item.record.hls else { return nil }
        let busy = Set(conns.compactMap(\.work)).union(waiting)
        for w in job.allWork {
            guard let p = job.part(w), !p.done, !p.external, !busy.contains(w) else { continue }
            return w
        }
        return nil
    }

    private func fill() {
        guard !stopped else { return }
        while conns.count < limit, let w = nextWork() {
            request(makeConn(), w)
        }
        checkIdle()
        manager?.itemChanged(item)
    }

    private var headers: [String: String] {
        var h = item.record.headers
        if h.keys.first(where: { $0.lowercased() == "user-agent" }) == nil { h["User-Agent"] = settings.userAgent }
        if let page = item.record.pageURL, h.keys.first(where: { $0.lowercased() == "referer" }) == nil {
            h["Referer"] = page.absoluteString
        }
        return h
    }

    private func request(_ c: Conn, _ w: HLSWork) {
        guard let part = item.record.hls?.part(w) else { return }
        let final = paths.hlsPartURL(item.record.id, track: w.track, index: w.index)
        let tmp = final.appendingPathExtension("tmp")
        do {
            c.sink = try FileSink(url: tmp, truncate: true)
        } catch {
            fail(error.localizedDescription)
            return
        }
        c.work = w
        c.tmpURL = tmp
        c.received = 0
        c.status = 0
        var req = ChannelRequest(url: part.url, headers: headers)
        if let off = part.rangeOffset, let len = part.rangeLength {
            req.rangeStart = off
            req.rangeEnd = off + len - 1
        }
        c.channel.start(req) { [weak self, weak c] event in
            guard let self, let c, !self.stopped else { return }
            self.handle(c, event)
        }
    }

    private func handle(_ c: Conn, _ event: HTTPChannel.Event) {
        guard let w = c.work else { return }
        switch event {
        case .response(let info):
            c.status = info.statusCode
            let ranged = item.record.hls?.part(w)?.rangeOffset != nil
            let ok = ranged ? (info.statusCode == 206 || (info.statusCode == 200 && item.record.hls?.part(w)?.rangeOffset == 0))
                            : info.isSuccess
            if !ok {
                failWork(c, ChannelError.http(info.statusCode))
            } else if ranged, info.statusCode == 206, let cr = info.contentRange,
                      cr.start != item.record.hls?.part(w)?.rangeOffset {
                failWork(c, ChannelError.badRange(info.header("content-range") ?? ""))
            }
        case .data(let data):
            var chunk = data
            if let len = item.record.hls?.part(w)?.rangeLength {
                // 200으로 통째로 오면 필요한 앞부분만
                let room = max(0, len - c.received)
                if Int64(chunk.count) > room { chunk = chunk.prefix(Int(room)) }
            }
            guard !chunk.isEmpty else { return }
            do {
                try c.sink?.write(chunk, at: c.received)
            } catch {
                fail(error.localizedDescription)
                return
            }
            c.received += Int64(chunk.count)
            let now = Date.monotonicNow
            c.meter.add(Int64(chunk.count), now: now)
            item.meter.add(Int64(chunk.count), now: now)
            if let len = item.record.hls?.part(w)?.rangeLength, c.received >= len {
                c.channel.cancel()
                partDone(c, w)
            }
        case .finished(let error):
            if let error {
                failWork(c, error)
            } else if let len = item.record.hls?.part(w)?.rangeLength, c.received < len {
                failWork(c, ChannelError.shortRead)
            } else {
                partDone(c, w)
            }
        }
    }

    private func partDone(_ c: Conn, _ w: HLSWork) {
        c.sink?.close()
        c.sink = nil
        let final = paths.hlsPartURL(item.record.id, track: w.track, index: w.index)
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            if let tmp = c.tmpURL { try fm.moveItem(at: tmp, to: final) }
        } catch {
            fail(error.localizedDescription)
            return
        }
        let bytes = c.received
        item.record.hls?.update(w) {
            $0.done = true
            $0.bytes = bytes
        }
        item.dirty = true
        c.work = nil
        c.tmpURL = nil
        c.failures = 0
        partFailures[w] = nil
        if item.record.hls?.isComplete == true {
            finish()
            return
        }
        if let next = nextWork() {
            request(c, next)
        } else {
            close(c)
            checkIdle()
        }
        manager?.itemChanged(item)
    }

    private func failWork(_ c: Conn, _ error: Error) {
        guard !stopped, let w = c.work else { return }
        c.channel.cancel()
        c.sink?.close()
        c.sink = nil
        if let tmp = c.tmpURL { try? FileManager.default.removeItem(at: tmp) }
        c.work = nil
        c.failures += 1
        let n = (partFailures[w] ?? 0) + 1
        partFailures[w] = n
        if n > settings.maxRetries {
            fail("조각 \(w.index + 1)번을 못 받았어요: \(error.localizedDescription)")
            return
        }
        // 조각을 잠깐 쉬게 하고 이 연결은 다른 조각부터
        waiting.insert(w)
        let delay = min(30, 0.5 * pow(2, Double(n - 1)))
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.waiting.remove(w)
            self.fill()
        }
        queue.asyncAfter(deadline: .now() + delay, execute: work)
        if let next = nextWork() {
            request(c, next)
        } else {
            close(c)
        }
        manager?.itemChanged(item)
    }

    /// 받을 게 남았는데 연결이 하나도 없으면(전부 백그라운드가 받는 중) 그냥 기다린다.
    private func checkIdle() {}

    private func fail(_ message: String) {
        stop()
        manager?.runnerFinished(item, .failed(message))
    }

    private func finish() {
        stop()
        manager?.runnerFinished(item, .needsProcessing)
    }

    func connectionSnapshots(now: Double) -> [ConnectionSnapshot] {
        conns.map { c in
            ConnectionSnapshot(id: c.id, rangeStart: Int64(c.work?.index ?? -1), rangeEnd: 0, received: c.received,
                               speed: c.meter.bytesPerSecond(now: now),
                               note: c.work.map { ($0.track == .audio ? "오디오 " : "") + ($0.index < 0 ? "init" : "조각 \($0.index + 1)") })
        }
    }
}
