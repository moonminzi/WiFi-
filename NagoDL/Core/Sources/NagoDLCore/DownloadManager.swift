import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 다운로드 목록 전체를 관리한다. 모든 상태는 `queue` 한 줄에서만 바뀐다.
///
/// - 포그라운드: 다운로드마다 Runner(여러 연결)가 직접 받는다.
/// - 백그라운드: 앱이 화면에서 내려가기 전에 `detachForBackground()`로 남은 구간을 잘라
///   백그라운드 URLSession(앱 쪽 코드)에 넘기고, 끝난 조각은 `externalFinished`로 돌려받는다.
public final class DownloadManager {
    final class Item {
        var record: DownloadRecord
        var runner: Runner?
        var meter = SpeedMeter()
        var dirty = false
        var lastSave: Double = 0
        var note: String?
        var externalProgress: [ExternalKey: Int64] = [:]
        var processing = false
        var processingProgress: Double?

        init(record: DownloadRecord) {
            self.record = record
        }
    }

    public let queue = DispatchQueue(label: "nago.dl.engine", qos: .userInitiated)
    public let paths: EnginePaths
    /// 화면 갱신(메인 스레드, 최대 초당 5번)
    public var onSnapshots: (([DownloadSnapshot]) -> Void)?
    /// 완료/실패 알림(메인 스레드)
    public var onEvent: ((DownloadEvent) -> Void)?
    /// 이 다운로드의 백그라운드 작업을 취소해 달라(일시정지·삭제할 때, 메인 스레드)
    public var onCancelExternal: ((UUID) -> Void)?
    /// HLS 조각을 하나로 합치는 방법(앱이 바꿀 수 있다)
    public var assembler: HLSAssembling = DefaultHLSAssembler()

    private var settings: EngineSettings
    private var items: [UUID: Item] = [:]
    private var order: [UUID] = []
    /// 앱이 화면에 나와 있을 때만 포그라운드 연결을 띄운다(백그라운드로 깨어났을 땐 안 띄움).
    /// 처음엔 꺼져 있고 앱이 `resumeForeground()`로 켠다.
    private var foreground = false
    private var emitScheduled = false
    private var ticker: DispatchSourceTimer?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public init(paths: EnginePaths = .standard(), settings: EngineSettings = EngineSettings()) {
        self.paths = paths
        self.settings = settings
    }

    // MARK: - 불러오기 / 저장

