import Foundation

/// Claude API(번역 엔진) 요청·응답. 전송은 앱이 URLSession으로 하고, 여기서는 본문을 만들고 응답을 읽는다.
public enum ClaudeAPI {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// 그림 읽기·번역 모두 가장 뛰어난 모델 하나로
    public static let model = "claude-opus-5-5"
    public static let version = "2023-06-01"
    /// 안전 분류기가 잘못 막으면 서버가 알아서 다른 모델로 다시 돌린다
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// 이보다 크면 서버가 줄여서 상자 좌표가 어긋나므로 미리 맞춰 보낸다
    public static let maxLongEdge = 2576
    public static let maxPixels = 3_750_000
    /// 1백만 토큰당 달러(입력, 출력, 캐시 읽기, 캐시 쓰기 5분)
    public static let price = (input: 4.0, output: 20.0, cacheRead: 0.20, cacheWrite: 5.0)

    public static func headers(apiKey: String) -> [String: String] {
        [
            "x-api-key": apiKey,
            "anthropic-version": version,
            "anthropic-beta": fallbackBeta,
            "content-type": "application/json",
            "accept": "text/event-stream",
        ]
    }

    /// 보낼 그림 크기(좌표가 그림 픽셀과 1:1이 되도록 한도 안으로)
    public static func fittedSize(width: Int, height: Int) -> (Int, Int) {
        var s = min(1.0, Double(maxLongEdge) / Double(max(width, height)))
        let px = Double(width) * Double(height) * s * s
        if px > Double(maxPixels) { s *= (Double(maxPixels) / px).squareRoot() }
        return (max(1, Int(Double(width) * s)), max(1, Int(Double(height) * s)))
    }
}

