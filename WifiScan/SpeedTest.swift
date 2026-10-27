import Foundation
import Observation

/// 지금 회선(VPN이 켜져 있으면 터널)의 실제 속도. 설정(loops 1·2, neptun·go, 나라)을 바꿔 가며 비교하려고 만들었다.
/// - 받기·올리기: Cloudflare 속도 측정 서버(speed.cloudflare.com)에 연결 4개로 동시에 7초씩.
///   연결마다 세션을 따로 둬서 HTTP/2 한 연결에 몰리지 않게 하고, 처음 1.5초(TCP가 속도를 올리는 동안)는 빼고 잰다
/// - 핑: 쉬는 동안 5번(중간값), 받는 동안 0.4초마다(대기열이 쌓이면 이 값이 커진다)
/// - 결과는 어떤 설정이었는지(via)와 함께 최근 8개까지 남긴다
@MainActor
@Observable
final class SpeedTest {
    enum Phase: String {
        case idle, ping, download, upload, done, failed
    }

    struct Result: Codable, Identifiable {
        var id: Date { at }
        let at: Date
        /// "wg/neptun ×2 · jp", "ikev2 · us", "direct" …
        let via: String
        let downMbps: Double
        let upMbps: Double
        let idleMs: Double?
        let loadedMs: Double?
    }

    private(set) var phase: Phase = .idle
    /// 지금 단계에서 흐르는 속도(Mbps)
    private(set) var liveMbps: Double = 0
    /// 지금 단계가 얼마나 지났는지(0…1)
    private(set) var progress: Double = 0
    private(set) var last: Result?
    private(set) var history: [Result] = []
    private(set) var errorText: String?

    var running: Bool { phase == .ping || phase == .download || phase == .upload }

    private static let historyKey = "nagoSpeedHistory"
    private static let streams = 4
    private static let seconds = 7.0
    private static let warmup = 1.5
    /// 연결 하나가 받을 최대 양. 7초 안에 다 받으면(아주 빠른 회선) 그때까지로 잰다
    private static let downBytes = 50_000_000
    /// 연결 하나가 올릴 양(같은 덩어리를 네 연결이 같이 쓴다)
    private static let upBytes = 25_000_000
    /// 화면에 적어 두는 최대 사용량(받기 4×50MB + 올리기 4×25MB)
    static let maxUsageMB = (streams * (downBytes + upBytes)) / 1_000_000

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([Result].self, from: data) {
            history = saved
            last = saved.first
        }
    }

    func run(via: String) async {
        guard !running else { return }
        errorText = nil
        if Demo.on {
            showDemo()
            return
        }
        phase = .ping
        progress = 0
        liveMbps = 0
        let idle = await Cloudflare.pingMedian(count: 5)
        guard idle != nil else {
            fail("speed.cloudflare.com unreachable")
            return
        }

        phase = .download
        let loadedPings = PingSampler()
        let pinger = Task.detached { await loadedPings.run() }
        let down = await transfer(upload: false)
        pinger.cancel()
        let loaded = await loadedPings.median()

        phase = .upload
        let up = await transfer(upload: true)

        guard let down, let up else {
            fail("transfer failed")
            return
        }
        let result = Result(at: Date(), via: via, downMbps: down, upMbps: up, idleMs: idle, loadedMs: loaded)
        last = result
        history.insert(result, at: 0)
        if history.count > 8 { history.removeLast(history.count - 8) }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
        liveMbps = 0
        progress = 1
        phase = .done
    }

    private func fail(_ message: String) {
        errorText = message
        liveMbps = 0
        phase = .failed
    }

    /// 연결 4개로 정해진 시간 동안 받거나 올리고, 처음 1.5초를 뺀 평균 속도(Mbps)를 돌려준다.
    private func transfer(upload: Bool) async -> Double? {
        let counter = ByteCounter()
        var sessions: [URLSession] = []
        var tasks: [URLSessionTask] = []
        let body = upload ? Data(count: Self.upBytes) : Data()
        for _ in 0..<Self.streams {
            let session = URLSession(configuration: Cloudflare.configuration, delegate: counter, delegateQueue: nil)
            sessions.append(session)
            let task: URLSessionTask
            if upload {
                var request = URLRequest(url: Cloudflare.upload)
                request.httpMethod = "POST"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                task = session.uploadTask(with: request, from: body)
            } else {
                task = session.dataTask(with: Cloudflare.download(bytes: Self.downBytes))
            }
            tasks.append(task)
            task.resume()
        }
        defer {
            tasks.forEach { $0.cancel() }
            sessions.forEach { $0.invalidateAndCancel() }
        }

        let start = Date()
        var mark: (time: Double, bytes: Int64)?
        var previous: (time: Double, bytes: Int64) = (0, 0)
        var finished: (time: Double, bytes: Int64) = (0, 0)
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            let t = Date().timeIntervalSince(start)
            let bytes = counter.total
            liveMbps = Double(bytes - previous.bytes) * 8 / max(t - previous.time, 0.001) / 1_000_000
            previous = (t, bytes)
            progress = min(t / Self.seconds, 1)
            if mark == nil, t >= Self.warmup { mark = (t, bytes) }
            finished = (t, bytes)
            let allDone = tasks.allSatisfy { $0.state == .completed }
            if t >= Self.seconds || allDone || counter.failures >= Self.streams { break }
        }
        guard finished.bytes > 0 else { return nil }
        // 1.5초 뒤부터 잰다. 그 뒤로 1초도 안 돼서 끝났으면(아주 빠른 회선) 처음부터
        var from: (time: Double, bytes: Int64) = (0, 0)
        if let mark, finished.time - mark.time > 1 { from = mark }
        let seconds = max(finished.time - from.time, 0.1)
        return Double(finished.bytes - from.bytes) * 8 / seconds / 1_000_000
    }

    /// 스크린샷용
    func showDemo() {
        let now = Date()
        history = [
            Result(at: now.addingTimeInterval(-60), via: "wg/nagotun ×1 · jp", downMbps: 312.4, upMbps: 88.1, idleMs: 31, loadedMs: 52),
            Result(at: now.addingTimeInterval(-420), via: "wg/nagotun ×2 · jp", downMbps: 243.9, upMbps: 86.7, idleMs: 31, loadedMs: 71),
            Result(at: now.addingTimeInterval(-900), via: "wg/go · jp", downMbps: 228.0, upMbps: 80.2, idleMs: 32, loadedMs: 66),
            Result(at: now.addingTimeInterval(-1500), via: "direct", downMbps: 486.5, upMbps: 121.0, idleMs: 9, loadedMs: 38),
        ]
        last = history.first
        phase = .done
        progress = 1
    }
}

