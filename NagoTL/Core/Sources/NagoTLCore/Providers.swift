import Foundation

/// 번역 AI 제공자. Claude 말고도 Gemini(Google AI Studio)와 OpenAI 호환 API(OpenAI·OpenRouter·xAI·로컬 서버 등).
/// 전송은 앱이 URLSession으로 하고, 여기서는 요청 본문을 만들고 응답을 읽는다.
public enum Provider: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude, gemini, openai

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .openai: "OpenAI 호환"
        }
    }

    /// 상자를 0~1000 정규화 좌표로 받는가. Claude는 서버가 그림을 줄이는 규칙대로 크기를 맞춰 보내 픽셀 1:1로 받는다
    public var normalizedBoxes: Bool { self != .claude }

    /// 기본 모델(설정에서 바꿀 수 있다 — "모델 목록"으로 지금 쓸 수 있는 이름을 불러온다)
    public var defaultModel: String {
        switch self {
        case .claude: ClaudeAPI.Engine.standard.model
        case .gemini: "gemini-2.5-flash"
        case .openai: "gpt-5-mini"
        }
    }

    public var defaultPremiumModel: String {
        switch self {
        case .claude: ClaudeAPI.Engine.premium.model
        case .gemini: "gemini-2.5-pro"
        case .openai: "gpt-5"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .claude: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .openai: "https://api.openai.com/v1"
        }
    }
}

/// 한 번의 요청에 쓸 AI(제공자·모델·주소)
public struct AIRoute: Sendable, Equatable {
    public var provider: Provider
    public var model: String
    public var baseURL: String
    /// 무료 등급 키면 쓴 돈을 0으로 센다
    public var freeTier: Bool

    public init(provider: Provider, model: String, baseURL: String? = nil, freeTier: Bool = false) {
        self.provider = provider
        self.model = model
        let base = (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = base.isEmpty ? provider.defaultBaseURL : base
        self.freeTier = freeTier
    }

    /// 화면에 보일 이름("Gemini · gemini-2.5-flash")
    public var label: String { provider.label + " · " + model }

    /// 이 AI의 1백만 토큰당 값(모르는 모델은 비싼 쪽으로)
    public var price: ClaudeAPI.Price {
        switch provider {
        case .claude: ClaudeAPI.price(model: model)
        case .gemini: GeminiAPI.price(model: model)
        case .openai: OpenAIAPI.price(model: model)
        }
    }

    /// 한 쪽 어림 비용(달러) — 예산 확인·예상 금액 표시용(그림 2.5천 + 글 1천 입력, 생각 포함 출력 2천 토큰 안팎)
    public var estimatedPageCost: Double {
        if freeTier { return 0 }
        if provider == .claude {
            return model == ClaudeAPI.Engine.premium.model ? ClaudeAPI.Engine.premium.estimatedPageCost
                : ClaudeAPI.Engine.standard.estimatedPageCost
        }
        return price.cost(Usage(input: 3500, output: 2000))
    }
}

/// 답에서 꺼낸 것: 글(JSON), 쓴 토큰·비용, 실제로 답한 모델
public struct AIReply: Sendable, Equatable {
    public var text: String
    public var usage: Usage
    public var model: String
}

extension PageAnswer {
    /// 0~1000 정규화 상자를 이 크기의 픽셀 상자로(뒤집힌 좌표·범위 밖 값도 바로잡는다)
    public func denormalized(width: Int, height: Int) -> PageAnswer {
        var out = self
        out.blocks = blocks.map { b in
            var b = b
            func px(_ v: Int, _ size: Int) -> Int { Int((Double(min(max(v, 0), 1000)) / 1000 * Double(size)).rounded()) }
            let r = b.box.rect
            b.box = Box(x0: px(r.x, width), y0: px(r.y, height), x1: px(r.maxX, width), y1: px(r.maxY, height))
            return b
        }
        return out
    }
}

// MARK: - Gemini

/// Google Gemini API(AI Studio 키). generateContent, 구조화 출력(responseSchema)
public enum GeminiAPI {
    public static func url(base: String, model: String) -> URL? {
        let m = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        return URL(string: base.trimmingSuffix("/") + "/models/" + m + ":generateContent")
    }

