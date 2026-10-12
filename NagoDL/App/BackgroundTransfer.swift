import Foundation
import NagoDLCore

/// 앱이 화면에서 내려간 동안 시스템(nsurlsessiond)이 대신 받는 백그라운드 세션.
///
/// 앱이 내려가기 직전(비활성)에 엔진이 남은 구간을 잘라 주면 여기서 작업으로 만든다. 앱이 꺼져 있어도 받고,
/// 끝나면 시스템이 앱을 깨워 `didFinishDownloadingTo`로 파일을 넘긴다. 앱으로 돌아오면 아직 시작 안 한
/// 작업은 취소하고 그 구간을 다시 여러 연결로 받는다(시작한 작업은 끝까지 둔다).
final class BackgroundTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "nago.dl.background"

    private let manager: DownloadManager
    private var session: URLSession!
    private let lock = NSLock()
    private var completion: (() -> Void)?
    private var inForeground = true
    /// 백그라운드에서 실패해 다시 맡긴 횟수(같은 구간이 계속 실패하면 앱이 열릴 때까지 둔다)
    private var retries: [ExternalKey: Int] = [:]

    init(manager: DownloadManager) {
        self.manager = manager
        super.init()
    }

    /// 앱 시작할 때 한 번. 같은 이름의 세션을 다시 만들면 이전 실행의 작업들이 이어진다.
    func activate(allowsCellular: Bool) {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = allowsCellular
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session.getAllTasks { [manager] tasks in
            let live = Set(tasks.filter { $0.state == .running || $0.state == .suspended }
                .compactMap { ExternalKey(string: $0.taskDescription) })
            manager.reconcileExternal(live: live)
        }
    }

    func setForeground(_ value: Bool) {
        lock.lock()
        inForeground = value
        lock.unlock()
    }

    private var isForeground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inForeground
    }

    /// 시스템이 앱을 깨우며 준 완료 콜백(모든 이벤트를 넘겨받은 뒤 부른다)
    func setEventsCompletion(_ handler: @escaping () -> Void) {
        lock.lock()
        completion = handler
        lock.unlock()
    }

    func enqueue(_ jobs: [ExternalJob]) {
        guard let session else { return }
        for job in jobs {
            var request = URLRequest(url: job.url)
            for (k, v) in job.headers { request.setValue(v, forHTTPHeaderField: k) }
            let task = session.downloadTask(with: request)
            task.taskDescription = job.key.description
            task.resume()
        }
    }

    /// 앱으로 돌아왔다: 한 바이트도 안 받은 작업은 취소하고 그 구간을 포그라운드로 되돌린다.
    func reclaimUnstarted(then done: @escaping @Sendable () -> Void) {
        guard let session else {
            done()
            return
        }
        session.getAllTasks { [manager] tasks in
            var keys: [ExternalKey] = []
            for task in tasks where task.state == .running || task.state == .suspended {
                guard task.countOfBytesReceived == 0, let key = ExternalKey(string: task.taskDescription) else { continue }
                task.cancel()
                keys.append(key)
            }
            manager.reclaim(keys)
            DispatchQueue.main.async(execute: done)
        }
    }

    /// 이 다운로드의 작업을 모두 취소(일시정지·삭제)
    func cancel(download id: UUID) {
        session?.getAllTasks { tasks in
            for task in tasks where ExternalKey(string: task.taskDescription)?.download == id {
                task.cancel()
            }
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = ExternalKey(string: downloadTask.taskDescription) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        manager.externalFinished(key, file: location, statusCode: http?.statusCode ?? 0,
                                 contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
                                 mimeType: http?.mimeType)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = ExternalKey(string: downloadTask.taskDescription) else { return }
        manager.externalProgress(key, received: totalBytesWritten)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = ExternalKey(string: task.taskDescription) else { return }
        manager.externalFailed(key)
        let cancelled = (error as? URLError)?.code == .cancelled
        guard !cancelled && !isForeground else { return }
        lock.lock()
        let count = (retries[key] ?? 0) + 1
        retries[key] = count
        lock.unlock()
        // 백그라운드에 있는 동안 실패했다 — 남은 일을 다시 맡긴다(세 번까지, 그 뒤는 앱이 열리면 포그라운드가 받는다)
        if count <= 3 {
            enqueue(manager.pendingJobs())
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = completion
        completion = nil
        lock.unlock()
        DispatchQueue.main.async { handler?() }
    }
}