    /// 저장된 기록을 읽는다. 앱 시작할 때 한 번(백그라운드 세션을 만들기 전에).
    public func load() {
        queue.sync {
            try? paths.prepare()
            let fm = FileManager.default
            let decoder = JSONDecoder()
            let files = (try? fm.contentsOfDirectory(at: paths.records, includingPropertiesForKeys: nil)) ?? []
            var loaded: [DownloadRecord] = []
            for url in files where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(DownloadRecord.self, from: data) else { continue }
                loaded.append(record)
            }
            loaded.sort { $0.createdAt < $1.createdAt }
            for var r in loaded {
                if r.status == .processing && r.kind == .file { r.status = .queued }
                let item = Item(record: r)
                items[r.id] = item
                order.append(r.id)
            }
        }
        queue.async { self.emitNow() }
    }

    private func save(_ item: Item) {
        item.dirty = false
        item.lastSave = Date.monotonicNow
        var r = item.record
        SegmentPlanner.compact(&r.segments, busy: item.runner?.busyKeys ?? [])
        guard let data = try? encoder.encode(r) else { return }
        try? data.write(to: paths.recordURL(r.id), options: .atomic)
    }

    // MARK: - 바깥에서 부르는 것들

    public func update(settings: EngineSettings) {
        queue.async {
            self.settings = settings
            self.schedule()
        }
    }

    @discardableResult
    public func add(_ new: NewDownload) -> UUID {
        let id = UUID()
        queue.async {
            let name = FileNamer.sanitize(new.fileName ?? FileNamer.suggestedName(url: new.url))
            var record = DownloadRecord(id: id, kind: new.hls == nil ? .file : .hls, sourceURL: new.url,
                                        pageURL: new.pageURL, headers: new.headers, fileName: name,
                                        maxConnections: max(1, min(32, new.connections ?? self.settings.defaultConnections)),
                                        hls: new.hls, nameLocked: new.fileName != nil)
            record.status = new.startPaused ? .paused : .queued
            let item = Item(record: record)
            self.items[id] = item
            self.order.append(id)
            self.save(item)
            self.schedule()
            self.emitSoon()
        }
        return id
    }

    public func pause(_ id: UUID) {
        queue.async {
            guard let item = self.items[id], item.record.status == .running || item.record.status == .queued else { return }
            self.stopRunner(item)
            self.dropExternal(item)
            item.record.status = .paused
            item.note = nil
            self.save(item)
            self.schedule()
            self.emitSoon()
        }
    }

    public func resume(_ id: UUID) {
        queue.async {
            guard let item = self.items[id] else { return }
            switch item.record.status {
            case .paused, .failed:
                item.record.status = item.record.kind == .hls && item.record.hls?.isComplete == true ? .processing : .queued
                item.record.errorMessage = nil
                item.record.restarts = 0
                item.note = nil
                self.save(item)
                if item.record.status == .processing { self.startProcessing(item) }
                self.schedule()
                self.emitSoon()
            default:
                break
            }
        }
    }

    public func pauseAll() {
        queue.async {
            for id in self.order { if let i = self.items[id], i.record.status == .running || i.record.status == .queued { self.pause(id) } }
        }
    }

    public func resumeAll() {
        queue.async {
            for id in self.order { if let i = self.items[id], i.record.status == .paused || i.record.status == .failed { self.resume(id) } }
        }
    }

    /// 목록에서 지운다. deleteFile이면 받은 파일도 지운다.
    public func remove(_ id: UUID, deleteFile: Bool) {
        queue.async {
            guard let item = self.items[id] else { return }
            self.stopRunner(item)
            self.dropExternal(item)
            let fm = FileManager.default
            try? fm.removeItem(at: self.paths.recordURL(id))
            try? fm.removeItem(at: self.paths.partialURL(id))
            try? fm.removeItem(at: self.paths.hlsDir(id))
            if deleteFile, let saved = item.record.savedName {
                try? fm.removeItem(at: self.paths.output.appendingPathComponent(saved))
            }
            self.items[id] = nil
            self.order.removeAll { $0 == id }
            self.schedule()
            self.emitSoon()
        }
    }

    /// 완료된 것을 목록에서만 지운다(파일은 남김).
    public func clearCompleted() {
        queue.async {
            for id in self.order where self.items[id]?.record.status == .completed {
                try? FileManager.default.removeItem(at: self.paths.recordURL(id))
                self.items[id] = nil
            }
            self.order.removeAll { self.items[$0] == nil }
            self.emitSoon()
        }
    }

    /// 링크가 만료됐을 때 새 주소로 바꿔서 이어받기(같은 파일이어야 한다)
    public func updateURL(_ id: UUID, url: URL) {
        queue.async {
            guard let item = self.items[id] else { return }
            let wasRunning = item.runner != nil
            self.stopRunner(item)
            item.record.sourceURL = url
            item.record.resolvedURL = nil
            item.record.errorMessage = nil
            item.record.restarts = 0
            if item.record.status == .failed || wasRunning { item.record.status = .queued }
            self.save(item)
            self.schedule()
            self.emitSoon()
        }
    }

    public func rename(_ id: UUID, to name: String) {
        queue.async {
            guard let item = self.items[id] else { return }
            let clean = FileNamer.sanitize(name)
            if item.record.status == .completed, let saved = item.record.savedName {
                let unique = FileNamer.uniqueName(clean, in: self.paths.output)
                let fm = FileManager.default
                do {
                    try fm.moveItem(at: self.paths.output.appendingPathComponent(saved),
                                    to: self.paths.output.appendingPathComponent(unique))
                    item.record.savedName = unique
                    item.record.fileName = unique
                } catch {
                    item.note = error.localizedDescription
                }
            } else {
                item.record.fileName = clean
                item.record.nameLocked = true
            }
            self.save(item)
            self.emitSoon()
        }
    }

    /// 앱이 끝날 때: 연결을 끊고 기록을 저장한다. 상태는 그대로 둬서 다음에 켜면 이어서 받는다.
    public func persistAndStop() {
        queue.sync {
            for item in items.values {
                item.runner?.stop()
                item.runner = nil
                save(item)
            }
            foreground = false
            updateTicker()
        }
    }

    public func snapshots() -> [DownloadSnapshot] {
        queue.sync { buildSnapshots() }
    }

    public func record(_ id: UUID) -> DownloadRecord? {
        queue.sync { items[id]?.record }
    }

    // MARK: - 순서 정하기

    /// 대기 중인 걸 동시 실행 한도까지 시작하고, 돌아야 하는데 멈춰 있는 Runner를 다시 띄운다.
    private func schedule() {
        guard foreground else { return }
        var running = order.compactMap { items[$0] }.filter { $0.record.status == .running }.count
        for id in order {
            guard let item = items[id] else { continue }
            if item.record.status == .running && item.runner == nil && hasForegroundWork(item) {
                startRunner(item)
            }
        }
        for id in order where running < settings.maxActiveDownloads {
            guard let item = items[id], item.record.status == .queued else { continue }
            item.record.status = .running
            item.record.errorMessage = nil
            running += 1
            save(item)
            startRunner(item)
        }
        for id in order {
            guard let item = items[id], item.record.status == .processing, !item.processing else { continue }
            startProcessing(item)
        }
        updateTicker()
    }

    private func hasForegroundWork(_ item: Item) -> Bool {
        let r = item.record
        switch r.kind {
        case .file:
            return r.isFresh || r.segments.contains { !$0.isDone && !$0.external }
        case .hls:
            guard let job = r.hls else { return false }
            return job.allWork.contains { w in
                guard let p = job.part(w) else { return false }
                return !p.done && !p.external
            }
        }
    }

    private func startRunner(_ item: Item) {
        guard item.runner == nil else { return }
        guard hasForegroundWork(item) else {
            // 남은 건 모두 백그라운드가 받는 중
            return
        }
        let runner: Runner
        switch item.record.kind {
        case .file:
            runner = FileRunner(manager: self, item: item, settings: settings, partialURL: paths.partialURL(item.record.id))
        case .hls:
            runner = HLSRunner(manager: self, item: item, settings: settings, paths: paths)
        }
        item.runner = runner
        runner.start()
        updateTicker()
    }

    private func stopRunner(_ item: Item) {
        item.runner?.stop()
        item.runner = nil
        item.meter.reset()
    }

    // MARK: - Runner가 부르는 것들

    func itemChanged(_ item: Item, save now: Bool = false) {
        item.dirty = true
        if now { save(item) }
        emitSoon()
    }

    func note(_ item: Item, _ text: String) {
        item.note = text
        emitSoon()
    }

    func runnerFinished(_ item: Item, _ outcome: RunnerOutcome) {
        item.runner = nil
        switch outcome {
        case .completed:
            finalizeFile(item)
        case .needsProcessing:
            item.record.status = .processing
            save(item)
            if foreground { startProcessing(item) }
        case .failed(let message):
            item.record.status = .failed
            item.record.errorMessage = message
            item.meter.reset()
            save(item)
            let name = item.record.fileName
            let id = item.record.id
            DispatchQueue.main.async { self.onEvent?(.failed(id: id, name: name, message: message)) }
        }
        schedule()
        emitSoon()
    }

    /// 받는 중이던 파일을 Documents로 옮긴다.
    private func finalizeFile(_ item: Item) {
        let fm = FileManager.default
        let partial = paths.partialURL(item.record.id)
        let name = FileNamer.uniqueName(item.record.fileName, in: paths.output)
        let target = paths.output.appendingPathComponent(name)
        do {
            if !fm.fileExists(atPath: partial.path) {
                // 0바이트 파일
                fm.createFile(atPath: partial.path, contents: Data())
            }
            if let total = item.record.totalBytes {
                let size = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? -1
                if size > total {
                    let sink = try FileSink(url: partial)
                    try sink.truncate(to: total)
                    sink.close()
                }
            }
            try fm.moveItem(at: partial, to: target)
        } catch {
            item.record.status = .failed
            item.record.errorMessage = "파일을 옮기지 못했어요: \(error.localizedDescription)"
            save(item)
            emitSoon()
            return
        }
        complete(item, savedName: name)
    }

    /// 이미 받은 파일을 완료 항목으로 넣는다(큐 안에서)
    func insertCompleted(_ r: DownloadRecord, savedName: String) {
        var record = r
        record.savedName = savedName
        record.status = .completed
        record.completedAt = Date()
        let item = Item(record: record)
        items[record.id] = item
        order.append(record.id)
        save(item)
        let id = record.id
        DispatchQueue.main.async { self.onEvent?(.completed(id: id, name: savedName)) }
        emitSoon()
    }

    private func complete(_ item: Item, savedName: String) {
        item.record.savedName = savedName
        item.record.status = .completed
        item.record.completedAt = Date()
        item.record.errorMessage = nil
        item.note = nil
        item.meter.reset()
        item.externalProgress.removeAll()
        if item.record.kind == .file {
            let total = item.record.totalBytes ?? item.record.doneBytes
            item.record.segments = total > 0 ? [Segment(start: 0, end: total - 1, received: total)] : []
            item.record.totalBytes = total
        }
        save(item)
        let id = item.record.id
        DispatchQueue.main.async { self.onEvent?(.completed(id: id, name: savedName)) }
        schedule()
        emitSoon()
    }

    // MARK: - HLS 합치기

    private func startProcessing(_ item: Item) {
        guard !item.processing, let job = item.record.hls else { return }
        item.processing = true
        item.processingProgress = 0
        let id = item.record.id
        let dir = paths.hlsDir(id)
        let baseName = item.record.fileName
        let assembler = self.assembler
        let paths = self.paths
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try assembler.assemble(job: job, id: id, paths: paths, workDir: dir) { p in
                    self.queue.async {
                        item.processingProgress = p
                        self.emitSoon()
                    }
                }
            }
            self.queue.async {
                item.processing = false
                guard self.items[id] != nil, item.record.status == .processing else {
                    if case .success(let out) = result { try? FileManager.default.removeItem(at: out.url) }
                    return
                }
                switch result {
                case .success(let out):
                    let name = FileNamer.uniqueName(FileNamer.replacingExtension(baseName, with: out.fileExtension), in: paths.output)
                    do {
                        try FileManager.default.moveItem(at: out.url, to: paths.output.appendingPathComponent(name))
                        try? FileManager.default.removeItem(at: dir)
                        item.record.totalBytes = (try? FileManager.default.attributesOfItem(atPath: paths.output.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value
                        self.complete(item, savedName: name)
                        if let note = out.note { item.note = note }
                    } catch {
                        item.record.status = .failed
                        item.record.errorMessage = "파일을 옮기지 못했어요: \(error.localizedDescription)"
                        self.save(item)
                    }
                case .failure(let error):
                    item.record.status = .failed
                    item.record.errorMessage = "합치기 실패: \(error.localizedDescription)"
                    self.save(item)
                    let name = item.record.fileName
                    let message = item.record.errorMessage ?? ""
                    DispatchQueue.main.async { self.onEvent?(.failed(id: id, name: name, message: message)) }
                }
                self.emitSoon()
            }
        }
        emitSoon()
    }

    // MARK: - 백그라운드 넘기기

    /// 앱이 화면에서 내려갈 때. 포그라운드 연결을 끊고 남은 일을 백그라운드 작업으로 돌려준다.
    /// 이어받기가 안 되는 서버(Range 없음)는 넘기지 않는다.
    public func detachForBackground() -> [ExternalJob] {
        queue.sync {
            foreground = false
            var jobs: [ExternalJob] = []
            for id in order {
                guard let item = items[id] else { continue }
                let status = item.record.status
                guard status == .running || status == .queued else { continue }
                jobs += handOff(item)
            }
            updateTicker()
            return jobs
        }
    }

    /// 앱이 백그라운드에 있는 동안 실패한 작업을 다시 넘길 때도 쓴다.
    public func pendingJobs() -> [ExternalJob] {
        queue.sync {
            guard !foreground else { return [] }
            var jobs: [ExternalJob] = []
            for id in order {
                guard let item = items[id], item.record.status == .running || item.record.status == .queued else { continue }
                jobs += handOff(item)
            }
            return jobs
        }
    }

    private func handOff(_ item: Item) -> [ExternalJob] {
        var r = item.record
        var jobs: [ExternalJob] = []
        let headers = jobHeaders(r)
        switch r.kind {
        case .file:
            if r.isFresh {
                // 크기도 모름 — 파일 전체를 한 작업으로
                stopRunner(item)
                r.segments = [Segment(start: 0, end: Int64.max, received: 0, external: true)]
                let key = ExternalKey(download: r.id, kind: .whole, a: 0, b: 0)
                jobs.append(ExternalJob(key: key, url: r.requestURL, headers: headers))
            } else if r.acceptsRanges, let total = r.totalBytes {
                stopRunner(item)
                let remaining = r.segments.filter { !$0.isDone && !$0.external }.reduce(Int64(0)) { $0 + $1.remaining }
                guard remaining > 0 else { break }
                let perConn = remaining / Int64(max(1, r.maxConnections) * 4)
                let chunk = min(max(perConn, 8 << 20), max(settings.backgroundChunkBytes, 8 << 20))
                // 이미 넘긴 구간(살아 있는 작업)은 다시 만들지 않는다
                let before = Set(r.segments.filter(\.external).map(\.start))
                r.segments = SegmentPlanner.chunkForBackground(r.segments, chunk: chunk)
                for s in r.segments where s.external && !before.contains(s.start) {
                    var h = headers
                    h["Range"] = "bytes=\(s.start)-\(s.end)"
                    if let v = r.validator { h["If-Range"] = v }
                    if total > 0 {
                        let key = ExternalKey(download: r.id, kind: .range, a: s.start, b: s.end)
                        jobs.append(ExternalJob(key: key, url: r.requestURL, headers: h))
                    }
                }
            } else {
                // 이어받기 불가: 포그라운드 연결을 그대로 둔다(잠깐 나갔다 오면 이어서 받을 수도 있다)
                return []
            }
        case .hls:
            guard var job = r.hls else { return [] }
            stopRunner(item)
            for w in job.allWork {
                guard let p = job.part(w), !p.done, !p.external else { continue }
                job.update(w) { $0.external = true }
                var h = headers
                if let off = p.rangeOffset, let len = p.rangeLength { h["Range"] = "bytes=\(off)-\(off + len - 1)" }
                let key = ExternalKey(download: r.id, kind: .hls, a: Int64(w.track.rawValue), b: Int64(w.index))
                jobs.append(ExternalJob(key: key, url: p.url, headers: h))
            }
            r.hls = job
        }
        if !jobs.isEmpty && r.status == .queued { r.status = .running }
        item.record = r
        save(item)
        return jobs
    }

    private func jobHeaders(_ r: DownloadRecord) -> [String: String] {
        var h = r.headers
        if h.keys.first(where: { $0.lowercased() == "user-agent" }) == nil { h["User-Agent"] = settings.userAgent }
        if let page = r.pageURL, h.keys.first(where: { $0.lowercased() == "referer" }) == nil { h["Referer"] = page.absoluteString }
        h["Accept-Encoding"] = "identity"
        return h
    }

    /// 백그라운드 작업 진행(화면 표시용)
    public func externalProgress(_ key: ExternalKey, received: Int64) {
        queue.async {
            guard let item = self.items[key.download] else { return }
            let before = item.externalProgress[key] ?? 0
            item.externalProgress[key] = received
            if received > before { item.meter.add(received - before, now: Date.monotonicNow) }
            self.emitSoon()
        }
    }

    /// 백그라운드 작업이 받은 파일을 넘겨받는다. URLSession delegate 안에서 동기로 불러야 한다(파일이 곧 지워진다).
    @discardableResult
    public func externalFinished(_ key: ExternalKey, file: URL, statusCode: Int, contentRange: String?,
                                 mimeType: String?) -> Bool {
        queue.sync {
            guard let item = items[key.download] else { return false }
            item.externalProgress[key] = nil
            let ok: Bool
            switch key.kind {
            case .range: ok = acceptRange(item, key, file: file, statusCode: statusCode, contentRange: contentRange)
            case .hls: ok = acceptHLS(item, key, file: file, statusCode: statusCode)
            case .whole: ok = acceptWhole(item, file: file, statusCode: statusCode, mimeType: mimeType)
            }
            emitSoon()
            return ok
        }
    }

    private func acceptRange(_ item: Item, _ key: ExternalKey, file: URL, statusCode: Int, contentRange: String?) -> Bool {
        guard let i = item.record.segments.firstIndex(where: { $0.start == key.a && $0.end == key.b && $0.external }) else {
            return false
        }
        let length = key.b - key.a + 1
        let cr = ContentRange.parse(contentRange)
        let full = statusCode == 200 && key.a == 0 && item.record.totalBytes == length
        let ranged = statusCode == 206 && cr?.start == key.a && cr?.end == key.b
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard (full || ranged), size == length else {
            item.record.segments[i].external = false
            if statusCode == 200 || statusCode == 416 {
                // 서버 파일이 바뀌었다 — 포그라운드로 돌아오면 처음부터
                item.note = "서버 파일이 바뀐 것 같아요"
            }
            save(item)
            return false
        }
        do {
            let sink = try FileSink(url: paths.partialURL(item.record.id))
            defer { sink.close() }
            _ = try sink.copy(from: file, at: key.a, expectedLength: length)
            sink.synchronize()
        } catch {
            item.record.segments[i].external = false
            item.note = error.localizedDescription
            save(item)
            return false
        }
        item.record.segments[i].received = length
        item.record.segments[i].external = false
        save(item)
        if item.record.segments.allSatisfy(\.isDone) {
            stopRunner(item)
            finalizeFile(item)
        }
        return true
    }

    private func acceptHLS(_ item: Item, _ key: ExternalKey, file: URL, statusCode: Int) -> Bool {
        guard let track = HLSTrack(rawValue: Int(key.a)), var job = item.record.hls else { return false }
        let w = HLSWork(track: track, index: Int(key.b))
        guard let part = job.part(w), part.external else { return false }
        guard (200..<300).contains(statusCode) else {
            job.update(w) { $0.external = false }
            item.record.hls = job
            save(item)
            return false
        }
        let target = paths.hlsPartURL(item.record.id, track: track, index: w.index)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: paths.hlsDir(item.record.id), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: file, to: target)
        } catch {
            job.update(w) { $0.external = false }
            item.record.hls = job
            save(item)
            return false
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
        job.update(w) {
            $0.done = true
            $0.external = false
            $0.bytes = size
        }
        item.record.hls = job
        if job.isComplete {
            stopRunner(item)
            item.record.status = .processing
            save(item)
            if foreground { startProcessing(item) }
        } else {
            save(item)
        }
        return true
    }

    private func acceptWhole(_ item: Item, file: URL, statusCode: Int, mimeType: String?) -> Bool {
        guard item.record.segments.first?.external == true else { return false }
        guard (200..<300).contains(statusCode) else {
            item.record.segments = []
            item.record.status = .failed
            item.record.errorMessage = ChannelError.http(statusCode).localizedDescription
            save(item)
            return false
        }
        let fm = FileManager.default
        let partial = paths.partialURL(item.record.id)
        do {
            if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
            try fm.moveItem(at: file, to: partial)
        } catch {
            item.record.segments = []
            save(item)
            return false
        }
        let size = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
        item.record.totalBytes = size
        item.record.mimeType = mimeType ?? item.record.mimeType
        item.record.segments = size > 0 ? [Segment(start: 0, end: size - 1, received: size)] : []
        stopRunner(item)
        finalizeFile(item)
        return true
    }

    /// 백그라운드 작업이 실패/취소됨 — 그 구간을 다시 포그라운드(또는 다음 넘기기)에 맡긴다.
    public func externalFailed(_ key: ExternalKey) {
        queue.async {
            guard let item = self.items[key.download] else { return }
            item.externalProgress[key] = nil
            self.release([key], in: item)
            self.schedule()
            self.emitSoon()
        }
    }

    /// 앱으로 돌아왔을 때 아직 시작 안 한 백그라운드 작업을 취소하고 그 구간을 되찾는다.
    public func reclaim(_ keys: [ExternalKey]) {
        queue.sync {
            for key in keys {
                guard let item = items[key.download] else { continue }
                item.externalProgress[key] = nil
                release([key], in: item)
            }
        }
    }

    private func release(_ keys: [ExternalKey], in item: Item) {
        for key in keys {
            switch key.kind {
            case .range:
                if let i = item.record.segments.firstIndex(where: { $0.start == key.a && $0.external }) {
                    item.record.segments[i].external = false
                }
            case .hls:
                if let track = HLSTrack(rawValue: Int(key.a)) {
                    item.record.hls?.update(HLSWork(track: track, index: Int(key.b))) { $0.external = false }
                }
            case .whole:
                if item.record.segments.first?.external == true { item.record.segments = [] }
            }
        }
        SegmentPlanner.compact(&item.record.segments, busy: item.runner?.busyKeys ?? [])
        save(item)
    }

    /// 앱이 새로 켜졌을 때: 살아 있는 백그라운드 작업 말고는 external 표시를 지운다.
    public func reconcileExternal(live: Set<ExternalKey>) {
        queue.sync {
            for id in order {
                guard let item = items[id] else { continue }
                var dead: [ExternalKey] = []
                for s in item.record.segments where s.external {
                    let key = s.end == Int64.max
                        ? ExternalKey(download: id, kind: .whole, a: 0, b: 0)
                        : ExternalKey(download: id, kind: .range, a: s.start, b: s.end)
                    if !live.contains(key) { dead.append(key) }
                }
                if let job = item.record.hls {
                    for w in job.allWork where job.part(w)?.external == true {
                        let key = ExternalKey(download: id, kind: .hls, a: Int64(w.track.rawValue), b: Int64(w.index))
                        if !live.contains(key) { dead.append(key) }
                    }
                }
                if !dead.isEmpty { release(dead, in: item) }
            }
        }
    }

    /// 앱이 다시 화면에 나왔다. 포그라운드 Runner를 다시 띄운다.
    public func resumeForeground() {
        queue.async {
            self.foreground = true
            for id in self.order {
                guard let item = self.items[id] else { continue }
                SegmentPlanner.compact(&item.record.segments, busy: item.runner?.busyKeys ?? [])
            }
            self.schedule()
            self.emitSoon()
        }
    }

    /// 이 다운로드를 백그라운드가 받는 중인 키들
    public func externalKeys(_ id: UUID) -> [ExternalKey] {
        queue.sync {
            guard let item = items[id] else { return [] }
            var keys: [ExternalKey] = []
            for s in item.record.segments where s.external {
                keys.append(s.end == Int64.max ? ExternalKey(download: id, kind: .whole, a: 0, b: 0)
                                               : ExternalKey(download: id, kind: .range, a: s.start, b: s.end))
            }
            if let job = item.record.hls {
                for w in job.allWork where job.part(w)?.external == true {
                    keys.append(ExternalKey(download: id, kind: .hls, a: Int64(w.track.rawValue), b: Int64(w.index)))
                }
            }
            return keys
        }
    }

    private func dropExternal(_ item: Item) {
        let hasExternal = item.record.segments.contains(where: \.external)
            || (item.record.hls?.allWork.contains { item.record.hls?.part($0)?.external == true } ?? false)
        guard hasExternal else { return }
        let id = item.record.id
        for i in item.record.segments.indices { item.record.segments[i].external = false }
        if item.record.segments.first?.end == Int64.max { item.record.segments = [] }
        if var job = item.record.hls {
            for w in job.allWork { job.update(w) { $0.external = false } }
            item.record.hls = job
        }
        item.externalProgress.removeAll()
        DispatchQueue.main.async { self.onCancelExternal?(id) }
    }

    // MARK: - 화면 갱신

    private func emitSoon() {
        guard !emitScheduled else { return }
        emitScheduled = true
        queue.asyncAfter(deadline: .now() + 0.2) {
            self.emitScheduled = false
            self.emitNow()
        }
    }

    /// 큐 안에서만 부른다
    private func emitNow() {
        guard let onSnapshots else { return }
        let built = buildSnapshots()
        DispatchQueue.main.async { onSnapshots(built) }
    }

    private func updateTicker() {
        let busy = items.values.contains { $0.runner != nil || $0.processing || !$0.externalProgress.isEmpty }
        if busy && ticker == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.5, repeating: 0.5)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            ticker = t
        } else if !busy, let t = ticker {
            t.cancel()
            ticker = nil
        }
    }

    private func tick() {
        let now = Date.monotonicNow
        for item in items.values where item.dirty && now - item.lastSave > 2 {
            save(item)
        }
        emitSoon()
        updateTicker()
    }

    private func buildSnapshots() -> [DownloadSnapshot] {
        let now = Date.monotonicNow
        return order.compactMap { id in
            guard let item = items[id] else { return nil }
            return snapshot(item, now: now)
        }
    }

    private func snapshot(_ item: Item, now: Double) -> DownloadSnapshot {
        let r = item.record
        var done = r.doneBytes
        var bars: [BarPiece] = []
        var progress: Double?
        var detail: String?
        let busy = item.runner?.busyKeys ?? []
        var external = 0

        switch r.kind {
        case .file:
            for (key, bytes) in item.externalProgress where key.kind != .hls { done += bytes }
            if let total = r.totalBytes, total > 0 {
                let t = Double(total)
                for s in r.segments where s.end != Int64.max {
                    var filled = s.received
                    if s.external {
                        external += 1
                        let key = ExternalKey(download: r.id, kind: .range, a: s.start, b: s.end)
                        filled = min(s.length, item.externalProgress[key] ?? 0)
                    }
                    bars.append(BarPiece(from: Double(s.start) / t, to: Double(s.end + 1) / t,
                                         filled: Double(s.start + filled) / t,
                                         active: busy.contains(s.start), external: s.external))
                }
                progress = min(1, Double(done) / t)
            } else if r.status == .completed {
                progress = 1
            }
            if r.status == .running && !r.isFresh && !r.acceptsRanges {
                detail = "이어받기 안 되는 서버 · 연결 1개"
            }
        case .hls:
            if let job = r.hls {
                let work = job.allWork
                let n = Double(max(1, work.count))
                var doneCount = 0
                for (i, w) in work.enumerated() {
                    guard let p = job.part(w) else { continue }
                    if p.done { doneCount += 1 }
                    if p.external { external += 1 }
                    let piece = BarPiece(from: Double(i) / n, to: Double(i + 1) / n,
                                         filled: p.done ? Double(i + 1) / n : Double(i) / n,
                                         active: busy.contains(w.key), external: p.external)
                    if var last = bars.last, last.active == piece.active, last.external == piece.external,
                       (last.filled == last.to) == (piece.filled == piece.to), last.to == piece.from {
                        last.to = piece.to
                        last.filled = piece.filled == piece.to ? piece.to : last.filled
                        bars[bars.count - 1] = last
                    } else {
                        bars.append(piece)
                    }
                }
                if let hls = item.runner as? HLSRunner { done += hls.inFlightBytes }
                for (key, bytes) in item.externalProgress where key.kind == .hls { done += bytes }
                progress = Double(doneCount) / n
                let label = job.label.map { $0 + " · " } ?? ""
                detail = "\(label)조각 \(doneCount)/\(work.count)"
                if job.audioPlaylistURL != nil { detail! += " (오디오 따로)" }
            }
            if r.status == .processing {
                let pct = Int(((item.processingProgress ?? 0) * 100).rounded())
                detail = "MP4로 합치는 중 \(pct)%"
                progress = item.processingProgress
            }
        }
        if let note = item.note, r.status != .completed || r.kind == .hls {
            detail = detail.map { $0 + " · " + note } ?? note
        }
        let speed = (r.status == .running) ? item.meter.bytesPerSecond(now: now) : 0
        return DownloadSnapshot(
            id: r.id, kind: r.kind, fileName: r.savedName ?? r.fileName, status: r.status, errorMessage: r.errorMessage,
            sourceURL: r.sourceURL, pageURL: r.pageURL,
            totalBytes: r.kind == .hls && r.status != .completed ? nil : r.totalBytes,
            doneBytes: done, speed: speed,
            activeConnections: item.runner?.activeConnections ?? 0, maxConnections: r.maxConnections,
            acceptsRanges: r.acceptsRanges, bars: bars,
            savedURL: r.savedName.map { paths.output.appendingPathComponent($0) },
            createdAt: r.createdAt, completedAt: r.completedAt, detail: detail,
            progress: r.status == .completed ? 1 : progress,
            connections: item.runner?.connectionSnapshots(now: now) ?? [],
            mimeType: r.mimeType, backgroundParts: external,
            fileMissing: r.status == .completed && r.savedName.map {
                !FileManager.default.fileExists(atPath: paths.output.appendingPathComponent($0).path)
            } ?? false)
    }
}