    public static func modelsURL(base: String) -> URL? { URL(string: base.trimmingSuffix("/") + "/models?pageSize=200") }

    public static func headers(apiKey: String) -> [String: String] {
        ["x-goog-api-key": apiKey, "content-type": "application/json"]
    }

    /// 만화에 흔한 싸움·노출 장면 때문에 번역이 막히지 않게, 조정할 수 있는 필터는 끈다(구글이 늘 막는 내용은 그대로 막힌다)
    static let safety: [[String: String]] = [
        "HARM_CATEGORY_HARASSMENT", "HARM_CATEGORY_HATE_SPEECH", "HARM_CATEGORY_SEXUALLY_EXPLICIT",
        "HARM_CATEGORY_DANGEROUS_CONTENT",
    ].map { ["category": $0, "threshold": "BLOCK_NONE"] }

    /// 페이지 하나(그림 + 지시). full = 구조화 출력, basic = JSON만 쓰라고 지시(스키마가 막힐 때)
    public static func pageBody(imageJPEG: Data, context: TranslationContext, mode: ClaudeAPI.Mode = .full) -> Data {
        var text = PageRequest.userText(width: 0, height: 0, context: context, normalized: true)
        if mode == .basic { text += "\n\n" + PageRequest.jsonInstruction(PageRequest.schema) }
        let parts: [[String: Any]] = [
            ["inlineData": ["mimeType": "image/jpeg", "data": imageJPEG.base64EncodedString()]],
            ["text": text],
        ]
        return body(parts: parts, system: PageRequest.systemPromptNormalized, schema: PageRequest.schema, mode: mode)
    }

    /// 글만(다른 표현 받기)
    public static func textBody(prompt: String, schema: [String: Any], mode: ClaudeAPI.Mode = .full) -> Data {
        var text = prompt
        if mode == .basic { text += "\n\n" + PageRequest.jsonInstruction(schema) }
        return body(parts: [["text": text]], system: PageRequest.systemPromptNormalized, schema: schema, mode: mode)
    }

