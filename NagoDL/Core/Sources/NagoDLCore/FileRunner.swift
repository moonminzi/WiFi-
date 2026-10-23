import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 다운로드 한 건을 실제로 받는 쪽(포그라운드). 매니저 큐에서만 돈다.
protocol Runner: AnyObject {
    func start()
    /// 연결을 모두 끊는다(상태는 매니저가 정한다)
    func stop()
    var activeConnections: Int { get }
    var busyKeys: Set<Int64> { get }
    func connectionSnapshots(now: Double) -> [ConnectionSnapshot]
}

enum RunnerOutcome {
    case completed
    /// HLS: 조각을 다 받아서 합칠 차례
    case needsProcessing
    case failed(String)
}

/// 일반 파일: 여러 연결로 구간을 나눠 받고, 먼저 끝난 연결은 남은 구간을 쪼개 가져간다.
final class FileRunner: Runner {
    private final class Conn {
        let id: Int
        let channel: HTTPChannel
        /// 맡은 구간(start로 찾는다). nil이면 쉬는 중/재시도 대기
        var segment: Int64?
        /// 이 응답에서 다음에 올 바이트의 파일 위치
        var position: Int64 = 0
        var requestStart: Int64 = 0
        var gotResponse = false
        var failures = 0
        var meter = SpeedMeter(window: 3)
        var retry: DispatchWorkItem?
        var note: String?
        /// 요청이 나가 있는 중(응답·데이터를 기다림)
        var inFlight = false
        /// 마지막으로 뭔가(응답·데이터) 받은 때
        var lastProgress: Double = 0

        init(id: Int, channel: HTTPChannel) {
            self.id = id
            self.channel = channel
        }
    }

    private weak var manager: DownloadManager?
    private let item: DownloadManager.Item
    private let queue: DispatchQueue
    private let settings: EngineSettings
    private let planner: SegmentPlanner
    private let partialURL: URL
    private var sink: FileSink?
    private var conns: [Conn] = []
    private var nextID = 1
    private var stopped = true
    private var connectionLimit: Int
    private var triedSourceAgain = false
    private var watchdog: DispatchSourceTimer?

    init(manager: DownloadManager, item: DownloadManager.Item, settings: EngineSettings, partialURL: URL) {
        self.manager = manager
        self.item = item
        self.queue = manager.queue
        self.settings = settings
        self.planner = SegmentPlanner(minPiece: settings.minPieceBytes)
        self.partialURL = partialURL
        self.connectionLimit = max(1, item.record.maxConnections)
    }

    private var record: DownloadRecord {
        get { item.record }
        set { item.record = newValue }
    }

    var activeConnections: Int { conns.filter { $0.segment != nil }.count }

    var busyKeys: Set<Int64> { Set(conns.compactMap(\.segment)) }

    // MARK: 시작/정지

    func start() {
        guard stopped else { return }
        stopped = false
        do {
            let fresh = record.isFresh || !FileManager.default.fileExists(atPath: partialURL.path)
            if fresh && !record.isFresh {
                // 받던 파일이 사라졌다 — 처음부터
                resetProgress()
            }
            sink = try FileSink(url: partialURL, truncate: fresh)
        } catch {
            fail(error.localizedDescription)
            return
        }
        startWatchdog()
        if record.isFresh {
            startProbe()
        } else {
            SegmentPlanner.compact(&record.segments, busy: [])
            if record.segments.allSatisfy(\.isDone) && !record.segments.isEmpty {
                complete()
                return
            }
            fill()
        }
    }

