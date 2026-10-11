import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 마스터 재생 목록의 화질 하나
public struct HLSVariant: Sendable, Equatable, Identifiable {
    public var id: String { url.absoluteString }
    public var url: URL
    public var bandwidth: Int?
    public var averageBandwidth: Int?
    public var width: Int?
    public var height: Int?
    public var codecs: String?
    public var frameRate: Double?
    public var audioGroup: String?

    public var isAudioOnly: Bool {
        guard height == nil else { return false }
        guard let codecs = codecs?.lowercased() else { return false }
        return !codecs.contains("avc") && !codecs.contains("hvc") && !codecs.contains("hev") && !codecs.contains("av01")
            && !codecs.contains("vp09") && codecs.contains("mp4a")
    }

    /// "1080p · 5.2 Mbps"
    public var label: String {
        var parts: [String] = []
        if let height { parts.append("\(height)p") } else if isAudioOnly { parts.append("오디오") }
        if let bw = averageBandwidth ?? bandwidth {
            parts.append(bw >= 1_000_000 ? String(format: "%.1f Mbps", Double(bw) / 1_000_000) : "\(bw / 1000) kbps")
        }
        return parts.isEmpty ? url.lastPathComponent : parts.joined(separator: " · ")
    }
}

/// #EXT-X-MEDIA (따로 있는 오디오/자막)
public struct HLSRendition: Sendable, Equatable {
    public var type: String
    public var groupID: String
    public var name: String?
    public var language: String?
    public var isDefault: Bool
    public var url: URL?
}

public struct HLSMediaSegment: Sendable, Equatable {
    public var url: URL
    public var duration: Double
    public var rangeLength: Int64?
    public var rangeOffset: Int64?
    public var discontinuity: Bool
    /// NONE이 아닌 암호화 방식(AES-128, SAMPLE-AES…)
    public var keyMethod: String?
    public var mapURL: URL?
    public var mapRangeLength: Int64?
    public var mapRangeOffset: Int64?
}

public struct HLSMediaPlaylist: Sendable, Equatable {
    public var segments: [HLSMediaSegment]
    public var endList: Bool
    public var playlistType: String?
    public var targetDuration: Double?

    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    public var isEncrypted: Bool { segments.contains { $0.keyMethod != nil } }
}

public enum HLSPlaylist: Sendable, Equatable {
    case master(variants: [HLSVariant], renditions: [HLSRendition])
    case media(HLSMediaPlaylist)
}

public enum HLSError: Error, LocalizedError, Equatable {
    case notPlaylist
    case encrypted(String)
    case live
    case empty
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notPlaylist: return "m3u8 재생 목록이 아니에요"
        case .encrypted(let m): return "암호화된 영상(\(m))이라 받을 수 없어요"
        case .live: return "라이브 방송은 아직 받을 수 없어요"
        case .empty: return "재생 목록이 비어 있어요"
        case .unsupported(let s): return "지원하지 않는 형식: \(s)"
        }
    }
}

public enum M3U8 {
    public static func looksLikePlaylist(_ data: Data) -> Bool {
        var text = String(decoding: data.prefix(64), as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }

    public static func parse(_ data: Data, baseURL: URL) throws -> HLSPlaylist {
        try parse(String(decoding: data, as: UTF8.self), baseURL: baseURL)
    }

    public static func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = String(first.dropFirst()) }
        guard lines.first(where: { !$0.isEmpty })?.hasPrefix("#EXTM3U") == true else { throw HLSError.notPlaylist }

