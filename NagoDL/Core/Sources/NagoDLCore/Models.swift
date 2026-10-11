import Foundation

public enum DownloadKind: String, Codable, Sendable {
    /// 일반 파일(여러 연결로 나눠 받기)
    case file
    /// HLS(m3u8) 동영상: 조각을 받아 MP4로 합친다
    case hls
}

public enum DownloadStatus: String, Codable, Sendable {
    case queued, running, paused, processing, completed, failed

    public var isActive: Bool { self == .running || self == .queued || self == .processing }
}

/// 파일의 한 구간. 한 연결이 맡아서 start부터 차례로 채운다.
public struct Segment: Codable, Equatable, Sendable {
    public var start: Int64
    /// 마지막 바이트(포함). 길이를 모르면 Int64.max
    public var end: Int64
    public var received: Int64
    /// 백그라운드 세션이 받는 중(앱이 꺼져도 시스템이 받는다)
    public var external: Bool

    public init(start: Int64, end: Int64, received: Int64 = 0, external: Bool = false) {
        self.start = start
        self.end = end
        self.received = received
        self.external = external
    }

    public var next: Int64 { start + received }
    public var length: Int64 { end == Int64.max ? Int64.max : end - start + 1 }
    public var remaining: Int64 { end == Int64.max ? Int64.max : max(0, end - next + 1) }
    public var isDone: Bool { end != Int64.max && next > end }

    enum CodingKeys: String, CodingKey { case start, end, received, external }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Int64.self, forKey: .start)
        end = try c.decode(Int64.self, forKey: .end)
        received = try c.decode(Int64.self, forKey: .received)
        external = try c.decodeIfPresent(Bool.self, forKey: .external) ?? false
    }
}

/// HLS 조각 하나(EXT-X-BYTERANGE면 파일 일부)
public struct HLSPart: Codable, Equatable, Sendable {
    public var url: URL
    public var rangeOffset: Int64?
    public var rangeLength: Int64?
    public var duration: Double
    public var discontinuity: Bool
    public var done: Bool
    public var bytes: Int64
    public var external: Bool

    public init(url: URL, rangeOffset: Int64? = nil, rangeLength: Int64? = nil, duration: Double = 0,
                discontinuity: Bool = false, done: Bool = false, bytes: Int64 = 0, external: Bool = false) {
        self.url = url
        self.rangeOffset = rangeOffset
        self.rangeLength = rangeLength
        self.duration = duration
        self.discontinuity = discontinuity
        self.done = done
        self.bytes = bytes
        self.external = external
    }
}

public enum HLSContainer: String, Codable, Sendable {
    /// MPEG-TS 조각 → 직접 디먹스해서 MP4로
    case ts
    /// fMP4(CMAF) 조각 → init + 조각을 이어 붙이면 그대로 MP4
    case fmp4
    /// 오디오만 담은 ADTS(.aac) 조각
    case packedAudio
}

public enum HLSTrack: Int, Codable, Sendable {
    case main = 0
    case audio = 1
}

/// 받을 HLS 재생 목록과 조각들
public struct HLSJob: Codable, Equatable, Sendable {
    public var playlistURL: URL
    public var label: String?
    public var container: HLSContainer
    public var initSegment: HLSPart?
    public var parts: [HLSPart]
    public var audioPlaylistURL: URL?
    public var audioContainer: HLSContainer?
    public var audioInit: HLSPart?
    public var audioParts: [HLSPart]
    public var duration: Double

    public init(playlistURL: URL, label: String?, container: HLSContainer, initSegment: HLSPart?, parts: [HLSPart],
                audioPlaylistURL: URL? = nil, audioContainer: HLSContainer? = nil, audioInit: HLSPart? = nil,
                audioParts: [HLSPart] = [], duration: Double) {
        self.playlistURL = playlistURL
        self.label = label
        self.container = container
        self.initSegment = initSegment
        self.parts = parts
        self.audioPlaylistURL = audioPlaylistURL
        self.audioContainer = audioContainer
        self.audioInit = audioInit
        self.audioParts = audioParts
        self.duration = duration
    }

    public var totalParts: Int { parts.count + audioParts.count + (initSegment == nil ? 0 : 1) + (audioInit == nil ? 0 : 1) }

    public var doneParts: Int {
        parts.filter(\.done).count + audioParts.filter(\.done).count
            + (initSegment?.done == true ? 1 : 0) + (audioInit?.done == true ? 1 : 0)
    }

