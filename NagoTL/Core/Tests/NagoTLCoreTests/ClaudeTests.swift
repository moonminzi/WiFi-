import Foundation
import XCTest
@testable import NagoTLCore

final class ClaudeTests: XCTestCase {
    func testRequestBodyShape() throws {
        let ctx = TranslationContext(glossary: [GlossaryEntry(source: "司", korean: "츠카사", note: "주인공")],
                                     previousSummaries: ["츠카사가 학교에 간다."], bookNote: "학원물",
                                     segment: (1, 3))
        let body = PageRequest.body(imageJPEG: Data([0xFF, 0xD8, 0xFF]), width: 1200, height: 1700, context: ctx)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(obj["stream"] as? Bool, true)
        XCTAssertEqual(obj["fallbacks"] as? String, "default")
        XCTAssertNil(obj["thinking"], "Opus 5.5는 thinking을 빼야 한다")
        XCTAssertNil(obj["temperature"])
        let oc = try XCTUnwrap(obj["output_config"] as? [String: Any])
        XCTAssertEqual(oc["effort"] as? String, "medium")
        let format = try XCTUnwrap(oc["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        try checkStrict(format["schema"])
        let system = try XCTUnwrap(obj["system"] as? [[String: Any]])
        XCTAssertNotNil(system[0]["cache_control"])
        let messages = try XCTUnwrap(obj["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "image")
        let source = try XCTUnwrap(content[0]["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, "/9j/")
        let text = try XCTUnwrap(content[1]["text"] as? String)
        XCTAssertTrue(text.contains("1200×1700"))
        XCTAssertTrue(text.contains("司 → 츠카사 (주인공)"))
        XCTAssertTrue(text.contains("part 2 of 3"))
        XCTAssertTrue(text.contains("학원물"))
        XCTAssertTrue(text.contains("츠카사가 학교에 간다."))

        let headers = ClaudeAPI.headers(apiKey: "k")
        XCTAssertEqual(headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        XCTAssertEqual(headers["anthropic-version"], "2023-06-01")

        let alt = try XCTUnwrap(JSONSerialization.jsonObject(with: PageRequest.alternativesBody(
            source: "うるさい", current: "시끄러워", kind: .speech, context: ctx, pageSummary: "")) as? [String: Any])
        let altFormat = try XCTUnwrap((alt["output_config"] as? [String: Any])?["format"] as? [String: Any])
        try checkStrict(altFormat["schema"])
    }

    /// 구조화 출력 규칙: 모든 객체에 required(속성 전부) + additionalProperties:false, 최소·최대 제약 없음
    func checkStrict(_ node: Any?) throws {
        guard let o = node as? [String: Any] else { return }
        for banned in ["minItems", "maxItems", "minimum", "maximum", "minLength", "maxLength"] {
            XCTAssertNil(o[banned], banned)
        }
        if o["type"] as? String == "object" {
            XCTAssertEqual(o["additionalProperties"] as? Bool, false)
            let props = try XCTUnwrap(o["properties"] as? [String: Any])
            XCTAssertEqual(Set(o["required"] as? [String] ?? []), Set(props.keys))
            for v in props.values { try checkStrict(v) }
        }
        if let items = o["items"] { try checkStrict(items) }
    }

    static let answerJSON = """
    {"source_language":"ja","blocks":[{"kind":"speech","box":{"x0":10,"y0":20,"x1":110,"y1":220},\
    "source":"おい、待てよ！","translation":"야, 기다려!","note":""},{"kind":"sfx","box":{"x0":300,"y0":40,"x1":420,\
    "y1":90},"source":"ドドド","translation":"두두두","note":""}],"page_summary":"츠카사가 누군가를 부른다.",\
    "new_terms":[{"source":"司","korean":"츠카사","note":"주인공"}]}
    """

    func sse(_ events: [[String: Any]]) -> [String] {
        events.flatMap { e -> [String] in
            let data = try! JSONSerialization.data(withJSONObject: e)
            return ["event: \(e["type"] as! String)", "data: " + String(decoding: data, as: UTF8.self), ""]
        }
    }

    func testStreamAccumulatesTextAfterThinking() throws {
        let json = Self.answerJSON
        let cut = json.index(json.startIndex, offsetBy: 57)
        let lines = sse([
            ["type": "message_start", "message": ["model": "claude-opus-5-5",
                                                  "usage": ["input_tokens": 3000, "output_tokens": 1,
                                                            "cache_read_input_tokens": 1500]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "x"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "ping"],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": String(json[..<cut])]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": String(json[cut...])]],
            ["type": "content_block_stop", "index": 1],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 2500]],
            ["type": "message_stop"],
        ])
        var acc = StreamAccumulator()
        for l in lines { acc.feed(line: l) }
        XCTAssertTrue(acc.finished)
        let answer = try acc.decode(PageAnswer.self)
        XCTAssertEqual(answer.blocks.count, 2)
        XCTAssertEqual(answer.blocks[0].box.rect, IRect(x: 10, y: 20, w: 100, h: 200))
        XCTAssertEqual(answer.blocks[1].blockKind, .sfx)
        XCTAssertEqual(answer.new_terms, [GlossaryEntry(source: "司", korean: "츠카사", note: "주인공")])
        XCTAssertEqual(acc.usage, Usage(input: 3000, output: 2500, cacheRead: 1500, cacheWrite: 0))
        XCTAssertEqual(acc.usage.dollars, (3000 * 4.0 + 2500 * 20.0 + 1500 * 0.2) / 1_000_000, accuracy: 1e-9)
    }

    func testRefusalAndTruncation() {
        var acc = StreamAccumulator()
        for l in sse([["type": "message_start", "message": ["model": "claude-opus-5-5", "usage": ["input_tokens": 10]]],
                      ["type": "message_delta", "delta": ["stop_reason": "refusal", "stop_details": ["category": "bio"]]],
                      ["type": "message_stop"]]) {
            acc.feed(line: l)
        }
        XCTAssertThrowsError(try acc.decode(PageAnswer.self)) { XCTAssertEqual($0 as? TranslateError, .refusal("bio")) }

        var cut = StreamAccumulator()
        for l in sse([["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                      ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "{\"blocks\":["]],
                      ["type": "message_delta", "delta": ["stop_reason": "max_tokens"]]]) {
            cut.feed(line: l)
        }
        XCTAssertThrowsError(try cut.decode(PageAnswer.self)) { XCTAssertEqual($0 as? TranslateError, .truncated) }

        var dropped = StreamAccumulator()
        dropped.feed(line: "event: content_block_start")
        XCTAssertThrowsError(try dropped.decode(PageAnswer.self))

        var overloaded = StreamAccumulator()
        for l in sse([["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]]]) {
            overloaded.feed(line: l)
        }
        XCTAssertEqual(overloaded.error, .overloaded)
        XCTAssertTrue(overloaded.error!.retryable)
    }

    /// 서버가 쓰다 만 글을 다른 모델이 이어 쓰거나, 처음부터 다시 쓰는 두 경우 모두 읽는다
    func testFallbackSegments() throws {
        let json = Self.answerJSON
        let cut = json.index(json.startIndex, offsetBy: 80)
        for second in [String(json[cut...]), json] {
            let first = second == json ? "{\"source_lang" : String(json[..<cut])
            var acc = StreamAccumulator()
            for l in sse([
                ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": first]],
                ["type": "content_block_stop", "index": 0],
                ["type": "content_block_start", "index": 1,
                 "content_block": ["type": "fallback", "from": ["model": "claude-opus-5-5"], "to": ["model": "claude-opus-5"]]],
                ["type": "content_block_stop", "index": 1],
                ["type": "content_block_start", "index": 2, "content_block": ["type": "text", "text": ""]],
                ["type": "content_block_delta", "index": 2, "delta": ["type": "text_delta", "text": second]],
                ["type": "message_delta", "delta": ["stop_reason": "end_turn"]],
            ]) {
                acc.feed(line: l)
            }
            XCTAssertEqual(try acc.decode(PageAnswer.self).blocks.count, 2)
        }
    }

    func testErrorMapping() {
        func body(_ type: String, _ msg: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": type, "message": msg]])
        }
        XCTAssertEqual(TranslateError.from(status: 401, body: body("authentication_error", "x"), retryAfter: nil), .badKey)
        XCTAssertEqual(TranslateError.from(status: 429, body: body("rate_limit_error", "x"), retryAfter: "12"),
                       .rateLimited(retryAfter: 12))
        XCTAssertEqual(TranslateError.from(status: 529, body: body("overloaded_error", "x"), retryAfter: nil), .overloaded)
        XCTAssertEqual(TranslateError.from(status: 400, body: body("invalid_request_error", "Your credit balance is too low"),
                                           retryAfter: nil), .noCredit("Your credit balance is too low"))
        XCTAssertEqual(TranslateError.from(status: 400, body: body("invalid_request_error", "bad image"), retryAfter: nil),
                       .invalidRequest("bad image"))
        XCTAssertTrue(TranslateError.from(status: 500, body: Data(), retryAfter: nil).retryable)
        XCTAssertFalse(TranslateError.badKey.retryable)
    }

    func testFittedSize() {
        XCTAssertEqual(ClaudeAPI.fittedSize(width: 1200, height: 1700).0, 1200)
        let (w, h) = ClaudeAPI.fittedSize(width: 4032, height: 3024)
        XCTAssertLessThanOrEqual(max(w, h), 2576)
        XCTAssertLessThanOrEqual(w * h, 3_750_000)
        XCTAssertEqual(Double(w) / Double(h), 4032.0 / 3024.0, accuracy: 0.01)
    }

    func testTilesCoverTallStrip() {
        XCTAssertEqual(Tiler.tiles(width: 1200, height: 1700).count, 1)
        let tiles = Tiler.tiles(width: 800, height: 9000)
        XCTAssertGreaterThan(tiles.count, 5)
        XCTAssertEqual(tiles.first?.y, 0)
        XCTAssertEqual(tiles.last?.maxY, 9000)
        for (a, b) in zip(tiles, tiles.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.maxY - b.y, 800 * 16 / 10 / 4 - 1, "겹침")
            XCTAssertLessThan(b.y, a.maxY)
        }
    }

    func testMergeDropsCutAndDuplicates() {
        func block(_ y0: Int, _ y1: Int, _ t: String) -> PageAnswer.Block {
            PageAnswer.Block(kind: "speech", box: .init(x0: 100, y0: y0, x1: 300, y1: y1), source: t, translation: t)
        }
        let t0 = IRect(x: 0, y: 0, w: 800, h: 1280), t1 = IRect(x: 0, y: 960, w: 800, h: 1280)
        // 같은 말풍선이 두 조각에 다 보인 경우 하나만, 아래 끝에 잘린 건 버리고 다음 조각의 온전한 것을 쓴다
        let merged = Tiler.merge([
            (t0, [block(100, 300, "a"), block(1000, 1100, "b"), block(1150, 1280, "c-cut")]),
            (t1, [block(1002, 1101, "b"), block(1150, 1400, "c"), block(1900, 2000, "d")]),
        ], height: 2240)
        XCTAssertEqual(merged.map(\.source), ["a", "b", "c", "d"])
    }

    func testGlossaryMergeKeepsUserEdits() {
        let mine = [GlossaryEntry(source: "司", korean: "츠카사(내가 고침)")]
        let merged = GlossaryEntry.merge(mine, adding: [GlossaryEntry(source: "司 ", korean: "쓰카사"),
                                                        GlossaryEntry(source: "東京", korean: "도쿄"),
                                                        GlossaryEntry(source: "", korean: "x")])
        XCTAssertEqual(merged.map(\.korean), ["츠카사(내가 고침)", "도쿄"])
    }
}
