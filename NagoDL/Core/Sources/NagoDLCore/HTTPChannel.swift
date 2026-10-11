import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ChannelOptions: Sendable {
    public var timeout: Double
    public var allowsCellular: Bool
    /// 요청에 Cookie 헤더를 직접 넣을 때는 세션 쿠키 저장소를 끈다(같이 섞이지 않게)
    public var useCookieStore: Bool

    public init(timeout: Double = 30, allowsCellular: Bool = true, useCookieStore: Bool = true) {
        self.timeout = timeout
        self.allowsCellular = allowsCellular
        self.useCookieStore = useCookieStore
    }
}

public struct ChannelRequest: Sendable {
    public var url: URL
    public var headers: [String: String]
    /// nil이면 Range 헤더 없이 전체
    public var rangeStart: Int64?
    /// nil이면 끝까지(bytes=n-)
    public var rangeEnd: Int64?
    public var ifRange: String?

    public init(url: URL, headers: [String: String] = [:], rangeStart: Int64? = nil, rangeEnd: Int64? = nil, ifRange: String? = nil) {
        self.url = url
        self.headers = headers
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.ifRange = ifRange
    }

    public func urlRequest(timeout: Double) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = "GET"
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        // 압축되면 바이트 위치가 안 맞는다
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let rangeStart {
            r.setValue("bytes=\(rangeStart)-" + (rangeEnd.map { String($0) } ?? ""), forHTTPHeaderField: "Range")
            if let ifRange { r.setValue(ifRange, forHTTPHeaderField: "If-Range") }
        }
        return r
    }
}

public enum ChannelError: Error, LocalizedError, Equatable {
    case http(Int)
    case shortRead
    case badRange(String)
    case encoded(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)" + (ChannelError.reason(code).map { " — \($0)" } ?? "")
        case .shortRead: return "서버가 중간에 끊었어요"
        case .badRange(let s): return "범위 응답이 이상해요(\(s))"
        case .encoded(let e): return "압축된 응답(\(e))"
        }
    }

    static func reason(_ code: Int) -> String? {
        switch code {
        case 401: return "로그인이 필요해요"
        case 403: return "권한이 없거나 링크가 만료됐어요"
        case 404: return "파일이 없어요"
        case 410: return "링크가 만료됐어요"
        case 429: return "요청이 너무 많아요"
        case 500...599: return "서버 오류"
        default: return nil
        }
    }
}

public extension HTTPResponseInfo {
    init(_ response: URLResponse?) {
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let k = k as? String { headers[k] = "\(v)" }
        }
        self.init(statusCode: http?.statusCode ?? 0, url: response?.url, headers: headers)
    }
}

/// 연결 하나. URLSession을 하나씩 따로 둔다 — 세션마다 연결 풀이 달라서 HTTP/2 서버여도
/// 연결이 하나로 합쳐지지 않는다(연결별 속도 제한을 피하는 게 분할 다운로드의 핵심).
/// 같은 채널에서 이어지는 요청은 keep-alive로 같은 연결을 다시 쓴다.
///
/// start/cancel은 `queue`에서만 부르고, 이벤트도 `queue`에서 온다.
public final class HTTPChannel {
    public enum Event {
        case response(HTTPResponseInfo)
        case data(Data)
        case finished(Error?)
    }

    private let queue: DispatchQueue
    private let options: ChannelOptions
    private let proxy: Proxy
    private let session: URLSession
    private var task: URLSessionDataTask?
    private var taskID: Int?
    private var handler: ((Event) -> Void)?

    public init(queue: DispatchQueue, options: ChannelOptions) {
        self.queue = queue
        self.options = options
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = options.timeout
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.allowsCellularAccess = options.allowsCellular
        config.httpShouldSetCookies = options.useCookieStore
        config.httpMaximumConnectionsPerHost = 2
        #if canImport(Darwin)
        config.waitsForConnectivity = false
        #endif
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        proxy = Proxy()
        session = URLSession(configuration: config, delegate: proxy, delegateQueue: delegateQueue)
        proxy.channel = self
    }

    deinit {
        session.invalidateAndCancel()
    }

    public var isBusy: Bool { task != nil }