    public var doneBytes: Int64 {
        parts.reduce(0) { $0 + ($1.done ? $1.bytes : 0) } + audioParts.reduce(0) { $0 + ($1.done ? $1.bytes : 0) }
            + (initSegment?.done == true ? initSegment!.bytes : 0) + (audioInit?.done == true ? audioInit!.bytes : 0)
    }
}

/// 디스크에 저장되는 다운로드 한 건
public struct DownloadRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var kind: DownloadKind
    public var sourceURL: URL
    /// 리다이렉트를 따라간 실제 주소(조각 요청에 쓴다)
    public var resolvedURL: URL?
    public var pageURL: URL?
    /// 브라우저에서 가져온 쿠키·User-Agent·Referer
    public var headers: [String: String]
    public var fileName: String
    /// 완료 후 Documents에 저장된 이름
    public var savedName: String?
    public var status: DownloadStatus
    public var errorMessage: String?
    public var totalBytes: Int64?
    public var acceptsRanges: Bool
    public var validator: String?
    public var mimeType: String?
    public var segments: [Segment]
    public var maxConnections: Int
    public var createdAt: Date
    public var completedAt: Date?
    public var hls: HLSJob?
    /// 서버 파일이 바뀌어 처음부터 다시 받은 횟수(무한 반복 방지)
    public var restarts: Int
    /// 사용자가 이름을 직접 정했으면 서버 이름으로 바꾸지 않는다
    public var nameLocked: Bool

    public init(id: UUID = UUID(), kind: DownloadKind, sourceURL: URL, pageURL: URL?, headers: [String: String],
                fileName: String, maxConnections: Int, hls: HLSJob? = nil, nameLocked: Bool = false) {
        self.id = id
        self.kind = kind
        self.sourceURL = sourceURL
        self.resolvedURL = nil
        self.pageURL = pageURL
        self.headers = headers
        self.fileName = fileName
        self.savedName = nil
        self.status = .queued
        self.errorMessage = nil
        self.totalBytes = nil
        self.acceptsRanges = false
        self.validator = nil
        self.mimeType = nil
        self.segments = []
        self.maxConnections = maxConnections
        self.createdAt = Date()
        self.completedAt = nil
        self.hls = hls
        self.restarts = 0
        self.nameLocked = nameLocked
    }

    public var doneBytes: Int64 {
        if kind == .hls { return hls?.doneBytes ?? 0 }
        return segments.reduce(0) { $0 + $1.received }
    }

    /// 받은 구간이 아직 없음(처음 연결 전)
    public var isFresh: Bool { segments.isEmpty }

    public var requestURL: URL { resolvedURL ?? sourceURL }
}

/// 화면에 그릴 진행 막대 한 칸(0...1 비율)
public struct BarPiece: Equatable, Sendable {
    public var from: Double
    public var to: Double
    public var filled: Double
    public var active: Bool
    public var external: Bool

    public init(from: Double, to: Double, filled: Double, active: Bool, external: Bool) {
        self.from = from
        self.to = to
        self.filled = filled
        self.active = active
        self.external = external
    }
}

/// 상세 화면의 연결 한 줄
public struct ConnectionSnapshot: Equatable, Sendable, Identifiable {
    public var id: Int
    public var rangeStart: Int64
    public var rangeEnd: Int64
    public var received: Int64
    public var speed: Double
    public var note: String?
}

/// UI가 받는 다운로드 상태(엔진 큐 밖으로 복사돼 나간다)
public struct DownloadSnapshot: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: DownloadKind
    public var fileName: String
    public var status: DownloadStatus
    public var errorMessage: String?
    public var sourceURL: URL
    public var pageURL: URL?
    public var totalBytes: Int64?
    public var doneBytes: Int64
    public var speed: Double
    public var activeConnections: Int
    public var maxConnections: Int
    public var acceptsRanges: Bool
    public var bars: [BarPiece]
    public var savedURL: URL?
    public var createdAt: Date
    public var completedAt: Date?
    public var detail: String?
    public var progress: Double?
    public var connections: [ConnectionSnapshot]
    public var mimeType: String?
    public var backgroundParts: Int
    /// 완료했는데 파일이 없어짐(파일 앱에서 지웠거나 옮김)
    public var fileMissing: Bool

    public var eta: Double? {
        guard speed > 1, let totalBytes, totalBytes > doneBytes else { return nil }
        return Double(totalBytes - doneBytes) / speed
    }
}