/// Cloudflare 속도 측정 서버 주소와 세션 설정(액터 밖에서도 쓴다)
private enum Cloudflare {
    static let host = "https://speed.cloudflare.com"
    static let upload = URL(string: "\(host)/__up")!

    static func download(bytes: Int) -> URL {
        URL(string: "\(host)/__down?bytes=\(bytes)")!
    }

    /// 세션마다 연결 하나(HTTP/2로 한 연결에 몰리지 않게 세션을 따로 만든다)
    static var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 1
        return config
    }

    /// 0바이트 요청의 왕복 시간 중간값(ms). 첫 요청은 TLS 핸드셰이크가 섞여서 버린다.
    static func pingMedian(count: Int) async -> Double? {
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let url = download(bytes: 0)
        guard (try? await session.data(from: url)) != nil else { return nil }
        var samples: [Double] = []
        for _ in 0..<count {
            let start = Date()
            if (try? await session.data(from: url)) != nil {
                samples.append(Date().timeIntervalSince(start) * 1000)
            }
        }
        guard !samples.isEmpty else { return nil }
        return samples.sorted()[samples.count / 2]
    }
}

/// 받는 동안 0.4초마다 0바이트 요청으로 핑을 잰다(받기와 다른 연결)
private actor PingSampler {
    private var samples: [Double] = []

    func run() async {
        let session = URLSession(configuration: Cloudflare.configuration)
        defer { session.finishTasksAndInvalidate() }
        let url = Cloudflare.download(bytes: 0)
        _ = try? await session.data(from: url)    // TLS 핸드셰이크
        while !Task.isCancelled {
            let start = Date()
            if (try? await session.data(from: url)) != nil {
                samples.append(Date().timeIntervalSince(start) * 1000)
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    func median() -> Double? {
        guard !samples.isEmpty else { return nil }
        return samples.sorted()[samples.count / 2]
    }
}

/// 연결 넷의 받은·보낸 바이트를 합친다(URLSession 대리자, 여러 스레드에서 불림)
private final class ByteCounter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var failed = 0

    var total: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    var failures: Int {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        bytes += Int64(data.count)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        bytes += bytesSent
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as? URLError)?.code != .cancelled else { return }
        lock.lock()
        failed += 1
        lock.unlock()
    }
}