    public func start(_ request: ChannelRequest, handler: @escaping (Event) -> Void) {
        cancel()
        let t = session.dataTask(with: request.urlRequest(timeout: options.timeout))
        task = t
        taskID = t.taskIdentifier
        self.handler = handler
        t.resume()
    }

    /// 지금 요청을 멈춘다. 이후 이 요청의 이벤트는 오지 않는다.
    public func cancel() {
        task?.cancel()
        task = nil
        taskID = nil
        handler = nil
    }

    /// 다 쓴 채널을 닫는다(세션이 delegate를 놓아 준다).
    public func invalidate() {
        cancel()
        session.invalidateAndCancel()
    }

    fileprivate func deliver(_ id: Int, _ event: Event) {
        queue.async { [weak self] in
            guard let self, self.taskID == id, let handler = self.handler else { return }
            if case .finished = event {
                self.task = nil
                self.taskID = nil
                self.handler = nil
            }
            handler(event)
        }
    }

    /// URLSession은 delegate를 강하게 잡고 있어서 채널 대신 이 작은 객체를 넘긴다.
    private final class Proxy: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var channel: HTTPChannel?

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            completionHandler(.allow)
            channel?.deliver(dataTask.taskIdentifier, .response(HTTPResponseInfo(response)))
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            channel?.deliver(dataTask.taskIdentifier, .data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            channel?.deliver(task.taskIdentifier, .finished(error))
        }

        /// 리다이렉트할 때 Range 같은 헤더를 그대로 들고 간다. 쿠키·인증은 같은 호스트일 때만.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var next = request
            if let original = task.originalRequest {
                let sameHost = original.url?.host?.lowercased() == request.url?.host?.lowercased()
                for (k, v) in original.allHTTPHeaderFields ?? [:] {
                    let lower = k.lowercased()
                    if !sameHost && (lower == "cookie" || lower == "authorization") { continue }
                    if next.value(forHTTPHeaderField: k) == nil { next.setValue(v, forHTTPHeaderField: k) }
                }
            }
            completionHandler(next)
        }
    }
}

/// 짧은 응답을 통째로 받는다(재생 목록, 미리보기).
public enum HTTPFetch {
    public struct TooLarge: Error, LocalizedError {
        public var errorDescription: String? { "응답이 너무 커요" }
    }

    public static func fetch(_ request: ChannelRequest, options: ChannelOptions = ChannelOptions(timeout: 20),
                             maxBytes: Int = 16 << 20) async throws -> (HTTPResponseInfo, Data) {
        let queue = DispatchQueue(label: "nago.dl.fetch")
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                let channel = HTTPChannel(queue: queue, options: options)
                var info: HTTPResponseInfo?
                var body = Data()
                var done = false
                func finish(_ result: Result<(HTTPResponseInfo, Data), Error>) {
                    guard !done else { return }
                    done = true
                    channel.invalidate()
                    cont.resume(with: result)
                }
                channel.start(request) { event in
                    switch event {
                    case .response(let r):
                        info = r
                    case .data(let d):
                        body.append(d)
                        if body.count > maxBytes { finish(.failure(TooLarge())) }
                    case .finished(let error):
                        if let error {
                            finish(.failure(error))
                        } else if let info {
                            finish(.success((info, body)))
                        } else {
                            finish(.failure(ChannelError.http(0)))
                        }
                    }
                }
            }
        }
    }

    /// 응답 머리만 보고 끊는다(크기·이어받기·종류 확인).
    public static func head(_ request: ChannelRequest, options: ChannelOptions = ChannelOptions(timeout: 20)) async throws -> HTTPResponseInfo {
        let queue = DispatchQueue(label: "nago.dl.head")
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                let channel = HTTPChannel(queue: queue, options: options)
                var done = false
                func finish(_ result: Result<HTTPResponseInfo, Error>) {
                    guard !done else { return }
                    done = true
                    channel.invalidate()
                    cont.resume(with: result)
                }
                channel.start(request) { event in
                    switch event {
                    case .response(let r): finish(.success(r))
                    case .data: break
                    case .finished(let error): finish(.failure(error ?? ChannelError.http(0)))
                    }
                }
            }
        }
    }
}