        var variants: [HLSVariant] = []
        var renditions: [HLSRendition] = []
        var segments: [HLSMediaSegment] = []
        var pendingVariant: [String: String]?
        var pendingDuration: Double?
        var pendingRange: (Int64, Int64?)?
        var pendingDiscontinuity = false
        var keyMethod: String?
        var map: (URL, Int64?, Int64?)?
        var lastRangeEnd: [URL: Int64] = [:]
        var endList = false
        var playlistType: String?
        var target: Double?

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#") {
                let (tag, value) = splitTag(line)
                switch tag {
                case "#EXT-X-STREAM-INF":
                    pendingVariant = attributes(value)
                case "#EXT-X-MEDIA":
                    let a = attributes(value)
                    renditions.append(HLSRendition(type: a["TYPE"] ?? "", groupID: a["GROUP-ID"] ?? "", name: a["NAME"],
                                                   language: a["LANGUAGE"], isDefault: a["DEFAULT"] == "YES",
                                                   url: a["URI"].flatMap { resolve($0, baseURL) }))
                case "#EXTINF":
                    pendingDuration = Double(value.split(separator: ",", maxSplits: 1).first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                case "#EXT-X-BYTERANGE":
                    pendingRange = byteRange(value)
                case "#EXT-X-DISCONTINUITY":
                    pendingDiscontinuity = true
                case "#EXT-X-KEY":
                    let a = attributes(value)
                    let method = (a["METHOD"] ?? "NONE").uppercased()
                    keyMethod = method == "NONE" ? nil : method
                case "#EXT-X-MAP":
                    let a = attributes(value)
                    if let uri = a["URI"], let url = resolve(uri, baseURL) {
                        let r = a["BYTERANGE"].flatMap { byteRange($0) }
                        map = (url, r?.0, r?.1 ?? (r == nil ? nil : 0))
                    }
                case "#EXT-X-ENDLIST":
                    endList = true
                case "#EXT-X-PLAYLIST-TYPE":
                    playlistType = value.uppercased()
                case "#EXT-X-TARGETDURATION":
                    target = Double(value)
                default:
                    break
                }
                continue
            }
            // URI 줄
            guard let url = resolve(line, baseURL) else { continue }
            if let attrs = pendingVariant {
                var v = HLSVariant(url: url)
                v.bandwidth = attrs["BANDWIDTH"].flatMap { Int($0) }
                v.averageBandwidth = attrs["AVERAGE-BANDWIDTH"].flatMap { Int($0) }
                if let res = attrs["RESOLUTION"]?.lowercased().split(separator: "x"), res.count == 2 {
                    v.width = Int(res[0])
                    v.height = Int(res[1])
                }
                v.codecs = attrs["CODECS"]
                v.frameRate = attrs["FRAME-RATE"].flatMap { Double($0) }
                v.audioGroup = attrs["AUDIO"]
                variants.append(v)
                pendingVariant = nil
            } else if let duration = pendingDuration {
                var seg = HLSMediaSegment(url: url, duration: duration, discontinuity: pendingDiscontinuity,
                                          keyMethod: keyMethod)
                if let (len, off) = pendingRange {
                    let offset = off ?? lastRangeEnd[url] ?? 0
                    seg.rangeLength = len
                    seg.rangeOffset = offset
                    lastRangeEnd[url] = offset + len
                }
                if let map {
                    seg.mapURL = map.0
                    seg.mapRangeLength = map.1
                    seg.mapRangeOffset = map.2
                }
                segments.append(seg)
                pendingDuration = nil
                pendingRange = nil
                pendingDiscontinuity = false
            }
        }
        if !variants.isEmpty {
            return .master(variants: variants, renditions: renditions)
        }
        return .media(HLSMediaPlaylist(segments: segments, endList: endList || playlistType == "VOD",
                                       playlistType: playlistType, targetDuration: target))
    }

    static func splitTag(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        return (String(line[..<colon]), String(line[line.index(after: colon)...]))
    }

    /// `A=1,B="x,y",C=z` → 사전
    static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var inQuotes = false
        func commit() {
            let k = key.trimmingCharacters(in: .whitespaces).uppercased()
            if !k.isEmpty { out[k] = value }
            key = ""
            value = ""
            inKey = true
        }
        for ch in s {
            if inKey {
                if ch == "=" { inKey = false } else if ch == "," { commit() } else { key.append(ch) }
            } else if inQuotes {
                if ch == "\"" { inQuotes = false } else { value.append(ch) }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                commit()
            } else {
                value.append(ch)
            }
        }
        commit()
        return out
    }

    /// `1000@200` → (길이, 시작)
    static func byteRange(_ s: String) -> (Int64, Int64?)? {
        let p = s.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).split(separator: "@")
        guard let len = p.first.flatMap({ Int64($0) }) else { return nil }
        return (len, p.count > 1 ? Int64(p[1]) : nil)
    }

    static func resolve(_ s: String, _ base: URL) -> URL? {
        if let u = URL(string: s, relativeTo: base) { return u.absoluteURL }
        let escaped = s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? s
        return URL(string: escaped, relativeTo: base)?.absoluteURL
    }
}