/// 백그라운드 세션 작업 하나를 가리키는 키. URLSessionTask.taskDescription에 문자열로 남는다.
public struct ExternalKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable {
        /// 파일의 [a, b] 구간
        case range = "r"
        /// HLS 조각: a = 트랙, b = 번호(-1은 init)
        case hls = "h"
        /// 크기를 모르는 파일 전체
        case whole = "w"
    }

    public var download: UUID
    public var kind: Kind
    public var a: Int64
    public var b: Int64

    public init(download: UUID, kind: Kind, a: Int64, b: Int64) {
        self.download = download
        self.kind = kind
        self.a = a
        self.b = b
    }

    public var description: String { "nagodl1|\(download.uuidString)|\(kind.rawValue)|\(a)|\(b)" }

    public init?(string: String?) {
        guard let string else { return nil }
        let p = string.split(separator: "|").map(String.init)
        guard p.count == 5, p[0] == "nagodl1", let id = UUID(uuidString: p[1]), let kind = Kind(rawValue: p[2]),
              let a = Int64(p[3]), let b = Int64(p[4]) else { return nil }
        self.init(download: id, kind: kind, a: a, b: b)
    }
}

/// 백그라운드 세션에 넘길 요청
public struct ExternalJob: Sendable {
    public var key: ExternalKey
    public var url: URL
    public var headers: [String: String]
}

public struct EngineSettings: Equatable, Sendable {
    public var defaultConnections: Int
    public var maxActiveDownloads: Int
    public var allowsCellular: Bool
    public var userAgent: String
    /// 이보다 작게는 안 쪼갠다
    public var minPieceBytes: Int64
    public var requestTimeout: Double
    public var maxRetries: Int
    /// 백그라운드로 넘길 때 구간을 이 크기 안팎으로 나눈다
    public var backgroundChunkBytes: Int64

    public static let safariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

    public init(defaultConnections: Int = 8, maxActiveDownloads: Int = 3, allowsCellular: Bool = true,
                userAgent: String = EngineSettings.safariUA, minPieceBytes: Int64 = 256 * 1024,
                requestTimeout: Double = 30, maxRetries: Int = 8, backgroundChunkBytes: Int64 = 32 << 20) {
        self.defaultConnections = defaultConnections
        self.maxActiveDownloads = maxActiveDownloads
        self.allowsCellular = allowsCellular
        self.userAgent = userAgent
        self.minPieceBytes = minPieceBytes
        self.requestTimeout = requestTimeout
        self.maxRetries = maxRetries
        self.backgroundChunkBytes = backgroundChunkBytes
    }
}

/// 엔진이 쓰는 폴더들
public struct EnginePaths: Sendable {
    /// Application Support/NagoDL — 기록, 받는 중인 파일, HLS 조각
    public let support: URL
    /// 완성된 파일(Documents: 파일 앱에 보인다)
    public let output: URL

    public init(support: URL, output: URL) {
        self.support = support
        self.output = output
    }

    public var records: URL { support.appendingPathComponent("records", isDirectory: true) }
    public var partial: URL { support.appendingPathComponent("partial", isDirectory: true) }
    public var hlsRoot: URL { support.appendingPathComponent("hls", isDirectory: true) }

    public func recordURL(_ id: UUID) -> URL { records.appendingPathComponent(id.uuidString + ".json") }
    public func partialURL(_ id: UUID) -> URL { partial.appendingPathComponent(id.uuidString + ".part") }
    public func hlsDir(_ id: UUID) -> URL { hlsRoot.appendingPathComponent(id.uuidString, isDirectory: true) }

    public func hlsPartURL(_ id: UUID, track: HLSTrack, index: Int) -> URL {
        let name = index < 0 ? "init_\(track.rawValue).bin" : String(format: "t%d_%06d.bin", track.rawValue, index)
        return hlsDir(id).appendingPathComponent(name)
    }

    public func prepare() throws {
        let fm = FileManager.default
        for dir in [records, partial, hlsRoot, output] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public static func standard() -> EnginePaths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NagoDL", isDirectory: true)
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return EnginePaths(support: support, output: docs)
    }
}

public enum DownloadEvent: Sendable {
    case completed(id: UUID, name: String)
    case failed(id: UUID, name: String, message: String)
}

/// 새로 추가할 다운로드
public struct NewDownload: Sendable {
    public var url: URL
    public var fileName: String?
    public var headers: [String: String]
    public var pageURL: URL?
    public var connections: Int?
    public var hls: HLSJob?
    public var startPaused: Bool

    public init(url: URL, fileName: String? = nil, headers: [String: String] = [:], pageURL: URL? = nil,
                connections: Int? = nil, hls: HLSJob? = nil, startPaused: Bool = false) {
        self.url = url
        self.fileName = fileName
        self.headers = headers
        self.pageURL = pageURL
        self.connections = connections
        self.hls = hls
        self.startPaused = startPaused
    }
}
