import Foundation
import XCTest
@testable import NagoTLCore

/// Gemini·OpenAI 호환 요청 본문과 응답 읽기
final class ProviderTests: XCTestCase {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
    let context = TranslationContext(glossary: [GlossaryEntry(source: "高橋", korean: "다카하시")],
                                     previousSummaries: ["앞 쪽 요약"], bookNote: "")

    func json(_ d: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    /// 스키마 어디에도 additionalProperties가 없어야 한다(Gemini는 모르는 칸이면 400)
    func assertNoAdditionalProperties(_ v: Any, file: StaticString = #filePath, line: UInt = #line) {
        if let d = v as? [String: Any] {
            XCTAssertNil(d["additionalProperties"], file: file, line: line)
            for (_, x) in d { assertNoAdditionalProperties(x, file: file, line: line) }
        } else if let a = v as? [Any] {
            for x in a { assertNoAdditionalProperties(x, file: file, line: line) }
        }
    }

    func testPromptsDifferOnlyInBoxRule() {
        XCTAssertTrue(PageRequest.systemPrompt.contains(
            "in this image's pixel coordinates (x0,y0 = top-left, x1,y1 = bottom-right). Hug the letters"))
        XCTAssertTrue(PageRequest.systemPromptNormalized.contains("as integers from 0 to 1000"))
        XCTAssertFalse(PageRequest.systemPromptNormalized.contains("pixel coordinates"))
        for p in [PageRequest.systemPrompt, PageRequest.systemPromptNormalized] {
            XCTAssertTrue(p.hasPrefix("You are NAGO TL"))
            XCTAssertTrue(p.contains("# Translation guidelines"))
            XCTAssertTrue(p.contains("- outline_color:"))
            XCTAssertFalse(p.contains("\\("))
        }
        XCTAssertTrue(PageRequest.userText(width: 0, height: 0, context: context, normalized: true)
            .hasPrefix("Give every box as integers from 0 to 1000"))
        XCTAssertTrue(PageRequest.userText(width: 800, height: 1200, context: context)
            .hasPrefix("The image is 800×1200 pixels"))
    }

    func testGeminiPageBody() throws {
        let b = try json(GeminiAPI.pageBody(imageJPEG: jpeg, context: context))
        let system = try XCTUnwrap(((b["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(system, PageRequest.systemPromptNormalized)
        let parts = try XCTUnwrap(((b["contents"] as? [[String: Any]])?.first)?["parts"] as? [[String: Any]])
        let inline = try XCTUnwrap(parts[0]["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(inline["data"] as? String, jpeg.base64EncodedString())
        let text = try XCTUnwrap(parts[1]["text"] as? String)
        XCTAssertTrue(text.contains("0 to 1000"))
        XCTAssertTrue(text.contains("高橋 → 다카하시"))
        let gen = try XCTUnwrap(b["generationConfig"] as? [String: Any])
        XCTAssertEqual(gen["responseMimeType"] as? String, "application/json")
        let schema = try XCTUnwrap(gen["responseSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "OBJECT")
        assertNoAdditionalProperties(schema)
        let block = try XCTUnwrap(((schema["properties"] as? [String: Any])?["blocks"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(block["propertyOrdering"] as? [String],
                       ["kind", "box", "source", "translation", "note", "vertical", "text_color", "outline_color"])
        let kind = try XCTUnwrap((block["properties"] as? [String: Any])?["kind"] as? [String: Any])
        XCTAssertEqual(kind["type"] as? String, "STRING")
        XCTAssertEqual(kind["format"] as? String, "enum")
        XCTAssertEqual(kind["enum"] as? [String], BlockKind.allCases.map(\.rawValue))
        XCTAssertEqual((b["safetySettings"] as? [[String: String]])?.count, 4)

        // basic: 스키마 없이 JSON만 쓰라고
        let basic = try json(GeminiAPI.pageBody(imageJPEG: jpeg, context: context, mode: .basic))
        XCTAssertNil((basic["generationConfig"] as? [String: Any])?["responseSchema"])
        let basicText = try XCTUnwrap((((basic["contents"] as? [[String: Any]])?.first)?["parts"] as? [[String: Any]])?[1]["text"] as? String)
        XCTAssertTrue(basicText.contains("Reply with only one JSON object"))

        XCTAssertEqual(GeminiAPI.url(base: "https://generativelanguage.googleapis.com/v1beta/", model: "models/gemini-2.5-flash")?
            .absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        XCTAssertEqual(GeminiAPI.headers(apiKey: "k")["x-goog-api-key"], "k")
    }

    func testGeminiParse() throws {
        let ok = #"""
        {"candidates":[{"content":{"role":"model","parts":[{"text":"생각 중","thought":true},{"text":"{\"source_language\":\"ja\",\"blocks\":[],\"page_summary\":\"\",\"new_terms\":[]}"}]},"finishReason":"STOP"}],
         "usageMetadata":{"promptTokenCount":3000,"candidatesTokenCount":800,"thoughtsTokenCount":200,"cachedContentTokenCount":1000},
         "modelVersion":"gemini-2.5-flash"}
        """#
        let r = try GeminiAPI.parse(Data(ok.utf8), model: "gemini-2.5-flash")
        XCTAssertFalse(r.text.contains("생각 중"))
        XCTAssertEqual(try PageRequest.decodeJSON(PageAnswer.self, from: r.text).source_language, "ja")
        XCTAssertEqual(r.usage.input, 2000)
        XCTAssertEqual(r.usage.cacheRead, 1000)
        XCTAssertEqual(r.usage.output, 1000)
        XCTAssertEqual(r.usage.cost, (2000 * 0.30 + 1000 * 2.50 + 1000 * 0.075) / 1_000_000, accuracy: 1e-12)
        XCTAssertEqual(r.model, "gemini-2.5-flash")
        XCTAssertEqual(try GeminiAPI.parse(Data(ok.utf8), model: "gemini-2.5-flash", freeTier: true).usage.cost, 0)

        let blocked = #"{"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}}"#
        XCTAssertThrowsError(try GeminiAPI.parse(Data(blocked.utf8), model: "m")) {
            XCTAssertEqual($0 as? TranslateError, .refusal("PROHIBITED_CONTENT"))
        }
        let safety = #"{"candidates":[{"content":{"parts":[]},"finishReason":"SAFETY"}]}"#
        XCTAssertThrowsError(try GeminiAPI.parse(Data(safety.utf8), model: "m")) {
            XCTAssertEqual($0 as? TranslateError, .refusal("SAFETY"))
        }
        let cut = #"{"candidates":[{"content":{"parts":[{"text":"{\"a\":"}]},"finishReason":"MAX_TOKENS"}]}"#
        XCTAssertThrowsError(try GeminiAPI.parse(Data(cut.utf8), model: "m")) { XCTAssertEqual($0 as? TranslateError, .truncated) }
        XCTAssertThrowsError(try GeminiAPI.parse(Data("nope".utf8), model: "m"))
    }

    func testOpenAIPageBody() throws {
        let b = try json(OpenAIAPI.pageBody(imageJPEG: jpeg, model: "gpt-5-mini", context: context,
                                            baseURL: "https://api.openai.com/v1"))
        XCTAssertEqual(b["model"] as? String, "gpt-5-mini")
        let messages = try XCTUnwrap(b["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, PageRequest.systemPromptNormalized)
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        let image = try XCTUnwrap(content[1]["image_url"] as? [String: Any])
        XCTAssertEqual(image["url"] as? String, "data:image/jpeg;base64," + jpeg.base64EncodedString())
        XCTAssertEqual(image["detail"] as? String, "high")
        let format = try XCTUnwrap(b["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["strict"] as? Bool, true)
        XCTAssertEqual(b["reasoning_effort"] as? String, "low")
        XCTAssertNil(b["usage"])

        // 생각 안 하는 모델·다른 주소엔 reasoning_effort를 안 보낸다. OpenRouter는 쓴 돈을 알려 달라고
        let other = try json(OpenAIAPI.pageBody(imageJPEG: jpeg, model: "openai/gpt-5-mini", context: context,
                                                baseURL: "https://openrouter.ai/api/v1"))
        XCTAssertNil(other["reasoning_effort"])
        XCTAssertEqual((other["usage"] as? [String: Any])?["include"] as? Bool, true)
        let classic = try json(OpenAIAPI.pageBody(imageJPEG: jpeg, model: "gpt-4.1-mini", context: context,
                                                  baseURL: "https://api.openai.com/v1"))
        XCTAssertNil(classic["reasoning_effort"])
        // basic: 구조화 출력·detail 없이
        let basic = try json(OpenAIAPI.pageBody(imageJPEG: jpeg, model: "local", context: context,
                                                baseURL: "http://192.168.0.2:1234/v1", mode: .basic))
        XCTAssertNil(basic["response_format"])
        let basicContent = try XCTUnwrap((basic["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]])
        XCTAssertNil((basicContent[1]["image_url"] as? [String: Any])?["detail"])
        XCTAssertTrue((basicContent[0]["text"] as? String ?? "").contains("Reply with only one JSON object"))
        XCTAssertEqual(OpenAIAPI.url(base: "https://api.x.ai/v1/")?.absoluteString, "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(OpenAIAPI.headers(apiKey: "sk")["authorization"], "Bearer sk")
    }

    func testOpenAIParse() throws {
        let ok = #"""
        {"model":"gpt-5-mini-2025-08-07","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"```json\n{\"alternatives\":[\"가\",\"나\"]}\n```","refusal":null}}],
         "usage":{"prompt_tokens":1200,"completion_tokens":300,"prompt_tokens_details":{"cached_tokens":200}}}
        """#
        struct Alt: Decodable { var alternatives: [String] }
        let r = try OpenAIAPI.parse(Data(ok.utf8), model: "gpt-5-mini")
        XCTAssertEqual(try PageRequest.decodeJSON(Alt.self, from: r.text).alternatives, ["가", "나"])
        XCTAssertEqual(r.usage.input, 1000)
        XCTAssertEqual(r.usage.cacheRead, 200)
        XCTAssertEqual(r.usage.cost, (1000 * 0.25 + 300 * 2.0 + 200 * 0.025) / 1_000_000, accuracy: 1e-12)
        XCTAssertEqual(r.model, "gpt-5-mini-2025-08-07")

        // OpenRouter가 알려 준 실제 비용을 쓴다
        let routed = #"{"model":"qwen/qwen2.5-vl-72b-instruct","choices":[{"finish_reason":"stop","message":{"content":"{}"}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.0123}}"#
        XCTAssertEqual(try OpenAIAPI.parse(Data(routed.utf8), model: "x").usage.cost, 0.0123, accuracy: 1e-12)

        let refused = #"{"choices":[{"finish_reason":"stop","message":{"content":null,"refusal":"I can't help with that."}}]}"#
        XCTAssertThrowsError(try OpenAIAPI.parse(Data(refused.utf8), model: "m")) {
            XCTAssertEqual($0 as? TranslateError, .refusal("I can't help with that."))
        }
        let filtered = #"{"choices":[{"finish_reason":"content_filter","message":{"content":""}}]}"#
        XCTAssertThrowsError(try OpenAIAPI.parse(Data(filtered.utf8), model: "m")) {
            XCTAssertEqual($0 as? TranslateError, .refusal("content_filter"))
        }
        let cut = #"{"choices":[{"finish_reason":"length","message":{"content":"{\"a\""}}]}"#
        XCTAssertThrowsError(try OpenAIAPI.parse(Data(cut.utf8), model: "m")) { XCTAssertEqual($0 as? TranslateError, .truncated) }
    }

    func testModelLists() {
        let gemini = #"""
        {"models":[{"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent","countTokens"]},
                   {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]},
                   {"name":"models/gemini-2.5-pro","supportedGenerationMethods":["generateContent"]},
                   {"name":"models/gemini-embedding-001","supportedGenerationMethods":["embedContent"]}]}
        """#
        XCTAssertEqual(GeminiAPI.parseModels(Data(gemini.utf8)), ["gemini-2.5-flash", "gemini-2.5-pro"])
        let openai = #"""
        {"data":[{"id":"gpt-5-mini"},{"id":"text-embedding-3-small"},{"id":"gpt-4o"},{"id":"whisper-1"},{"id":"dall-e-3"},
                 {"id":"meta/llama-text","architecture":{"input_modalities":["text"]}},
                 {"id":"qwen/qwen2.5-vl-72b-instruct","architecture":{"input_modalities":["text","image"]}}]}
        """#
        XCTAssertEqual(OpenAIAPI.parseModels(Data(openai.utf8)), ["gpt-4o", "gpt-5-mini", "qwen/qwen2.5-vl-72b-instruct"])
        XCTAssertEqual(GeminiAPI.parseModels(Data("x".utf8)), [])
    }

    func testPricesAndRoutes() {
        XCTAssertEqual(GeminiAPI.price(model: "gemini-2.5-flash").output, 2.5)
        XCTAssertEqual(GeminiAPI.price(model: "gemini-2.5-flash-lite").input, 0.10)
        XCTAssertEqual(GeminiAPI.price(model: "gemini-2.5-pro").input, 1.25)
        XCTAssertEqual(OpenAIAPI.price(model: "gpt-5-mini-2025-08-07").input, 0.25)
        XCTAssertEqual(OpenAIAPI.price(model: "openai/gpt-4o-mini").input, 0.15)
        XCTAssertEqual(OpenAIAPI.price(model: "google/gemini-2.5-flash").output, 2.5)
        XCTAssertEqual(OpenAIAPI.price(model: "some/model:free").input, 0)
        XCTAssertEqual(OpenAIAPI.price(model: "mystery-model").input, 2.5)

        let g = AIRoute(provider: .gemini, model: "gemini-2.5-flash")
        XCTAssertEqual(g.baseURL, Provider.gemini.defaultBaseURL)
        XCTAssertEqual(g.label, "Gemini · gemini-2.5-flash")
        XCTAssertEqual(g.estimatedPageCost, (3500 * 0.30 + 2000 * 2.5) / 1_000_000, accuracy: 1e-12)
        XCTAssertEqual(AIRoute(provider: .gemini, model: "gemini-2.5-flash", freeTier: true).estimatedPageCost, 0)
        XCTAssertEqual(AIRoute(provider: .claude, model: ClaudeAPI.Engine.standard.model).estimatedPageCost,
                       ClaudeAPI.Engine.standard.estimatedPageCost)
        XCTAssertEqual(AIRoute(provider: .claude, model: ClaudeAPI.Engine.premium.model).estimatedPageCost,
                       ClaudeAPI.Engine.premium.estimatedPageCost)
        XCTAssertEqual(AIRoute(provider: .openai, model: "m", baseURL: "  ").baseURL, Provider.openai.defaultBaseURL)
        XCTAssertTrue(Provider.gemini.normalizedBoxes)
        XCTAssertFalse(Provider.claude.normalizedBoxes)
        XCTAssertEqual(TranslateError.from(status: 400, body: Data(#"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}"#.utf8), retryAfter: nil), .badKey)
    }

    func testDenormalizedBoxes() {
        let answer = PageAnswer(source_language: "ja", blocks: [
            .init(kind: "speech", box: .init(x0: 100, y0: 200, x1: 300, y1: 500), source: "あ", translation: "아"),
            // 뒤집히고 범위를 넘은 상자
            .init(kind: "sfx", box: .init(x0: 1200, y0: 900, x1: 800, y1: -50), source: "ド", translation: "두"),
        ], page_summary: "", new_terms: [])
        let d = answer.denormalized(width: 800, height: 1200)
        XCTAssertEqual(d.blocks[0].box, .init(x0: 80, y0: 240, x1: 240, y1: 600))
        XCTAssertEqual(d.blocks[1].box, .init(x0: 640, y0: 0, x1: 800, y1: 1080))
        XCTAssertEqual(d.blocks[0].translation, "아")
    }
}