/// 받기 전에 재생 목록을 읽어 화질을 보여 주고, 고른 화질로 HLSJob을 만든다.
public enum HLSLoader {
    public struct Info: Sendable {
        public var url: URL
        public var variants: [HLSVariant]
        public var renditions: [HLSRendition]
        /// 바로 미디어 목록이면 채워진다
        public var media: HLSMediaPlaylist?
    }

    public static func load(_ url: URL, headers: [String: String]) async throws -> Info {
        let (info, data) = try await HTTPFetch.fetch(ChannelRequest(url: url, headers: headers))
        guard info.isSuccess else { throw ChannelError.http(info.statusCode) }
        let base = info.url ?? url
        switch try M3U8.parse(data, baseURL: base) {
        case .master(let variants, let renditions):
            // 화질 높은 순
            let sorted = variants.sorted { ($0.height ?? 0, $0.bandwidth ?? 0) > ($1.height ?? 0, $1.bandwidth ?? 0) }
            return Info(url: base, variants: sorted, renditions: renditions, media: nil)
        case .media(let media):
            return Info(url: base, variants: [], renditions: [], media: media)
        }
    }

    /// 고른 화질(없으면 미디어 목록 그대로)로 받을 조각 목록을 만든다.
    public static func makeJob(_ info: Info, variant: HLSVariant?, headers: [String: String]) async throws -> HLSJob {
        var media: HLSMediaPlaylist
        var playlistURL = info.url
        if let variant {
            let loaded = try await load(variant.url, headers: headers)
            guard let m = loaded.media else { throw HLSError.unsupported("중첩된 재생 목록") }
            media = m
            playlistURL = loaded.url
        } else if let m = info.media {
            media = m
        } else {
            throw HLSError.empty
        }
        let (container, initPart, parts) = try describe(media)

        var job = HLSJob(playlistURL: playlistURL, label: variant?.label, container: container, initSegment: initPart,
                         parts: parts, duration: media.duration)

        // 오디오가 따로 있는 화질이면 같이 받는다(기본 오디오, 없으면 첫 번째)
        if let group = variant?.audioGroup {
            let candidates = info.renditions.filter { $0.type.uppercased() == "AUDIO" && $0.groupID == group && $0.url != nil }
            if let audio = candidates.first(where: \.isDefault) ?? candidates.first, let audioURL = audio.url {
                let loaded = try await load(audioURL, headers: headers)
                guard let am = loaded.media else { throw HLSError.unsupported("오디오 목록") }
                let (ac, ainit, aparts) = try describe(am)
                job.audioPlaylistURL = loaded.url
                job.audioContainer = ac
                job.audioInit = ainit
                job.audioParts = aparts
            }
        }
        return job
    }

    static func describe(_ media: HLSMediaPlaylist) throws -> (HLSContainer, HLSPart?, [HLSPart]) {
        guard !media.segments.isEmpty else { throw HLSError.empty }
        if let method = media.segments.compactMap(\.keyMethod).first { throw HLSError.encrypted(method) }
        guard media.endList else { throw HLSError.live }
        let maps = Set(media.segments.compactMap { seg -> String? in
            guard let url = seg.mapURL else { return nil }
            return "\(url.absoluteString)#\(seg.mapRangeOffset ?? -1)-\(seg.mapRangeLength ?? -1)"
        })
        let first = media.segments[0]
        var container: HLSContainer = .ts
        var initPart: HLSPart?
        if let mapURL = first.mapURL {
            guard maps.count == 1 else { throw HLSError.unsupported("init 조각이 여러 개") }
            container = .fmp4
            initPart = HLSPart(url: mapURL, rangeOffset: first.mapRangeOffset, rangeLength: first.mapRangeLength)
        } else {
            let ext = first.url.pathExtension.lowercased()
            if ["aac", "adts"].contains(ext) {
                container = .packedAudio
            } else if ["mp3", "ac3", "ec3", "eac3"].contains(ext) {
                throw HLSError.unsupported(ext)
            } else if ["m4s", "mp4", "m4a", "m4v", "cmfv", "cmfa"].contains(ext) {
                container = .fmp4
            }
        }
        let parts = media.segments.map {
            HLSPart(url: $0.url, rangeOffset: $0.rangeOffset, rangeLength: $0.rangeLength, duration: $0.duration,
                    discontinuity: $0.discontinuity)
        }
        return (container, initPart, parts)
    }
}
