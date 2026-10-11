import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NagoDLCore

/// tools/testserver.py를 띄우고 NAGODL_TEST_SERVER=http://127.0.0.1:8711 로 돌린다. 없으면 건너뛴다.
final class EngineIntegrationTests: XCTestCase {
    var server: String!
    var root: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["NAGODL_TEST_SERVER"] else {
            throw XCTSkip("NAGODL_TEST_SERVER 없음")
        }
        server = s
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nagodl-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try fetch("/reset")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: 도우미

    func paths(_ name: String = "a") -> EnginePaths {
        EnginePaths(support: root.appendingPathComponent(name + "-support"), output: root.appendingPathComponent(name + "-out"))
    }

    func fetch(_ path: String) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        var err: Error?
        let task = URLSession(configuration: .ephemeral).dataTask(with: URL(string: server + path)!) { d, _, e in
            result = d
            err = e
            sem.signal()
        }
        task.resume()
        sem.wait()
        if let err { throw err }
        return result ?? Data()
    }

    func stats(_ path: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: fetch("/stats")) as? [String: Any]
        return obj?[path] as? [String: Any] ?? [:]
    }

    func makeManager(_ p: EnginePaths, connections: Int = 8, minPiece: Int64 = 64 * 1024) -> DownloadManager {
        let settings = EngineSettings(defaultConnections: connections, maxActiveDownloads: 3, minPieceBytes: minPiece,
                                      requestTimeout: 10, maxRetries: 20)
        let m = DownloadManager(paths: p, settings: settings)
        m.load()
        m.resumeForeground()
        return m
    }

    @discardableResult
    func waitFor(_ m: DownloadManager, _ id: UUID, timeout: Double = 60,
                 until: (DownloadSnapshot) -> Bool = { $0.status == .completed || $0.status == .failed }) throws -> DownloadSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = m.snapshots().first(where: { $0.id == id }), until(s) { return s }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let s = m.snapshots().first(where: { $0.id == id })
        XCTFail("시간 초과: \(String(describing: s?.status)) \(s?.doneBytes ?? -1)/\(s?.totalBytes ?? -1) \(s?.errorMessage ?? "") \(s?.detail ?? "")")
        throw XCTSkip("timeout")
    }

    func assertFile(_ snap: DownloadSnapshot, equals path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(snap.status, .completed, snap.errorMessage ?? "", file: file, line: line)
        let url = try XCTUnwrap(snap.savedURL, file: file, line: line)
        let got = try Data(contentsOf: url)
        // 비교용 원본은 오류 주입/속도 제한 없이 받는다(내용은 size·seed로만 정해진다)
        var clean = URLComponents(string: path)!
        clean.queryItems = clean.queryItems?.filter { !["fail", "rate", "slowfirst", "maxconn", "h2fail"].contains($0.name) }
        let want = try fetch(clean.string!)
        XCTAssertEqual(got.count, want.count, "크기", file: file, line: line)
        XCTAssertTrue(got == want, "내용이 다름", file: file, line: line)
    }

    // MARK: 시험

    func testParallelIsFasterAndCorrect() throws {
        let path = "/file/big.bin?size=8000000&seed=7&rate=1000000"
        let m = makeManager(paths())
        let t0 = Date()
        let id = m.add(NewDownload(url: URL(string: server + path)!))
        let snap = try waitFor(m, id)
        let took = Date().timeIntervalSince(t0)
        try assertFile(snap, equals: path)
        let st = try stats("/file/big.bin")
        // 한 연결이면 8초, 8개면 1초 남짓
        XCTAssertLessThan(took, 4, "병렬이 효과 없음 \(took)s")
        XCTAssertGreaterThanOrEqual(st["max"] as? Int ?? 0, 6)
        XCTAssertEqual(snap.fileName, "big.bin")
        print("parallel: \(String(format: "%.2f", took))s, requests \(st["requests"] ?? 0), max \(st["max"] ?? 0)")
    }

    func testDynamicSplittingKeepsConnectionsBusy() throws {
        // 첫 연결(0번 구간)만 아주 느리다. 쪼개 가져가지 않으면 그 구간 1.5MB를 150KB/s로 10초 걸린다.
        let path = "/file/split.bin?size=6000000&seed=3&rate=1500000&slowfirst=150000"
        let m = makeManager(paths(), connections: 4)
        let t0 = Date()
        let id = m.add(NewDownload(url: URL(string: server + path)!, connections: 4))
        let snap = try waitFor(m, id)
        let took = Date().timeIntervalSince(t0)
        try assertFile(snap, equals: path)
        let st = try stats("/file/split.bin")
        XCTAssertGreaterThan(st["requests"] as? Int ?? 0, 6)
        XCTAssertLessThan(took, 5, "느린 구간을 나눠 가져가지 않음 \(took)s")
        print("split: \(String(format: "%.2f", took))s, requests \(st["requests"] ?? 0)")
    }

    func testRandomDisconnectsStillProduceExactFile() throws {
        let path = "/file/flaky.bin?size=5000000&seed=11&fail=0.35&rate=3000000"
        let m = makeManager(paths())
        let id = m.add(NewDownload(url: URL(string: server + path)!))
        let snap = try waitFor(m, id, timeout: 90)
        try assertFile(snap, equals: path)
    }

    func testTooManyConnectionsBacksOff() throws {
        let path = "/file/limited.bin?size=4000000&seed=5&maxconn=3&rate=2000000"
        let m = makeManager(paths())
        let id = m.add(NewDownload(url: URL(string: server + path)!))
        let snap = try waitFor(m, id, timeout: 60)
        try assertFile(snap, equals: path)
        XCTAssertLessThanOrEqual(try stats("/file/limited.bin")["max"] as? Int ?? 99, 3)
    }

    func testNoRangeServerUsesOneConnection() throws {
        let path = "/file/norange.bin?size=3000000&seed=9&norange=1"
        let m = makeManager(paths())
        let id = m.add(NewDownload(url: URL(string: server + path)!))
        let snap = try waitFor(m, id)
        try assertFile(snap, equals: path)
        XCTAssertFalse(snap.acceptsRanges)
        XCTAssertEqual(try stats("/file/norange.bin")["max"] as? Int, 1)
    }

    func testChunkedUnknownLength() throws {
        let path = "/file/chunked.bin?size=2500000&seed=4&chunked=1&norange=1"
        let m = makeManager(paths())
        let id = m.add(NewDownload(url: URL(string: server + path)!))
        let snap = try waitFor(m, id)
        try assertFile(snap, equals: path)
        XCTAssertEqual(snap.totalBytes, 2_500_000)
    }

    func testRedirectAndContentDispositionName() throws {
        let target = "/file/r.bin?size=3000000&seed=21&cd=" + "한글 파일.zip".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let path = "/redir?to=" + target.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let m = makeManager(paths())
        let id = m.add(NewDownload(url: URL(string: server + path)!))
        let snap = try waitFor(m, id)
        try assertFile(snap, equals: target)
        XCTAssertEqual(snap.fileName, "한글 파일.zip")
        // 조각 요청은 리다이렉트된 주소로 바로 갔어야 한다
        XCTAssertGreaterThanOrEqual(try stats("/file/r.bin")["requests"] as? Int ?? 0, 4)
    }

    func testEmptyFile() throws {
        let path = "/file/empty.bin?size=0&seed=1"
        let m = makeManager(paths())
        let id = m.add(NewDownload(url: URL(string: server + path)!))
        let snap = try waitFor(m, id)
        XCTAssertEqual(snap.status, .completed, snap.errorMessage ?? "")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(snap.savedURL)).count, 0)
    }

    func testHTTPErrorFails() throws {
        let m = makeManager(paths())
        let id = m.add(NewDownload(url: URL(string: server + "/nothing-here")!))
        let snap = try waitFor(m, id)
        XCTAssertEqual(snap.status, .failed)
        XCTAssertTrue(snap.errorMessage?.contains("404") == true, snap.errorMessage ?? "")
    }

    /// 앱이 죽었다 다시 켜진 것처럼: 기록만 남기고 매니저를 버린 뒤 새로 만든다.
    func testResumeAfterRelaunchDoesNotRestart() throws {
        let path = "/file/resume.bin?size=8000000&seed=13&rate=700000"
        let p = paths()
        var m: DownloadManager? = makeManager(p, connections: 4)
        let id = m!.add(NewDownload(url: URL(string: server + path)!, connections: 4))
        try waitFor(m!, id, timeout: 30) { $0.doneBytes > 2_500_000 }
        m!.persistAndStop()
        let before = m!.record(id)!.doneBytes
        m = nil
        Thread.sleep(forTimeInterval: 0.3)
        _ = try fetch("/reset")

        let m2 = makeManager(p, connections: 4)
        let snap = try waitFor(m2, id, timeout: 60)
        try assertFile(snap, equals: path)
        // 두 번째 실행에서 받은 양은 남은 양 정도여야 한다(처음부터 다시 받지 않음)
        let ranges = (try stats("/file/resume.bin")["ranges"] as? [Any]) ?? []
        XCTAssertFalse(ranges.contains { ($0 as? String) == "bytes=0-" }, "처음부터 다시 받음: \(ranges)")
        print("resume: had \(before) before relaunch")
    }

    /// 서버 파일이 바뀌면(ETag 다름) 처음부터 받아 새 내용이 돼야 한다.
    func testChangedFileRestarts() throws {
        let p = paths()
        let old = "/file/chg.bin?size=4000000&seed=1&etag=v1&rate=600000"
        let new = "/file/chg.bin?size=4500000&seed=2&etag=v2"
        let m = makeManager(p, connections: 4)
        let id = m.add(NewDownload(url: URL(string: server + old)!, connections: 4))
        try waitFor(m, id, timeout: 30) { $0.doneBytes > 1_000_000 }
        m.pause(id)
        try waitFor(m, id) { $0.status == .paused }
        m.updateURL(id, url: URL(string: server + new)!)
        m.resume(id)
        let snap = try waitFor(m, id, timeout: 60)
        try assertFile(snap, equals: new)
    }

    func testPauseResume() throws {
        let path = "/file/pr.bin?size=5000000&seed=17&rate=800000"
        let m = makeManager(paths(), connections: 4)
        let id = m.add(NewDownload(url: URL(string: server + path)!, connections: 4))
        try waitFor(m, id, timeout: 30) { $0.doneBytes > 1_000_000 }
        m.pause(id)
        let paused = try waitFor(m, id) { $0.status == .paused }
        Thread.sleep(forTimeInterval: 0.5)
        let still = m.snapshots().first { $0.id == id }!
        XCTAssertEqual(paused.doneBytes, still.doneBytes, "일시정지 후에도 받음")
        m.resume(id)
        let snap = try waitFor(m, id, timeout: 60)
        try assertFile(snap, equals: path)
    }

    /// 백그라운드 넘기기: 남은 구간을 작업으로 받아 따로 내려받은 뒤 돌려준다.
    func testBackgroundHandOffAndReclaim() throws {
        let path = "/file/bg.bin?size=9000000&seed=23&rate=900000"
        let m = makeManager(paths(), connections: 4)
        let id = m.add(NewDownload(url: URL(string: server + path)!, connections: 4))
        try waitFor(m, id, timeout: 30) { $0.doneBytes > 1_500_000 }
        let jobs = m.detachForBackground()
        XCTAssertFalse(jobs.isEmpty)
        // 넘긴 뒤엔 포그라운드 연결이 없어야 한다
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(m.snapshots().first { $0.id == id }?.activeConnections, 0)

        // 절반은 "시작 전"이라 되찾고, 나머지는 시스템이 받은 것처럼 직접 받아서 넘긴다
        let reclaimed = jobs.enumerated().filter { $0.offset % 2 == 1 }.map(\.element.key)
        let external = jobs.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        m.reclaim(reclaimed)
        m.resumeForeground()

        for job in external {
            var req = URLRequest(url: job.url)
            for (k, v) in job.headers { req.setValue(v, forHTTPHeaderField: k) }
            let sem = DispatchSemaphore(value: 0)
            var data: Data?
            var response: HTTPURLResponse?
            URLSession(configuration: .ephemeral).dataTask(with: req) { d, r, _ in
                data = d
                response = r as? HTTPURLResponse
                sem.signal()
            }.resume()
            sem.wait()
            let tmp = root.appendingPathComponent(UUID().uuidString)
            try XCTUnwrap(data).write(to: tmp)
            let ok = m.externalFinished(job.key, file: tmp, statusCode: response?.statusCode ?? 0,
                                        contentRange: response?.allHeaderFields["Content-Range"] as? String, mimeType: nil)
            XCTAssertTrue(ok, "\(job.key)")
        }
        let snap = try waitFor(m, id, timeout: 90)
        try assertFile(snap, equals: path)
    }

    func testBackgroundWholeFileForUnprobed() throws {
        let path = "/file/w.bin?size=1000000&seed=29"
        let m = makeManager(paths())
        m.update(settings: EngineSettings(maxActiveDownloads: 0))
        let id = m.add(NewDownload(url: URL(string: server + path)!))
        Thread.sleep(forTimeInterval: 0.3)
        let jobs = m.detachForBackground()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.key.kind, .whole)
        let data = try fetch(path)
        let tmp = root.appendingPathComponent("whole")
        try data.write(to: tmp)
        XCTAssertTrue(m.externalFinished(jobs[0].key, file: tmp, statusCode: 200, contentRange: nil, mimeType: "application/octet-stream"))
        let snap = try waitFor(m, id)
        try assertFile(snap, equals: path)
    }

    /// 백그라운드에 넘긴 뒤 일시정지: 앱에 작업 취소를 요청하고, 다시 시작하면 포그라운드가 다 받는다.
    func testPauseDropsBackgroundWork() throws {
        let path = "/file/pd.bin?size=6000000&seed=37&rate=900000"
        let m = makeManager(paths(), connections: 4)
        var cancelled: [UUID] = []
        let lock = NSLock()
        m.onCancelExternal = { id in lock.lock(); cancelled.append(id); lock.unlock() }
        let id = m.add(NewDownload(url: URL(string: server + path)!, connections: 4))
        try waitFor(m, id, timeout: 30) { $0.doneBytes > 800_000 }
        let jobs = m.detachForBackground()
        XCTAssertFalse(jobs.isEmpty)
        XCTAssertEqual(m.externalKeys(id).count, jobs.count)
        m.resumeForeground()
        m.pause(id)
        try waitFor(m, id) { $0.status == .paused }
        // onCancelExternal는 메인 큐로 온다
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            lock.lock(); let n = cancelled.count; lock.unlock()
            if n > 0 { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        lock.lock(); XCTAssertEqual(cancelled, [id]); lock.unlock()
        XCTAssertTrue(m.externalKeys(id).isEmpty)
        // 늦게 도착한 백그라운드 결과는 받지 않는다
        let tmp = root.appendingPathComponent("late")
        try Data(count: 10).write(to: tmp)
        XCTAssertFalse(m.externalFinished(jobs[0].key, file: tmp, statusCode: 206, contentRange: nil, mimeType: nil))
        m.resume(id)
        let snap = try waitFor(m, id, timeout: 60)
        try assertFile(snap, equals: path)
    }

    /// 앱이 새로 켜졌는데 일부 작업만 살아 있다: 죽은 작업의 구간은 포그라운드가 받는다.
    func testReconcileReleasesDeadTasks() throws {
        let path = "/file/rc.bin?size=7000000&seed=41&rate=900000"
        let p = paths()
        let m = makeManager(p, connections: 4)
        let id = m.add(NewDownload(url: URL(string: server + path)!, connections: 4))
        try waitFor(m, id, timeout: 30) { $0.doneBytes > 800_000 }
        let jobs = m.detachForBackground()
        XCTAssertGreaterThan(jobs.count, 1)
        m.persistAndStop()

        // 새 실행: 첫 작업만 살아 있다
        let m2 = DownloadManager(paths: p, settings: EngineSettings(defaultConnections: 4, minPieceBytes: 64 * 1024,
                                                                    requestTimeout: 10, maxRetries: 20))
        m2.load()
        let live: Set<ExternalKey> = [jobs[0].key]
        m2.reconcileExternal(live: live)
        XCTAssertEqual(m2.externalKeys(id), [jobs[0].key])
        m2.resumeForeground()
        // 살아 있던 작업이 끝났다고 치고 넘긴다
        var req = URLRequest(url: jobs[0].url)
        for (k, v) in jobs[0].headers { req.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        var response: HTTPURLResponse?
        URLSession(configuration: .ephemeral).dataTask(with: req) { d, r, _ in
            data = d
            response = r as? HTTPURLResponse
            sem.signal()
        }.resume()
        sem.wait()
        let tmp = root.appendingPathComponent("live0")
        try XCTUnwrap(data).write(to: tmp)
        XCTAssertTrue(m2.externalFinished(jobs[0].key, file: tmp, statusCode: response?.statusCode ?? 0,
                                          contentRange: response?.allHeaderFields["Content-Range"] as? String, mimeType: nil))
        let snap = try waitFor(m2, id, timeout: 60)
        try assertFile(snap, equals: path)
    }

    /// 백그라운드에서 실패한 구간은 pendingJobs로 다시 넘길 수 있어야 한다(같은 구간이 두 번 나오지 않게).
    func testPendingJobsAfterFailure() throws {
        let path = "/file/pj.bin?size=5000000&seed=43&rate=900000"
        let m = makeManager(paths(), connections: 4)
        let id = m.add(NewDownload(url: URL(string: server + path)!, connections: 4))
        try waitFor(m, id, timeout: 30) { $0.doneBytes > 600_000 }
        let jobs = m.detachForBackground()
        XCTAssertTrue(m.pendingJobs().isEmpty, "살아 있는 작업을 또 만들면 안 된다")
        m.externalFailed(jobs[0].key)
        let again = m.pendingJobs()
        XCTAssertEqual(again.map(\.key), [jobs[0].key])
        XCTAssertTrue(m.pendingJobs().isEmpty)
        _ = id
    }

    func testRefreshAddressAfterExpiry() throws {
        let p = paths()
        let first = "/file/exp.bin?size=4000000&seed=31&rate=700000"
        let m = makeManager(p, connections: 4)
        let id = m.add(NewDownload(url: URL(string: server + first)!, connections: 4))
        try waitFor(m, id, timeout: 30) { $0.doneBytes > 1_000_000 }
        m.pause(id)
        try waitFor(m, id) { $0.status == .paused }
        // 같은 내용, 다른 주소
        let second = "/file/exp2.bin?size=4000000&seed=31"
        m.updateURL(id, url: URL(string: server + second)!)
        m.resume(id)
        let snap = try waitFor(m, id, timeout: 60)
        try assertFile(snap, equals: second)
        let ranges = (try stats("/file/exp2.bin")["ranges"] as? [Any]) ?? []
        XCTAssertFalse(ranges.contains { ($0 as? String) == "bytes=0-" }, "새 주소에서 처음부터 받음")
    }
}

/// HLS 전체 흐름: 마스터 목록 → 화질 선택 → 조각 병렬 다운로드 → MP4. 시험 서버 + ffmpeg 필요.
final class HLSIntegrationTests: XCTestCase {
    var server: String!
    var serverRoot: URL!
    var work: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["NAGODL_TEST_SERVER"],
              let r = ProcessInfo.processInfo.environment["NAGODL_TEST_ROOT"] else { throw XCTSkip("시험 서버 없음") }
        guard RemuxTests.which("ffmpeg") != nil else { throw XCTSkip("ffmpeg 없음") }
        server = s
        serverRoot = URL(fileURLWithPath: r)
        work = FileManager.default.temporaryDirectory.appendingPathComponent("hls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    func ffmpeg(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: RemuxTests.which("ffmpeg")!)
        p.arguments = ["-v", "error", "-y"] + args
        p.currentDirectoryURL = dir
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, args.joined(separator: " "))
    }

    /// 서버 폴더에 hi(640x360)/lo(320x180) 두 화질 + 마스터 목록을 만든다.
    func makeFixture(_ name: String, separateAudio: Bool = false) throws -> URL {
        let dir = serverRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dir)
        for (sub, size) in [("hi", "640x360"), ("lo", "320x180")] {
            let d = dir.appendingPathComponent(sub)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var args = ["-f", "lavfi", "-i", "testsrc2=size=\(size):rate=25"]
            if !separateAudio { args += ["-f", "lavfi", "-i", "sine=frequency=700:sample_rate=44100"] }
            args += ["-t", "8", "-c:v", "libx264", "-preset", "veryfast", "-bf", "2", "-g", "50", "-pix_fmt", "yuv420p"]
            if !separateAudio { args += ["-c:a", "aac", "-b:a", "96k"] }
            args += ["-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_segment_filename", "s%03d.ts", "index.m3u8"]
            try ffmpeg(args, in: d)
        }
        var master = "#EXTM3U\n"
        if separateAudio {
            let a = dir.appendingPathComponent("audio")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=500:sample_rate=48000", "-t", "8", "-c:a", "aac", "-b:a", "96k",
                        "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_segment_filename", "a%03d.ts", "index.m3u8"], in: a)
            master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"main\",DEFAULT=YES,URI=\"audio/index.m3u8\"\n"
        }
        let audioAttr = separateAudio ? ",AUDIO=\"aud\"" : ""
        master += "#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=320x180\(audioAttr)\nlo/index.m3u8\n"
        master += "#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360\(audioAttr)\nhi/index.m3u8\n"
        try master.write(to: dir.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
        return dir
    }

    func manager() -> DownloadManager {
        let p = EnginePaths(support: work.appendingPathComponent("support"), output: work.appendingPathComponent("out"))
        let m = DownloadManager(paths: p, settings: EngineSettings(defaultConnections: 6, requestTimeout: 10, maxRetries: 10))
        m.load()
        m.resumeForeground()
        return m
    }

    func wait(_ m: DownloadManager, _ id: UUID, timeout: Double = 60,
              until: (DownloadSnapshot) -> Bool = { $0.status == .completed || $0.status == .failed }) throws -> DownloadSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = m.snapshots().first(where: { $0.id == id }), until(s) { return s }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let s = m.snapshots().first { $0.id == id }
        XCTFail("시간 초과 \(String(describing: s?.status)) \(s?.detail ?? "") \(s?.errorMessage ?? "")")
        throw XCTSkip("timeout")
    }

    func loadJob(_ url: URL, pickHighest: Bool = true) throws -> HLSJob {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<HLSJob, Error>!
        Task {
            do {
                let info = try await HLSLoader.load(url, headers: [:])
                XCTAssertEqual(info.variants.count, 2)
                XCTAssertEqual(info.variants.first?.height, 360, "화질 높은 순이어야")
                let job = try await HLSLoader.makeJob(info, variant: pickHighest ? info.variants.first : info.variants.last, headers: [:])
                result = .success(job)
            } catch {
                result = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }

    func testHLSDownloadEndToEnd() throws {
        let dir = try makeFixture("hls1")
        let master = URL(string: server + "/static/hls1/master.m3u8")!
        let job = try loadJob(master)
        XCTAssertEqual(job.parts.count, 4)
        XCTAssertEqual(job.container, .ts)
        XCTAssertEqual(job.label, "360p · 900 kbps")
        let m = manager()
        let id = m.add(NewDownload(url: master, fileName: "영상.mp4", hls: job))
        let snap = try wait(m, id)
        XCTAssertEqual(snap.status, .completed, snap.errorMessage ?? "")
        XCTAssertEqual(snap.fileName, "영상.mp4")
        let out = try XCTUnwrap(snap.savedURL)
        // 원본 hi 조각과 프레임이 같은지
        let src = (0..<4).map { dir.appendingPathComponent(String(format: "hi/s%03d.ts", $0)).path }.joined(separator: "|")
        XCTAssertEqual(try FFTool.frames(["-i", out.path], stream: "v"), try FFTool.frames(["-i", "concat:" + src], stream: "v"))
        XCTAssertEqual(try FFTool.frames(["-i", out.path], stream: "a"), try FFTool.frames(["-i", "concat:" + src], stream: "a"))
        XCTAssertGreaterThan(try FFTool.frames(["-i", out.path], stream: "v").count, 150)
        // 조각 폴더는 지워졌어야
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.paths.hlsDir(id).path))
    }

    func testHLSSeparateAudio() throws {
        _ = try makeFixture("hls2", separateAudio: true)
        let master = URL(string: server + "/static/hls2/master.m3u8")!
        let job = try loadJob(master, pickHighest: false)
        XCTAssertGreaterThanOrEqual(job.audioParts.count, 4)
        XCTAssertNotNil(job.audioPlaylistURL)
        let m = manager()
        let id = m.add(NewDownload(url: master, fileName: "sep.mp4", hls: job))
        let snap = try wait(m, id)
        XCTAssertEqual(snap.status, .completed, snap.errorMessage ?? "")
        let streams = try FFTool.probe(XCTUnwrap(snap.savedURL))
        XCTAssertEqual(streams.compactMap { $0["codec_name"] as? String }.sorted(), ["aac", "h264"])
    }

    /// 백그라운드 넘기기: 조각들을 작업으로 받아 직접 내려받아 돌려준다. 합치기는 앱이 다시 켜졌을 때.
    func testHLSBackgroundHandOff() throws {
        _ = try makeFixture("hls3")
        let master = URL(string: server + "/static/hls3/master.m3u8")!
        let job = try loadJob(master)
        let m = manager()
        m.update(settings: EngineSettings(maxActiveDownloads: 0))
        let id = m.add(NewDownload(url: master, fileName: "bg.mp4", hls: job))
        Thread.sleep(forTimeInterval: 0.2)
        let jobs = m.detachForBackground()
        XCTAssertEqual(jobs.count, 4)
        for j in jobs {
            var req = URLRequest(url: j.url)
            for (k, v) in j.headers { req.setValue(v, forHTTPHeaderField: k) }
            let sem = DispatchSemaphore(value: 0)
            var data: Data?
            URLSession(configuration: .ephemeral).dataTask(with: req) { d, _, _ in data = d; sem.signal() }.resume()
            sem.wait()
            let tmp = work.appendingPathComponent(UUID().uuidString)
            try XCTUnwrap(data).write(to: tmp)
            XCTAssertTrue(m.externalFinished(j.key, file: tmp, statusCode: 200, contentRange: nil, mimeType: nil))
        }
        // 백그라운드에선 합치지 않는다
        let pending = try wait(m, id, timeout: 5) { $0.status == .processing }
        XCTAssertEqual(pending.status, .processing)
        m.update(settings: EngineSettings())
        m.resumeForeground()
        let snap = try wait(m, id)
        XCTAssertEqual(snap.status, .completed, snap.errorMessage ?? "")
    }
}

/// ffmpeg/ffprobe 도우미(시험끼리 같이 쓴다)
enum FFTool {
    static func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: RemuxTests.which(args[0]) ?? args[0])
        p.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func frames(_ input: [String], stream: String) throws -> [String] {
        let text = try run(["ffmpeg", "-v", "error"] + input + ["-map", "0:\(stream)", "-fps_mode", "passthrough", "-f", "framemd5", "-"])
        return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
            line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.suffix(2).joined(separator: ",")
        }
    }

    static func probe(_ file: URL) throws -> [[String: Any]] {
        let text = try run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", file.path])
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        return obj?["streams"] as? [[String: Any]] ?? []
    }
}