    static func body(parts: [[String: Any]], system: String, schema: [String: Any], mode: ClaudeAPI.Mode) -> Data {
        var generation: [String: Any] = ["responseMimeType": "application/json", "temperature": 0.3]
        if mode == .full { generation["responseSchema"] = geminiSchema(schema) }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": generation,
            "safetySettings": safety,
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// 속성 순서(읽고 → 옮기고 → 색): 만드는 순서가 답의 질에 영향을 준다
    static let order = ["source_language", "blocks", "kind", "box", "x0", "y0", "x1", "y1", "source", "translation", "note",
                        "vertical", "text_color", "outline_color", "page_summary", "new_terms", "korean", "alternatives"]

    /// JSON 스키마 → Gemini 스키마(형 이름은 대문자, additionalProperties 없음, 속성 순서 지정)
    static func geminiSchema(_ s: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        if let t = s["type"] as? String { out["type"] = t.uppercased() }
        if let e = s["enum"] {
            out["enum"] = e
            out["format"] = "enum"
        }
        if let props = s["properties"] as? [String: Any] {
            var p: [String: Any] = [:]
            for (k, v) in props {
                if let d = v as? [String: Any] { p[k] = geminiSchema(d) }
            }
            out["properties"] = p
            out["propertyOrdering"] = props.keys.sorted { a, b in
                (order.firstIndex(of: a) ?? order.count, a) < (order.firstIndex(of: b) ?? order.count, b)
            }
        }
        if let r = s["required"] { out["required"] = r }
        if let items = s["items"] as? [String: Any] { out["items"] = geminiSchema(items) }
        return out
    }

    /// 응답 읽기. 막혔으면 refusal, 잘렸으면 truncated
    public static func parse(_ data: Data, model: String, freeTier: Bool = false) throws -> AIReply {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TranslateError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let feedback = obj["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            throw TranslateError.refusal(reason)
        }
        guard let candidate = (obj["candidates"] as? [[String: Any]])?.first else {
            throw TranslateError.badResponse("답이 비었어요")
        }
        let finish = candidate["finishReason"] as? String ?? ""
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        // 생각(thought) 부분은 빼고 답 글만
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        let blocked = ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION", "IMAGE_SAFETY"]
        if blocked.contains(finish), text.isEmpty { throw TranslateError.refusal(finish) }
        if finish == "MAX_TOKENS" { throw TranslateError.truncated }
        let meta = obj["usageMetadata"] as? [String: Any] ?? [:]
        func int(_ k: String) -> Int { (meta[k] as? NSNumber)?.intValue ?? 0 }
        let cached = int("cachedContentTokenCount")
        var usage = Usage(input: max(0, int("promptTokenCount") - cached),
                          output: int("candidatesTokenCount") + int("thoughtsTokenCount"), cacheRead: cached)
        let served = (obj["modelVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? model
        usage.cost = freeTier ? 0 : price(model: served).cost(usage)
        guard !text.isEmpty else { throw TranslateError.badResponse("답이 비었어요(\(finish))") }
        return AIReply(text: text, usage: usage, model: served)
    }

    /// 모델 목록(generateContent를 쓸 수 있는 gemini 모델)
    public static func parseModels(_ data: Data) -> [String] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { m -> String? in
            guard let name = m["name"] as? String else { return nil }
            let methods = m["supportedGenerationMethods"] as? [String] ?? ["generateContent"]
            guard methods.contains("generateContent") else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
            return id.contains("gemini") && !id.contains("embedding") ? id : nil
        }.sorted()
    }

    /// 공식 가격(1백만 토큰당, 유료 등급). 모르는 모델은 Pro 값으로
    public static func price(model: String) -> ClaudeAPI.Price {
        let m = model.lowercased()
        func p(_ i: Double, _ o: Double) -> ClaudeAPI.Price {
            ClaudeAPI.Price(input: i, output: o, cacheRead: i / 4, cacheWrite: i)
        }
        if m.contains("flash-lite") { return m.contains("2.0") ? p(0.075, 0.30) : p(0.10, 0.40) }
        if m.contains("2.0-flash") { return p(0.10, 0.40) }
        if m.contains("flash") { return p(0.30, 2.50) }
        if m.contains("pro") { return p(1.25, 10) }
        return p(1.25, 10)
    }
}

// MARK: - OpenAI 호환

/// OpenAI Chat Completions 모양의 API(OpenAI, OpenRouter, xAI, 로컬 서버 등 — 주소만 바꾸면 된다)
public enum OpenAIAPI {
    public static func url(base: String) -> URL? { URL(string: base.trimmingSuffix("/") + "/chat/completions") }

    public static func modelsURL(base: String) -> URL? { URL(string: base.trimmingSuffix("/") + "/models") }

    public static func headers(apiKey: String) -> [String: String] {
        ["authorization": "Bearer " + apiKey, "content-type": "application/json"]
    }

    static func isOpenAI(_ base: String) -> Bool { base.contains("api.openai.com") }

    /// 생각하는 모델(o 시리즈·gpt-5)은 생각을 줄여 빠르고 싸게
    static func isReasoning(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("gpt-5") || (m.hasPrefix("o") && m.dropFirst().first?.isNumber == true)
    }

    public static func pageBody(imageJPEG: Data, model: String, context: TranslationContext, baseURL: String,
                                mode: ClaudeAPI.Mode = .full) -> Data {
        var text = PageRequest.userText(width: 0, height: 0, context: context, normalized: true)
        if mode == .basic { text += "\n\n" + PageRequest.jsonInstruction(PageRequest.schema) }
        var image: [String: Any] = ["url": "data:image/jpeg;base64," + imageJPEG.base64EncodedString()]
        if mode == .full { image["detail"] = "high" }
        let content: [[String: Any]] = [["type": "text", "text": text], ["type": "image_url", "image_url": image]]
        return body(model: model, system: PageRequest.systemPromptNormalized, content: content, schema: PageRequest.schema,
                    name: "manga_page", baseURL: baseURL, mode: mode)
    }

    public static func textBody(model: String, prompt: String, schema: [String: Any], baseURL: String,
                                mode: ClaudeAPI.Mode = .full) -> Data {
        var text = prompt
        if mode == .basic { text += "\n\n" + PageRequest.jsonInstruction(schema) }
        return body(model: model, system: PageRequest.systemPromptNormalized, content: text, schema: schema,
                    name: "alternatives", baseURL: baseURL, mode: mode)
    }

    static func body(model: String, system: String, content: Any, schema: [String: Any], name: String, baseURL: String,
                     mode: ClaudeAPI.Mode) -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": content]],
        ]
        if mode == .full {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": name, "strict": true, "schema": schema]]
            if isOpenAI(baseURL) && isReasoning(model) { body["reasoning_effort"] = "low" }
        }
        // OpenRouter는 실제로 든 돈을 알려 준다
        if baseURL.contains("openrouter.ai") { body["usage"] = ["include": true] }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    public static func parse(_ data: Data, model: String, freeTier: Bool = false) throws -> AIReply {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TranslateError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let err = obj["error"] as? [String: Any] {
            throw TranslateError.server(0, err["message"] as? String ?? "오류")
        }
        guard let choice = (obj["choices"] as? [[String: Any]])?.first else { throw TranslateError.badResponse("답이 비었어요") }
        let message = choice["message"] as? [String: Any] ?? [:]
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw TranslateError.refusal(refusal) }
        let finish = choice["finish_reason"] as? String ?? ""
        if finish == "content_filter" { throw TranslateError.refusal("content_filter") }
        var text = message["content"] as? String ?? ""
        if text.isEmpty, let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        }
        if finish == "length" { throw TranslateError.truncated }
        let u = obj["usage"] as? [String: Any] ?? [:]
        func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
        let cached = int((u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"])
        var usage = Usage(input: max(0, int(u["prompt_tokens"]) - cached), output: int(u["completion_tokens"]),
                          cacheRead: cached)
        let served = (obj["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? model
        if freeTier {
            usage.cost = 0
        } else if let c = (u["cost"] as? NSNumber)?.doubleValue {
            usage.cost = c
        } else {
            usage.cost = price(model: served).cost(usage)
        }
        guard !text.isEmpty else { throw TranslateError.badResponse("답이 비었어요(\(finish))") }
        return AIReply(text: text, usage: usage, model: served)
    }

    /// 모델 목록(OpenRouter면 그림을 읽는 모델만)
    public static func parseModels(_ data: Data) -> [String] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { m -> String? in
            guard let id = m["id"] as? String else { return nil }
            if let arch = m["architecture"] as? [String: Any], let input = arch["input_modalities"] as? [String],
               !input.contains("image") { return nil }
            let lower = id.lowercased()
            let skip = ["embedding", "whisper", "tts", "dall-e", "moderation", "audio", "realtime", "transcribe", "image-"]
            return skip.contains(where: { lower.contains($0) }) ? nil : id
        }.sorted()
    }

    /// 공식 가격(1백만 토큰당). "회사/모델" 꼴(OpenRouter)은 뒤만 본다. 모르는 모델은 비싼 쪽으로
    public static func price(model: String) -> ClaudeAPI.Price {
        var m = model.lowercased()
        if let slash = m.lastIndex(of: "/") { m = String(m[m.index(after: slash)...]) }
        func p(_ i: Double, _ o: Double) -> ClaudeAPI.Price {
            ClaudeAPI.Price(input: i, output: o, cacheRead: i / 10, cacheWrite: i)
        }
        let table: [(String, ClaudeAPI.Price)] = [
            ("gpt-5-nano", p(0.05, 0.40)), ("gpt-5-mini", p(0.25, 2.00)), ("gpt-5", p(1.25, 10)),
            ("gpt-4.1-nano", p(0.10, 0.40)), ("gpt-4.1-mini", p(0.40, 1.60)), ("gpt-4.1", p(2, 8)),
            ("gpt-4o-mini", p(0.15, 0.60)), ("gpt-4o", p(2.50, 10)), ("o4-mini", p(1.10, 4.40)), ("o3", p(2, 8)),
            ("gemini-2.5-flash-lite", p(0.10, 0.40)), ("gemini-2.5-flash", p(0.30, 2.50)), ("gemini-2.5-pro", p(1.25, 10)),
        ]
        for (prefix, price) in table where m.hasPrefix(prefix) { return price }
        if m.hasSuffix(":free") { return p(0, 0) }
        return p(2.50, 10)
    }
}

extension String {
    func trimmingSuffix(_ s: String) -> String {
        var t = self
        while t.hasSuffix(s) { t.removeLast(s.count) }
        return t
    }
}
