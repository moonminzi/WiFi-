import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 받기 전에 링크를 한 번 찔러 본 결과
public struct LinkInfo: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// 받을 파일
        case file
        /// HLS 재생 목록(m3u8)
        case hls
        /// 웹 페이지 — 브라우저로 열어서 동영상/파일을 찾는다
        case page
    }

    public var url: URL
    public var statusCode: Int
    public var totalBytes: Int64?
    public var acceptsRanges: Bool
    public var mimeType: String?
    public var suggestedName: String
    public var kind: Kind
}

public enum LinkProbe {
    public static let hlsTypes: Set<String> = ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl",
                                        "audio/x-mpegurl", "application/mpegurl"]

    /// 첫 응답 머리만 보고 끊는다(본문은 안 받음).
    public static func inspect(_ url: URL, headers: [String: String] = [:], userAgent: String = EngineSettings.safariUA) async throws -> LinkInfo {
        var h = headers
        if h.keys.first(where: { $0.lowercased() == "user-agent" }) == nil { h["User-Agent"] = userAgent }
        let info = try await HTTPFetch.head(ChannelRequest(url: url, headers: h, rangeStart: 0),
                                            options: ChannelOptions(timeout: 20, useCookieStore: h["Cookie"] == nil))
        return describe(info, requested: url)
    }

    public static func describe(_ info: HTTPResponseInfo, requested url: URL) -> LinkInfo {
        let final = info.url ?? url
        var total: Int64?
        var ranges = false
        if info.statusCode == 206 {
            ranges = true
            total = info.contentRange?.total
        } else if info.isSuccess {
            total = info.contentLength
        } else if info.statusCode == 416 {
            ranges = true
            total = ContentRange.unsatisfiedTotal(info.header("content-range"))
        }
        let mime = info.mimeType
        let ext = final.pathExtension.lowercased()
        let kind: LinkInfo.Kind
        if let mime, hlsTypes.contains(mime) {
            kind = .hls
        } else if ext == "m3u8" && (mime == nil || mime == "application/octet-stream" || mime == "text/plain" || mime?.hasPrefix("text/") == true) {
            kind = .hls
        } else if (mime == "text/html" || mime == "application/xhtml+xml"),
                  !ContentDisposition.isAttachment(info.header("content-disposition")) {
            kind = .page
        } else {
            kind = .file
        }
        var name = FileNamer.suggestedName(url: final, contentDisposition: info.header("content-disposition"), mimeType: mime)
        if kind == .hls { name = FileNamer.replacingExtension(name, with: "mp4") }
        return LinkInfo(url: final, statusCode: info.statusCode, totalBytes: total, acceptsRanges: ranges,
                        mimeType: mime, suggestedName: name, kind: kind)
    }

    /// 글 안에서 첫 http(s) 링크를 찾는다(공유·붙여넣기용).
    public static func firstURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: trimmed), let s = u.scheme?.lowercased(), s == "http" || s == "https", u.host != nil {
            return u
        }
        for token in trimmed.components(separatedBy: .whitespacesAndNewlines) {
            guard let r = token.range(of: "http", options: .caseInsensitive) else { continue }
            var candidate = String(token[r.lowerBound...])
            while let last = candidate.last, ")]}>\"'.,;".contains(last) { candidate.removeLast() }
            if let u = URL(string: candidate) ?? URL(string: candidate.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
               let s = u.scheme?.lowercased(), s == "http" || s == "https", u.host != nil {
                return u
            }
        }
        return nil
    }

    /// 주소창 입력: 링크면 그대로(https 붙여서), 아니면 nil
    public static func urlFromAddressBar(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if let u = URL(string: t), let s = u.scheme?.lowercased(), ["http", "https"].contains(s), u.host != nil { return u }
        // 점이 있고 공백이 없으면 주소로 본다(example.com/path)
        if t.contains("."), let u = URL(string: "https://" + t), u.host?.contains(".") == true { return u }
        return nil
    }
}

extension DownloadManager {
    /// 브라우저(WKDownload)가 직접 받은 파일을 완료 목록에 넣는다.
    public func addCompletedFile(at file: URL, name: String, sourceURL: URL, pageURL: URL? = nil, mimeType: String? = nil) {
        queue.async {
            let fm = FileManager.default
            let unique = FileNamer.uniqueName(FileNamer.sanitize(name), in: self.paths.output)
            let target = self.paths.output.appendingPathComponent(unique)
            do {
                if file.standardizedFileURL != target.standardizedFileURL {
                    try fm.moveItem(at: file, to: target)
                }
            } catch {
                return
            }
            let size = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
            var record = DownloadRecord(kind: .file, sourceURL: sourceURL, pageURL: pageURL, headers: [:], fileName: unique,
                                        maxConnections: 1, nameLocked: true)
            record.totalBytes = size
            record.segments = size > 0 ? [Segment(start: 0, end: size - 1, received: size)] : []
            record.mimeType = mimeType
            self.insertCompleted(record, savedName: unique)
        }
    }
}