/// 사용량과 비용
public struct Usage: Codable, Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var dollars: Double {
        let p = ClaudeAPI.price
        return (Double(input) * p.input + Double(output) * p.output + Double(cacheRead) * p.cacheRead
            + Double(cacheWrite) * p.cacheWrite) / 1_000_000
    }

    public static func + (a: Usage, b: Usage) -> Usage {
        Usage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
              cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

/// 작품 용어집 항목(이름·지명·기술 이름 등을 계속 같은 말로)
public struct GlossaryEntry: Codable, Sendable, Equatable, Hashable {
    public var source: String
    public var korean: String
    public var note: String

    public init(source: String, korean: String, note: String = "") {
        self.source = source
        self.korean = korean
        self.note = note
    }

    /// 새 용어를 더한다(같은 원어가 있으면 그대로 둔다 — 사용자가 고친 걸 덮지 않게)
    public static func merge(_ list: [GlossaryEntry], adding new: [GlossaryEntry]) -> [GlossaryEntry] {
        var out = list
        var seen = Set(list.map { $0.source.trimmingCharacters(in: .whitespaces).lowercased() })
        for e in new {
            let key = e.source.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, !e.korean.trimmingCharacters(in: .whitespaces).isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(e)
        }
        return out
    }
}

/// 번역할 때 같이 주는 맥락
public struct TranslationContext: Sendable, Equatable {
    public var glossary: [GlossaryEntry]
    /// 앞 페이지 요약(오래된 것부터)
    public var previousSummaries: [String]
    /// 사용자가 적어 둔 작품 메모(제목, 등장인물, 말투 등)
    public var bookNote: String
    /// 긴 세로 그림을 나눈 조각이면 (몇 번째, 모두 몇 개)
    public var segment: (index: Int, count: Int)?

    public init(glossary: [GlossaryEntry] = [], previousSummaries: [String] = [], bookNote: String = "",
                segment: (index: Int, count: Int)? = nil) {
        self.glossary = glossary
        self.previousSummaries = previousSummaries
        self.bookNote = bookNote
        self.segment = segment
    }

    public static func == (a: TranslationContext, b: TranslationContext) -> Bool {
        a.glossary == b.glossary && a.previousSummaries == b.previousSummaries && a.bookNote == b.bookNote
            && a.segment?.index == b.segment?.index && a.segment?.count == b.segment?.count
    }
}

/// Claude가 돌려주는 한 페이지 답
public struct PageAnswer: Codable, Sendable, Equatable {
    public struct Box: Codable, Sendable, Equatable {
        public var x0: Int
        public var y0: Int
        public var x1: Int
        public var y1: Int

        public init(x0: Int, y0: Int, x1: Int, y1: Int) {
            self.x0 = x0
            self.y0 = y0
            self.x1 = x1
            self.y1 = y1
        }

        public var rect: IRect {
            IRect(x: min(x0, x1), y: min(y0, y1), w: abs(x1 - x0), h: abs(y1 - y0))
        }
    }

    public struct Block: Codable, Sendable, Equatable {
        public var kind: String
        public var box: Box
        public var source: String
        public var translation: String
        public var note: String

        public init(kind: String, box: Box, source: String, translation: String, note: String = "") {
            self.kind = kind
            self.box = box
            self.source = source
            self.translation = translation
            self.note = note
        }

        public var blockKind: BlockKind { BlockKind(rawValue: kind) ?? .other }
    }

    public var source_language: String
    public var blocks: [Block]
    public var page_summary: String
    public var new_terms: [GlossaryEntry]

    public init(source_language: String, blocks: [Block], page_summary: String, new_terms: [GlossaryEntry]) {
        self.source_language = source_language
        self.blocks = blocks
        self.page_summary = page_summary
        self.new_terms = new_terms
    }

    enum CodingKeys: String, CodingKey {
        case source_language, blocks, page_summary, new_terms
    }

    struct Term: Codable {
        var source: String
        var korean: String
        var note: String
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source_language = (try? c.decode(String.self, forKey: .source_language)) ?? ""
        blocks = try c.decode([Block].self, forKey: .blocks)
        page_summary = (try? c.decode(String.self, forKey: .page_summary)) ?? ""
        new_terms = ((try? c.decode([Term].self, forKey: .new_terms)) ?? []).map {
            GlossaryEntry(source: $0.source, korean: $0.korean, note: $0.note)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source_language, forKey: .source_language)
        try c.encode(blocks, forKey: .blocks)
        try c.encode(page_summary, forKey: .page_summary)
        try c.encode(new_terms.map { Term(source: $0.source, korean: $0.korean, note: $0.note) }, forKey: .new_terms)
    }
}

public enum PageRequest {
    /// 늘 같은 지시(캐시된다)
    public static let systemPrompt = """
    You are NAGO TL, an expert translator and letterer of manga, manhwa, manhua, webtoons and comics, and of \
    text in real-world photos (signs, menus, packages, screens, documents). You receive one image and return every \
    piece of text a Korean reader needs translated, with its exact location, translated into natural Korean.

    # What to return for each text block
    - kind: one of
      - speech: dialogue in a speech bubble, or floating dialogue next to a speaker
      - thought: inner monologue (cloud bubbles, unbordered thought text)
      - narration: narrative boxes or captions that tell the story
      - caption: titles, chapter headings, labels added by the author (not credits or page numbers)
      - sfx: sound effects and mimetic words drawn as part of the artwork
      - sign: text on objects inside the scene or photo (signs, screens, letters, books, labels, menus, packaging)
      - other: anything else that needs translating
    - box: the tight pixel bounding box of the glyphs of that block, in this image's pixel coordinates \
    (x0,y0 = top-left, x1,y1 = bottom-right). Hug the letters themselves, not the speech bubble outline. Include \
    furigana/ruby and punctuation that belong to the block. One block per speech bubble, caption box or sign; never \
    merge separate bubbles; text that continues across two bubbles is two blocks.
    - source: the original text exactly as written. Vertical Japanese/Chinese is read top-to-bottom, columns \
    right-to-left; join its lines without adding spaces. Leave furigana out of source.
    - translation: the Korean translation (see guidelines).
    - note: a short note in Korean only when something cannot be carried over (a pun, wordplay, a cultural \
    reference the reader needs); otherwise an empty string.

    List blocks in natural reading order (Japanese manga: panels right-to-left then top-to-bottom; within a panel \
    right-to-left, top-to-bottom. Korean, Chinese webtoons and Western comics: left-to-right, top-to-bottom).

    # Skip
    - Text that is already Korean.
    - Page numbers, watermarks, scanlator or publisher credits, URLs, and decorative text that carries no meaning.
    - Text that is too small or blurry to read with confidence; do not guess.

    # Translation guidelines
    - Write what a skilled Korean manga translator would publish: fluent, natural spoken Korean for dialogue, never \
    word-for-word. Keep each character's voice (age, gender, personality, mood) and keep 반말/존댓말 consistent with \
    how characters address each other across pages.
    - Keep the energy: shouting, stammering ("그, 그게…"), drawn-out sounds ("으아아아"), trailing "…", "!?" and \
    emphasis. Use "…" for ellipses and "~" for sing-song endings where the original does.
    - Keep it concise so it fits the bubble; Korean manga lettering favors short, punchy lines.
    - Honorifics: render naturally (先輩→선배, 先生→선생님, 様→님; さん/ちゃん/くん usually dropped or turned into a natural \
    Korean form such as a nickname or "~씨" when it matters).
    - Names and recurring terms: always use the glossary rendering when one is given. For new Japanese names, use the \
    transliteration most familiar to Korean manga readers (つ→츠, e.g. 츠카사; long vowels usually dropped: 사토, 유키).
    - Sound effects: give a natural Korean onomatopoeia or mimetic word of similar feel and length \
    (ドドド→두두두, ゴゴゴ→우우웅, ドキドキ→두근두근, ザワザワ→웅성웅성, シーン→조용…). Keep it short.
    - Signs and photos: translate the meaning so a traveller understands it; keep numbers, prices, times and brand \
    names as they are; for menus give the dish name the way a Korean menu would.
    - Translate faithfully, including rough language; do not censor, soften or add commentary inside the translation.
    - Never put line breaks in a translation; the app lays out the lines to fit the bubble.

    # Also return
    - source_language: ISO 639-1 code of the main source language (ja, zh, en, ko, ...).
    - page_summary: 1-3 short Korean sentences on what happens on this page and who says what, for continuity.
    - new_terms: character names, places, techniques and recurring jargon that appear here and are not yet in the \
    glossary, with the Korean rendering you used (note: who/what it is, in a few Korean words).
    """

    /// 구조화 출력 스키마(모든 객체에 required + additionalProperties:false)
    public static var schema: [String: Any] {
        let box: [String: Any] = [
            "type": "object",
            "properties": ["x0": ["type": "integer"], "y0": ["type": "integer"],
                           "x1": ["type": "integer"], "y1": ["type": "integer"]],
            "required": ["x0", "y0", "x1", "y1"],
            "additionalProperties": false,
        ]
        let block: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": BlockKind.allCases.map(\.rawValue)],
                "box": box,
                "source": ["type": "string"],
                "translation": ["type": "string"],
                "note": ["type": "string"],
            ],
            "required": ["kind", "box", "source", "translation", "note"],
            "additionalProperties": false,
        ]
        let term: [String: Any] = [
            "type": "object",
            "properties": ["source": ["type": "string"], "korean": ["type": "string"], "note": ["type": "string"]],
            "required": ["source", "korean", "note"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "source_language": ["type": "string"],
                "blocks": ["type": "array", "items": block],
                "page_summary": ["type": "string"],
                "new_terms": ["type": "array", "items": term],
            ],
            "required": ["source_language", "blocks", "page_summary", "new_terms"],
            "additionalProperties": false,
        ]
    }

    /// 페이지 하나 번역 요청 본문(스트리밍)
    public static func body(imageJPEG: Data, width: Int, height: Int, context: TranslationContext,
                            maxTokens: Int = 32000) -> Data {
        let content: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": imageJPEG.base64EncodedString()]],
            ["type": "text", "text": userText(width: width, height: height, context: context)],
        ]
        let body: [String: Any] = [
            "model": ClaudeAPI.model,
            "max_tokens": maxTokens,
            "stream": true,
            "fallbacks": "default",
            "system": [["type": "text", "text": systemPrompt, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": content]],
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func userText(width: Int, height: Int, context: TranslationContext) -> String {
        var parts: [String] = []
        parts.append("The image is \(width)×\(height) pixels. Give boxes in these pixel coordinates.")
        if let seg = context.segment {
            parts.append("This image is part \(seg.index + 1) of \(seg.count) of one long vertical strip (webtoon), cut "
                + "with overlap. Include text cut off at the top or bottom edge too; boxes may touch the edge.")
        }
        let note = context.bookNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { parts.append("Notes from the reader about this work:\n\(note)") }
        if !context.glossary.isEmpty {
            let lines = context.glossary.suffix(250).map { e in
                "- \(e.source) → \(e.korean)" + (e.note.isEmpty ? "" : " (\(e.note))")
            }
            parts.append("Glossary (use these renderings):\n" + lines.joined(separator: "\n"))
        }
        if !context.previousSummaries.isEmpty {
            parts.append("Story so far (previous pages, oldest first):\n"
                + context.previousSummaries.suffix(3).map { "- \($0)" }.joined(separator: "\n"))
        }
        parts.append("Find and translate all text in the image into Korean.")
        return parts.joined(separator: "\n\n")
    }

    /// 말풍선 하나를 다른 표현으로(그림 없이 글만 — 싸고 빠르다)
    public static func alternativesBody(source: String, current: String, kind: BlockKind, context: TranslationContext,
                                        pageSummary: String) -> Data {
        var text = """
        Original (\(kind.rawValue)): \(source)
        Current Korean translation: \(current)

        Give 3 alternative Korean translations for this line, each natural and fitting a manga bubble, \
        different from each other in nuance or tone (for example more casual, more literal, punchier). \
        Keep names and terms consistent with the glossary.
        """
        if !pageSummary.isEmpty { text += "\n\nWhat happens on this page: \(pageSummary)" }
        if !context.glossary.isEmpty {
            text += "\n\nGlossary:\n" + context.glossary.suffix(150).map { "- \($0.source) → \($0.korean)" }
                .joined(separator: "\n")
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["alternatives": ["type": "array", "items": ["type": "string"]]],
            "required": ["alternatives"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": ClaudeAPI.model,
            "max_tokens": 8000,
            "stream": true,
            "fallbacks": "default",
            "system": [["type": "text", "text": systemPrompt, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": [["type": "text", "text": text]]]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

/// 번역 실패 이유(사용자에게 보여 줄 말 포함)
public enum TranslateError: Error, Equatable, LocalizedError {
    case badKey
    case noCredit(String)
    case rateLimited(retryAfter: Double?)
    case overloaded
    case server(Int, String)
    case invalidRequest(String)
    case refusal(String?)
    case truncated
    case badResponse(String)
    case network(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .badKey: return "API 키가 맞지 않아요. 설정에서 키를 확인해 주세요."
        case let .noCredit(m): return "API 사용 한도/잔액 문제예요: \(m)"
        case .rateLimited: return "요청이 너무 많아요. 잠시 뒤 다시 할게요."
        case .overloaded: return "Claude 서버가 붐벼요. 잠시 뒤 다시 할게요."
        case let .server(code, m): return "서버 오류(\(code)): \(m)"
        case let .invalidRequest(m): return "요청 오류: \(m)"
        case let .refusal(c): return "Claude가 이 페이지 번역을 거절했어요" + (c.map { "(\($0))" } ?? "") + "."
        case .truncated: return "답이 너무 길어 잘렸어요."
        case let .badResponse(m): return "답을 읽지 못했어요: \(m)"
        case let .network(m): return "네트워크 오류: \(m)"
        case .cancelled: return "취소됨"
        }
    }

    /// 잠시 뒤 다시 하면 될 수 있는 오류
    public var retryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .server, .network, .truncated: return true
        default: return false
        }
    }

    /// HTTP 오류 응답을 해석한다
    public static func from(status: Int, body: Data, retryAfter: String?) -> TranslateError {
        var message = String(data: body, encoding: .utf8) ?? ""
        var type = ""
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let err = obj["error"] as? [String: Any] {
            message = err["message"] as? String ?? message
            type = err["type"] as? String ?? ""
        }
        switch status {
        case 401: return .badKey
        case 403: return .noCredit(message)
        case 429: return .rateLimited(retryAfter: retryAfter.flatMap(Double.init))
        case 529: return .overloaded
        case 400 where message.lowercased().contains("credit"): return .noCredit(message)
        case 400, 404, 413, 422: return .invalidRequest(message)
        default:
            if type == "overloaded_error" { return .overloaded }
            return .server(status, message)
        }
    }
}

/// 스트리밍(SSE) 응답을 줄 단위로 받아 최종 글을 모은다
public struct StreamAccumulator: Sendable {
    /// 구간별 글(서버가 다른 모델로 넘기면 새 구간이 시작된다)
    public private(set) var segments: [String] = [""]
    public private(set) var stopReason: String?
    public private(set) var stopCategory: String?
    public private(set) var model: String?
    public private(set) var usage = Usage()
    /// 생각 중(아직 글이 안 나옴)인지 — 진행 표시용
    public private(set) var thinking = false
    public private(set) var error: TranslateError?
    var blockTypes: [Int: String] = [:]
    var event = ""

    public init() {}

    public var text: String { segments.joined() }
    public var finished: Bool { stopReason != nil || error != nil }

    public mutating func feed(line: String) {
        if line.hasPrefix("event:") {
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return
        }
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? event
        switch type {
        case "message_start":
            if let m = obj["message"] as? [String: Any] {
                model = m["model"] as? String ?? model
                if let u = m["usage"] as? [String: Any] { absorb(u) }
            }
        case "content_block_start":
            let index = obj["index"] as? Int ?? -1
            let block = obj["content_block"] as? [String: Any] ?? [:]
            let bt = block["type"] as? String ?? ""
            blockTypes[index] = bt
            if bt == "thinking" || bt == "redacted_thinking" { thinking = true }
            if bt == "text" {
                thinking = false
                if let t = block["text"] as? String { segments[segments.count - 1] += t }
            }
            if bt == "fallback" {
                // 앞 모델이 쓰다 만 글은 다음 모델이 이어 쓴다(구간을 나눠 둔다)
                segments.append("")
            }
        case "content_block_delta":
            let delta = obj["delta"] as? [String: Any] ?? [:]
            if delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                thinking = false
                segments[segments.count - 1] += t
            }
        case "message_delta":
            if let d = obj["delta"] as? [String: Any] {
                if let r = d["stop_reason"] as? String { stopReason = r }
                if let sd = d["stop_details"] as? [String: Any] { stopCategory = sd["category"] as? String }
            }
            if let u = obj["usage"] as? [String: Any] { absorb(u) }
        case "error":
            let err = obj["error"] as? [String: Any] ?? [:]
            let et = err["type"] as? String ?? ""
            let msg = err["message"] as? String ?? "error"
            switch et {
            case "overloaded_error": error = .overloaded
            case "rate_limit_error": error = .rateLimited(retryAfter: nil)
            case "authentication_error": error = .badKey
            case "invalid_request_error": error = .invalidRequest(msg)
            default: error = .server(500, msg)
            }
        default:
            break
        }
    }

    mutating func absorb(_ u: [String: Any]) {
        if let v = u["input_tokens"] as? Int { usage.input = v }
        if let v = u["output_tokens"] as? Int { usage.output = v }
        if let v = u["cache_read_input_tokens"] as? Int { usage.cacheRead = v }
        if let v = u["cache_creation_input_tokens"] as? Int { usage.cacheWrite = v }
    }

    /// 끝난 응답에서 JSON을 꺼낸다
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if let error { throw error }
        switch stopReason {
        case "refusal": throw TranslateError.refusal(stopCategory)
        case "max_tokens": throw TranslateError.truncated
        case nil: throw TranslateError.network("응답이 중간에 끊겼어요")
        default: break
        }
        // 이어 쓴 글 전체, 안 되면 마지막 구간만
        for candidate in [text, segments.last ?? ""] {
            if let d = candidate.data(using: .utf8), let v = try? JSONDecoder().decode(T.self, from: d) { return v }
        }
        throw TranslateError.badResponse(String(text.prefix(200)))
    }
}

/// 세로로 긴 그림(웹툰)을 겹치게 잘라 따로 번역하고 합친다
public enum Tiler {
    /// 이 비율(세로/가로)을 넘으면 자른다
    public static let tallRatio = 2.4

    public static func tiles(width: Int, height: Int) -> [IRect] {
        guard Double(height) > Double(width) * tallRatio else { return [IRect(x: 0, y: 0, w: width, h: height)] }
        let tileH = Int(Double(width) * 1.6)
        let overlap = tileH / 4
        var out: [IRect] = []
        var y = 0
        while true {
            let h = min(tileH, height - y)
            out.append(IRect(x: 0, y: y, w: width, h: h))
            if y + h >= height { break }
            y += tileH - overlap
            // 마지막 조각이 너무 얇으면 앞 조각과 합쳐 끝까지
            if height - y < overlap * 2 {
                y = max(0, height - tileH)
                out.append(IRect(x: 0, y: y, w: width, h: height - y))
                break
            }
        }
        return out
    }

    /// 조각마다 받은 덩어리(전체 좌표)를 합친다: 잘린 쪽 가장자리에 걸린 건 옆 조각 것을 쓰고, 겹친 건 하나만
    public static func merge(_ parts: [(tile: IRect, blocks: [PageAnswer.Block])], height: Int) -> [PageAnswer.Block] {
        struct Item {
            var block: PageAnswer.Block
            var rect: IRect
            var cut: Bool
        }
        var items: [Item] = []
        for (t, blocks) in parts {
            for b in blocks {
                let r = b.box.rect
                let cutTop = t.y > 0 && r.y <= t.y + 3
                let cutBottom = t.maxY < height && r.maxY >= t.maxY - 3
                items.append(Item(block: b, rect: r, cut: cutTop || cutBottom))
            }
        }
        var keep = [Bool](repeating: true, count: items.count)
        for i in items.indices where keep[i] {
            for j in items.indices where j > i && keep[j] {
                let a = items[i].rect, b = items[j].rect
                let inter = a.intersection(b).area
                let same = a.iou(b) > 0.3 || Double(inter) >= 0.6 * Double(min(a.area, b.area))
                guard same else { continue }
                // 온전한 쪽, 둘 다 같으면 큰 쪽
                let preferJ = (items[i].cut && !items[j].cut) || (items[i].cut == items[j].cut && b.area > a.area)
                if preferJ { keep[i] = false } else { keep[j] = false }
                if !keep[i] { break }
            }
        }
        return items.indices.filter { keep[$0] }.map { items[$0] }.sorted { $0.rect.y < $1.rect.y }.map(\.block)
    }
}
