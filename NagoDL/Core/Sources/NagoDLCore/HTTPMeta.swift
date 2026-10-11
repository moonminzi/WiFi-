import Foundation

/// `Content-Range: bytes 0-499/1234` 해석
public struct ContentRange: Equatable, Sendable {
    public var start: Int64
    public var end: Int64
    /// `*`이면 nil
    public var total: Int64?

    public init(start: Int64, end: Int64, total: Int64?) {
        self.start = start
        self.end = end
        self.total = total
    }

    public static func parse(_ header: String?) -> ContentRange? {
        guard let header else { return nil }
        var s = header.trimmingCharacters(in: .whitespaces)
        guard s.lowercased().hasPrefix("bytes") else { return nil }
        s = String(s.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: " ="))
        let parts = s.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start
        else { return nil }
        let total: Int64?
        if parts[1] == "*" {
            total = nil
        } else {
            guard let t = Int64(parts[1]), t > end else { return nil }
            total = t
        }
        return ContentRange(start: start, end: end, total: total)
    }

    /// 416 응답의 `bytes */1234`
    public static func unsatisfiedTotal(_ header: String?) -> Int64? {
        guard let header else { return nil }
        let s = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard s.hasPrefix("bytes"), let slash = s.lastIndex(of: "/") else { return nil }
        let head = s[s.index(s.startIndex, offsetBy: 5)..<slash].trimmingCharacters(in: .whitespaces)
        guard head == "*" else { return nil }
        return Int64(s[s.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}

/// HTTP 응답에서 다운로드에 필요한 것만 추린 것. 헤더 이름은 소문자.
public struct HTTPResponseInfo: Sendable {
    public var statusCode: Int
    public var url: URL?
    public var headers: [String: String]

    public init(statusCode: Int, url: URL?, headers: [String: String]) {
        self.statusCode = statusCode
        self.url = url
        var lower: [String: String] = [:]
        for (k, v) in headers { lower[k.lowercased()] = v }
        self.headers = lower
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public var contentLength: Int64? {
        guard let v = header("content-length"), let n = Int64(v.trimmingCharacters(in: .whitespaces)), n >= 0 else { return nil }
        return n
    }

    public var contentRange: ContentRange? { ContentRange.parse(header("content-range")) }

    public var mimeType: String? {
        guard let v = header("content-type") else { return nil }
        let mime = v.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return mime.isEmpty ? nil : mime
    }

    /// If-Range에 쓸 값. 약한 ETag(W/)는 If-Range에 못 쓰니 Last-Modified로.
    public var validator: String? {
        if let etag = header("etag")?.trimmingCharacters(in: .whitespaces), !etag.isEmpty, !etag.hasPrefix("W/") {
            return etag
        }
        if let lm = header("last-modified")?.trimmingCharacters(in: .whitespaces), !lm.isEmpty {
            return lm
        }
        return nil
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

public enum ContentDisposition {
    /// `attachment; filename*=UTF-8''%ED%95%9C.zip; filename="a.zip"` → 파일 이름
    public static func filename(from header: String?) -> String? {
        guard let header else { return nil }
        let params = parameters(header)
        if let ext = params["filename*"], let decoded = decodeExtended(ext), !decoded.isEmpty {
            return decoded
        }
        if var plain = params["filename"], !plain.isEmpty {
            plain = repairMojibake(plain)
            // 일부 서버는 filename=에도 %XX를 넣는다
            if plain.contains("%"), let dec = plain.removingPercentEncoding, dec != plain, !dec.contains("\u{FFFD}") {
                plain = dec
            }
            return plain
        }
        return nil
    }

    public static func isAttachment(_ header: String?) -> Bool {
        guard let header else { return false }
        return header.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
    }

    /// `;`로 나눈 파라미터(따옴표 안의 `;`는 무시). 이름은 소문자.
    static func parameters(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in header {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inQuotes {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let name = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                // 따옴표 안의 \x → x
                var unescaped = ""
                var esc = false
                for ch in value {
                    if esc {
                        unescaped.append(ch)
                        esc = false
                    } else if ch == "\\" {
                        esc = true
                    } else {
                        unescaped.append(ch)
                    }
                }
                value = unescaped
            }
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    /// RFC 5987: `UTF-8'ko'%ED%95%9C.zip`
    static func decodeExtended(_ value: String) -> String? {
        let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return value.removingPercentEncoding }
        let charset = pieces[0].lowercased()
        let encoded = String(pieces[2])
        if charset == "utf-8" || charset.isEmpty {
            return encoded.removingPercentEncoding
        }
        // ISO-8859-1 등: %XX를 바이트로 풀고 그 문자셋으로 읽는다
        var bytes: [UInt8] = []
        var i = encoded.startIndex
        while i < encoded.endIndex {
            let ch = encoded[i]
            if ch == "%", encoded.distance(from: i, to: encoded.endIndex) >= 3,
               let b = UInt8(encoded[encoded.index(after: i)..<encoded.index(i, offsetBy: 3)], radix: 16) {
                bytes.append(b)
                i = encoded.index(i, offsetBy: 3)
            } else {
                bytes.append(contentsOf: Array(String(ch).utf8))
                i = encoded.index(after: i)
            }
        }
        return String(bytes: bytes, encoding: .isoLatin1)
    }

    /// 서버가 UTF-8 바이트를 그대로 보냈는데 Latin-1로 읽혀 깨진 이름을 되살린다.
    public static func repairMojibake(_ s: String) -> String {
        var bytes: [UInt8] = []
        var hasHigh = false
        for scalar in s.unicodeScalars {
            guard scalar.value <= 0xFF else { return s }
            if scalar.value >= 0x80 { hasHigh = true }
            bytes.append(UInt8(scalar.value))
        }
        guard hasHigh, let fixed = String(bytes: bytes, encoding: .utf8) else { return s }
        return fixed
    }
}

public enum FileNamer {
    static let mimeExtensions: [String: String] = [
        "video/mp4": "mp4", "video/quicktime": "mov", "video/x-m4v": "m4v", "video/webm": "webm",
        "video/x-matroska": "mkv", "video/mp2t": "ts", "video/x-msvideo": "avi", "video/3gpp": "3gp",
        "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/aac": "aac", "audio/wav": "wav",
        "audio/x-wav": "wav", "audio/flac": "flac", "audio/ogg": "ogg", "audio/opus": "opus", "audio/webm": "weba",
        "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic",
        "image/svg+xml": "svg", "application/pdf": "pdf", "application/zip": "zip",
        "application/x-zip-compressed": "zip", "application/x-rar-compressed": "rar", "application/vnd.rar": "rar",
        "application/x-7z-compressed": "7z", "application/gzip": "gz", "application/x-gzip": "gz",
        "application/x-tar": "tar", "application/x-bzip2": "bz2", "application/x-xz": "xz",
        "application/vnd.android.package-archive": "apk", "application/octet-stream": "",
        "application/x-apple-diskimage": "dmg", "application/x-msdownload": "exe", "application/x-iso9660-image": "iso",
        "application/json": "json", "text/plain": "txt", "text/csv": "csv", "text/html": "html",
        "application/vnd.apple.mpegurl": "m3u8", "application/x-mpegurl": "m3u8", "audio/mpegurl": "m3u8",
        "application/epub+zip": "epub", "application/msword": "doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.ms-excel": "xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.ms-powerpoint": "ppt",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "application/x-bittorrent": "torrent", "application/vnd.debian.binary-package": "deb",
        "application/x-ios-app": "ipa", "font/ttf": "ttf", "font/otf": "otf", "font/woff2": "woff2",
    ]

    public static func fileExtension(forMIME mime: String?) -> String? {
        guard let mime else { return nil }
        let ext = mimeExtensions[mime.lowercased()]
        return ext?.isEmpty == true ? nil : ext
    }

    /// 응답과 URL로 이름을 정한다(Content-Disposition > URL 마지막 경로 > download).
    public static func suggestedName(url: URL, contentDisposition: String? = nil, mimeType: String? = nil) -> String {
        var name = ContentDisposition.filename(from: contentDisposition) ?? ""
        if name.isEmpty {
            let last = url.lastPathComponent
            if last != "/" && !last.isEmpty {
                name = last.removingPercentEncoding ?? last
                name = ContentDisposition.repairMojibake(name)
            }
        }
        if name.isEmpty || name == "/" {
            name = url.host.map { $0.replacingOccurrences(of: ".", with: "_") } ?? "download"
        }
        name = sanitize(name)
        if (name as NSString).pathExtension.isEmpty, let ext = fileExtension(forMIME: mimeType) {
            name += "." + ext
        }
        return name
    }

    /// 파일 시스템에 못 쓰는 글자를 바꾸고 길이를 줄인다(확장자는 남긴다).
    public static func sanitize(_ raw: String) -> String {
        var s = ""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "/", "\\", ":", "*", "?", "\"", "<", ">", "|": s.append("_")
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { continue }
                s.unicodeScalars.append(scalar)
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
        if s.isEmpty { s = "download" }
        // UTF-8 200바이트까지(APFS 이름 한도 255바이트)
        if s.utf8.count > 200 {
            let ext = (s as NSString).pathExtension
            var base = (s as NSString).deletingPathExtension
            let keep = 200 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
            while base.utf8.count > keep, !base.isEmpty { base.removeLast() }
            s = ext.isEmpty ? base : base + "." + ext
        }
        return s
    }

    /// dir 안에서 겹치지 않는 이름: `a.zip` → `a (1).zip`
    public static func uniqueName(_ name: String, in dir: URL, reserved: Set<String> = []) -> String {
        let fm = FileManager.default
        func taken(_ n: String) -> Bool {
            reserved.contains(n.lowercased()) || fm.fileExists(atPath: dir.appendingPathComponent(n).path)
        }
        if !taken(name) { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var i = 1
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            if !taken(candidate) { return candidate }
            i += 1
        }
    }

    public static func replacingExtension(_ name: String, with ext: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? name : base) + "." + ext
    }
}

public enum ByteFormat {
    public static func size(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if bytes < 1024 { return "\(bytes) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / 1024 / 1024) }
        return String(format: "%.2f GB", b / 1024 / 1024 / 1024)
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond <= 0 { return "0 B/s" }
        return size(Int64(bytesPerSecond)) + "/s"
    }

    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        if s < 86400 { return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60) }
        return String(format: "%dd %02dh", s / 86400, (s % 86400) / 3600)
    }
}

/// 최근 몇 초 동안 받은 양으로 속도를 잰다(0.25초 칸으로 모아 둔다).
public struct SpeedMeter: Sendable {
    private var buckets: [(start: Double, bytes: Int64)] = []
    private let window: Double

    public init(window: Double = 4) {
        self.window = window
    }

    public mutating func add(_ bytes: Int64, now: Double) {
        if let last = buckets.last, now - last.start < 0.25 {
            buckets[buckets.count - 1].bytes += bytes
        } else {
            buckets.append((now, bytes))
        }
        while let first = buckets.first, now - first.start > window {
            buckets.removeFirst()
        }
    }

    public mutating func reset() {
        buckets.removeAll()
    }

    public func bytesPerSecond(now: Double) -> Double {
        var sum: Int64 = 0
        var oldest: Double?
        for b in buckets where now - b.start <= window {
            sum += b.bytes
            if oldest == nil { oldest = b.start }
        }
        guard let oldest, sum > 0 else { return 0 }
        return Double(sum) / max(now - oldest, 1)
    }
}

public extension Date {
    static var monotonicNow: Double { ProcessInfo.processInfo.systemUptime }
}