    /// 멈춘 연결 찾기: 한동안 아무것도 안 온 연결은 끊고 다시(모바일망에서 TCP가 그냥 멈추는 일이 잦다)
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let every = max(0.5, min(2, settings.stallTimeout / 4))
        t.schedule(deadline: .now() + every, repeating: every)
        t.setEventHandler { [weak self] in self?.checkStalls() }
        t.resume()
        watchdog = t
    }

    private func checkStalls() {
        guard !stopped else { return }
        let now = Date.monotonicNow
        for c in conns where c.inFlight && now - c.lastProgress > settings.stallTimeout {
            failConn(c, ChannelError.stalled)
        }
    }

    func stop() {
        stopped = true
        watchdog?.cancel()
        watchdog = nil
        for c in conns {
            c.retry?.cancel()
            c.channel.invalidate()
        }
        conns.removeAll()
        sink?.close()
        sink = nil
    }

    // MARK: 연결

    private func makeConn() -> Conn {
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
        conns.removeAll { $0 === c }
    }

    private var requestHeaders: [String: String] {
        var h = record.headers
        if h.keys.first(where: { $0.lowercased() == "user-agent" }) == nil { h["User-Agent"] = settings.userAgent }
        if let page = record.pageURL, h.keys.first(where: { $0.lowercased() == "referer" }) == nil {
            h["Referer"] = page.absoluteString
        }
        return h
    }

    private func index(of start: Int64) -> Int? {
        record.segments.firstIndex { $0.start == start }
    }

    // MARK: 첫 연결(크기·이어받기 지원 확인 겸 0번 구간 받기)

    private func startProbe() {
        let c = makeConn()
        c.segment = nil
        c.position = 0
        c.requestStart = 0
        c.gotResponse = false
        c.inFlight = true
        c.lastProgress = Date.monotonicNow
        let req = ChannelRequest(url: record.requestURL, headers: requestHeaders, rangeStart: 0, rangeEnd: nil)
        c.channel.start(req) { [weak self, weak c] event in
            guard let self, let c, !self.stopped else { return }
            self.handle(c, event, probing: true)
        }
        manager?.itemChanged(item)
    }

    private func adoptProbeResponse(_ c: Conn, _ info: HTTPResponseInfo) -> Bool {
        var total: Int64?
        switch info.statusCode {
        case 206:
            guard let cr = info.contentRange, cr.start == 0 else {
                failConn(c, ChannelError.badRange(info.header("content-range") ?? "없음"))
                return false
            }
            record.acceptsRanges = true
            total = cr.total
        case 200..<300:
            record.acceptsRanges = false
            total = info.contentLength
        case 416 where ContentRange.unsatisfiedTotal(info.header("content-range")) == 0:
            // 0바이트 파일에 bytes=0-를 요청하면 416이 온다
            record.acceptsRanges = true
            total = 0
        default:
            failConn(c, ChannelError.http(info.statusCode))
            return false
        }
        if let enc = info.header("content-encoding")?.lowercased(), enc != "identity", !enc.isEmpty {
            // 압축해서 보내면 구간을 못 맞춘다. 한 연결로 통째로 받는다.
            record.acceptsRanges = false
            total = nil
        }
        record.totalBytes = total
        record.validator = info.validator
        record.mimeType = info.mimeType
        if let url = info.url, url != record.sourceURL { record.resolvedURL = url }
        if !record.nameLocked {
            record.fileName = FileNamer.suggestedName(url: info.url ?? record.sourceURL,
                                                      contentDisposition: info.header("content-disposition"),
                                                      mimeType: info.mimeType)
        }
        if let total {
            if total == 0 {
                record.segments = [Segment(start: 0, end: -1)]
            } else if record.acceptsRanges {
                record.segments = planner.initialSegments(total: total, connections: connectionLimit)
            } else {
                record.segments = [Segment(start: 0, end: total - 1)]
            }
        } else {
            record.segments = [Segment(start: 0, end: Int64.max)]
        }
        c.segment = record.segments.first?.start
        c.position = 0
        c.requestStart = 0
        manager?.itemChanged(item, save: true)
        return true
    }

    // MARK: 구간 요청

    private func request(_ c: Conn, segmentStart: Int64) {
        guard let i = index(of: segmentStart) else { return }
        if !record.acceptsRanges && record.segments[i].received > 0 {
            // 이어받기가 안 되는 서버는 처음부터
            record.segments[i].received = 0
            try? sink?.truncate(to: 0)
        }
        let s = record.segments[i]
        c.segment = s.start
        c.position = s.next
        c.requestStart = s.next
        c.gotResponse = false
        c.note = nil
        c.inFlight = true
        c.lastProgress = Date.monotonicNow
        var req = ChannelRequest(url: record.requestURL, headers: requestHeaders)
        if record.acceptsRanges {
            req.rangeStart = s.next
            req.rangeEnd = s.end == Int64.max ? nil : s.end
            req.ifRange = record.validator
        }
        c.channel.start(req) { [weak self, weak c] event in
            guard let self, let c, !self.stopped else { return }
            self.handle(c, event, probing: false)
        }
    }

    private func handle(_ c: Conn, _ event: HTTPChannel.Event, probing: Bool) {
        switch event {
        case .response(let info):
            c.gotResponse = true
            c.lastProgress = Date.monotonicNow
            if probing {
                if adoptProbeResponse(c, info) { fill() }
                return
            }
            checkResponse(c, info)
        case .data(let data):
            c.lastProgress = Date.monotonicNow
            receive(c, data)
        case .finished(let error):
            c.inFlight = false
            finished(c, error)
        }
    }

    private func checkResponse(_ c: Conn, _ info: HTTPResponseInfo) {
        if record.acceptsRanges {
            switch info.statusCode {
            case 206:
                guard let cr = info.contentRange, cr.start == c.requestStart else {
                    failConn(c, ChannelError.badRange(info.header("content-range") ?? "없음"))
                    return
                }
                if let known = record.totalBytes, let t = cr.total, t != known {
                    restartFresh("서버 파일 크기가 바뀌어서 처음부터 다시 받아요")
                    return
                }
            case 200:
                // If-Range가 안 맞음(파일이 바뀜) 또는 서버가 Range를 무시함
                restartFresh("서버 파일이 바뀌어서 처음부터 다시 받아요")
            case 416:
                restartFresh("서버 파일이 바뀌어서 처음부터 다시 받아요")
            default:
                failConn(c, ChannelError.http(info.statusCode))
            }
        } else {
            guard info.isSuccess else {
                failConn(c, ChannelError.http(info.statusCode))
                return
            }
            if let t = info.contentLength, let i = c.segment.flatMap(index(of:)), record.totalBytes != t {
                record.totalBytes = t
                record.segments[i].end = t == 0 ? -1 : t - 1
            }
        }
    }

    private func receive(_ c: Conn, _ data: Data) {
        guard let start = c.segment, let i = index(of: start), c.gotResponse else { return }
        let s = record.segments[i]
        guard c.position == s.next else {
            // 이 연결이 쓰던 자리와 기록이 어긋났다 — 다시 요청
            c.channel.cancel()
            failConn(c, ChannelError.badRange("위치 어긋남"))
            return
        }
        let room = s.end == Int64.max ? Int64(data.count) : max(0, s.end - s.next + 1)
        let n = Int(min(Int64(data.count), room))
        if n > 0 {
            do {
                if n == data.count {
                    try sink?.write(data, at: s.next)
                } else {
                    try sink?.write(data.prefix(n), at: s.next)
                }
            } catch {
                fail(error.localizedDescription)
                return
            }
            record.segments[i].received += Int64(n)
            let now = Date.monotonicNow
            c.meter.add(Int64(n), now: now)
            item.meter.add(Int64(n), now: now)
            item.dirty = true
        }
        c.position += Int64(data.count)
        if record.segments[i].isDone {
            c.channel.cancel()
            c.inFlight = false
            segmentDone(c)
        }
    }

    private func finished(_ c: Conn, _ error: Error?) {
        guard let start = c.segment, let i = index(of: start) else {
            if let error { failConn(c, error) } else { assignWork(c) }
            return
        }
        if let error {
            failConn(c, error)
            return
        }
        let s = record.segments[i]
        if s.end == Int64.max {
            // 길이를 모르던 흐름이 끝남 = 다 받음
            record.segments[i].end = s.next - 1
            record.totalBytes = s.next
            segmentDone(c)
        } else if s.isDone {
            segmentDone(c)
        } else {
            failConn(c, ChannelError.shortRead)
        }
    }

    private func segmentDone(_ c: Conn) {
        c.segment = nil
        c.failures = 0
        c.note = nil
        manager?.itemChanged(item, save: true)
        if allDone {
            complete()
        } else {
            assignWork(c)
        }
    }

    private var allDone: Bool {
        !record.segments.isEmpty && record.segments.allSatisfy { $0.isDone }
    }

    /// 쉬는 연결에 일을 준다. 줄 일이 없으면 닫는다.
    private func assignWork(_ c: Conn) {
        guard !stopped else { return }
        c.retry = nil
        if conns.count > connectionLimit {
            close(c)
            return
        }
        if record.isFresh {
            // 첫 응답 전에 실패했다 — 다시 확인부터
            close(c)
            if conns.isEmpty { startProbe() }
            return
        }
        var busy = busyKeys
        busy.remove(c.segment ?? -1)
        let canSplit = record.acceptsRanges && record.totalBytes != nil
        var segments = record.segments
        let pick: Int64?
        if canSplit {
            pick = planner.pickWork(&segments, busy: busy)
        } else {
            pick = segments.first(where: { !$0.isDone && !$0.external && !busy.contains($0.start) })?.start
        }
        record.segments = segments
        if let pick {
            request(c, segmentStart: pick)
        } else {
            close(c)
        }
        manager?.itemChanged(item)
    }

    /// 연결 수가 모자라면 채운다.
    private func fill() {
        guard !stopped, !record.isFresh else { return }
        let limit = (record.acceptsRanges && record.totalBytes != nil) ? connectionLimit : 1
        while conns.count < limit {
            var segments = record.segments
            let busy = busyKeys
            let pick: Int64?
            if record.acceptsRanges && record.totalBytes != nil {
                pick = planner.pickWork(&segments, busy: busy)
            } else {
                pick = segments.first(where: { !$0.isDone && !$0.external && !busy.contains($0.start) })?.start
            }
            record.segments = segments
            guard let pick else { break }
            let c = makeConn()
            request(c, segmentStart: pick)
        }
        manager?.itemChanged(item)
    }

    // MARK: 실패 처리

    private func failConn(_ c: Conn, _ error: Error) {
        guard !stopped else { return }
        c.channel.cancel()
        c.inFlight = false
        c.segment = nil
        c.failures += 1
        c.note = error.localizedDescription
        let active = conns.filter { $0 !== c && ($0.segment != nil || $0.retry != nil) }.count

        if let urlError = error as? URLError, urlError.code == .cancelled {
            assignWork(c)
            return
        }
        if case ChannelError.http(let code)? = error as? ChannelError {
            switch code {
            case 429, 503, 509:
                // 연결이 너무 많다는 뜻 — 하나 줄인다
                if active > 0 {
                    connectionLimit = max(1, active)
                    close(c)
                    manager?.itemChanged(item)
                    return
                }
            case 401, 403, 404, 410:
                if active > 0 {
                    // 연결 수 제한을 403으로 알리는 서버도 있다
                    connectionLimit = max(1, active)
                    close(c)
                    manager?.itemChanged(item)
                    return
                }
                if record.resolvedURL != nil && !triedSourceAgain {
                    // 리다이렉트로 받은 주소가 만료됐을 수 있다 — 원래 주소로 다시
                    triedSourceAgain = true
                    record.resolvedURL = nil
                    assignWork(c)
                    return
                }
                fail(error.localizedDescription)
                return
            default:
                break
            }
        }
        if c.failures > settings.maxRetries {
            if active > 0 {
                close(c)
                manager?.itemChanged(item)
            } else {
                fail(error.localizedDescription)
            }
            return
        }
        // 멈춤은 그 연결만의 문제인 경우가 많아서 처음 몇 번은 바로 새 연결로
        let stalled = (error as? ChannelError) == .stalled
        let delay = stalled && c.failures <= 3 ? 0.1 : min(30, 0.5 * pow(2, Double(c.failures - 1)))
        let work = DispatchWorkItem { [weak self, weak c] in
            guard let self, let c, !self.stopped else { return }
            c.retry = nil
            self.assignWork(c)
        }
        c.retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
        manager?.itemChanged(item)
    }

    private func restartFresh(_ reason: String) {
        record.restarts += 1
        if record.restarts > 2 {
            fail("서버가 이어받기를 제대로 지원하지 않아요")
            return
        }
        for c in conns {
            c.retry?.cancel()
            c.channel.invalidate()
        }
        conns.removeAll()
        resetProgress()
        try? sink?.truncate(to: 0)
        manager?.note(item, reason)
        startProbe()
    }

    private func resetProgress() {
        record.segments = []
        record.totalBytes = nil
        record.validator = nil
        record.acceptsRanges = false
        record.resolvedURL = nil
        item.dirty = true
    }

    private func fail(_ message: String) {
        stop()
        manager?.runnerFinished(item, .failed(message))
    }

    private func complete() {
        sink?.synchronize()
        stop()
        manager?.runnerFinished(item, .completed)
    }

    // MARK: 화면용

    func connectionSnapshots(now: Double) -> [ConnectionSnapshot] {
        conns.map { c in
            let s = c.segment.flatMap { index(of: $0) }.map { record.segments[$0] }
            return ConnectionSnapshot(id: c.id, rangeStart: s?.start ?? 0, rangeEnd: s?.end ?? 0,
                                      received: s?.received ?? 0, speed: c.meter.bytesPerSecond(now: now),
                                      note: c.segment == nil ? (c.note ?? "대기") : nil)
        }
    }
}
