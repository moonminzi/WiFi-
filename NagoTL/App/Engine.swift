import Foundation
import NagoTLCore
import UIKit

/// Claude API 전송(스트리밍)
enum ClaudeClient {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        // 생각하는 동안에도 ping이 오므로 바이트 사이 대기는 넉넉히
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 1800
        return URLSession(configuration: c)
    }()

    static func request(_ url: URL, apiKey: String, mode: ClaudeAPI.Mode = .full,
                        engine: ClaudeAPI.Engine = .standard) -> URLRequest {
        var req = URLRequest(url: url)
        for (k, v) in ClaudeAPI.headers(apiKey: apiKey, mode: mode, engine: engine) { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// 요청 하나를 스트리밍으로 받는다. progress는 0.3초마다 부른다.
    static func stream(_ body: Data, apiKey: String, mode: ClaudeAPI.Mode = .full, engine: ClaudeAPI.Engine = .standard,
                       progress: @escaping @Sendable (StreamAccumulator) -> Void) async throws -> StreamAccumulator {
        var req = request(ClaudeAPI.endpoint, apiKey: apiKey, mode: mode, engine: engine)
        req.httpMethod = "POST"
        req.httpBody = body
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            throw map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw TranslateError.network("응답이 없어요") }
        if http.statusCode != 200 {
            var data = Data()
            do {
                for try await b in bytes {
                    data.append(b)
                    if data.count > 65536 { break }
                }
            } catch {}
            throw TranslateError.from(status: http.statusCode, body: data,
                                      retryAfter: http.value(forHTTPHeaderField: "retry-after"))
        }
        var acc = StreamAccumulator()
        var last = Date.distantPast
        do {
            for try await line in bytes.lines {
                acc.feed(line: line)
                if acc.error != nil { break }
                if Date().timeIntervalSince(last) > 0.3 {
                    last = Date()
                    progress(acc)
                }
            }
        } catch {
            throw map(error)
        }
        progress(acc)
        return acc
    }

    static func map(_ error: Error) -> TranslateError {
        if let t = error as? TranslateError { return t }
        if error is CancellationError { return .cancelled }
        if let u = error as? URLError {
            if u.code == .cancelled { return .cancelled }
            return .network(u.localizedDescription)
        }
        return .network(error.localizedDescription)
    }

    /// 다시 하면 될 오류(붐빔·한도·끊김)는 기다렸다가 몇 번 더
    static func withRetries<T>(_ attempts: Int = 4, _ op: (Int) async throws -> T) async throws -> T {
        var delay = 3.0
        var attempt = 0
        while true {
            do {
                return try await op(attempt)
            } catch {
                let e = map(error)
                attempt += 1
                guard e.retryable, attempt < attempts else { throw e }
                var wait = delay
                if case let .rateLimited(ra?) = e { wait = max(wait, ra) }
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                delay *= 2.5
            }
        }
    }

    /// 키 확인(모델 목록 읽기 — 돈이 들지 않는다)
    static func checkKey(_ key: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(ClaudeAPI.version, forHTTPHeaderField: "anthropic-version")
        req.httpMethod = "GET"
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return "응답이 없어요" }
            if http.statusCode == 200 { return nil }
            return TranslateError.from(status: http.statusCode, body: data, retryAfter: nil).localizedDescription
        } catch {
            return map(error).localizedDescription
        }
    }

    /// 말풍선 하나의 다른 표현들
    static func alternatives(source: String, current: String, kind: BlockKind, context: TranslationContext,
                             summary: String, apiKey: String) async throws -> ([String], Usage) {
        struct Answer: Decodable { var alternatives: [String] }
        var mode = ClaudeAPI.Mode.full
        let acc = try await ClaudeClient.withRetries(3) { _ in
            let body = PageRequest.alternativesBody(source: source, current: current, kind: kind, context: context,
                                                    pageSummary: summary, mode: mode)
            do {
                let acc = try await ClaudeClient.stream(body, apiKey: apiKey, mode: mode) { _ in }
                _ = try acc.decode(Answer.self)
                return acc
            } catch let e as TranslateError {
                if case .invalidRequest = e, mode == .full {
                    mode = .basic
                    throw TranslateError.server(400, "기본 요청으로 다시")
                }
                throw e
            }
        }
        return (try acc.decode(Answer.self).alternatives, acc.usage)
    }
}

/// Gemini·OpenAI 호환 전송(스트리밍 없이 한 번에 — 한 쪽 답은 길지 않다)
enum AIClient {
    static func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await ClaudeClient.session.data(for: req)
        } catch {
            throw ClaudeClient.map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw TranslateError.network("응답이 없어요") }
        guard http.statusCode == 200 else {
            throw TranslateError.from(status: http.statusCode, body: data,
                                      retryAfter: http.value(forHTTPHeaderField: "retry-after"))
        }
        return data
    }

    static func post(_ url: URL, headers: [String: String], body: Data) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 300
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await send(req)
    }

    /// 페이지 하나(그림) — 상자는 0~1000
    static func page(_ r: KeyedRoute, imageJPEG: Data, context: TranslationContext,
                     mode: ClaudeAPI.Mode) async throws -> AIReply {
        let route = r.route
        switch route.provider {
        case .gemini:
            guard let url = GeminiAPI.url(base: route.baseURL, model: route.model) else {
                throw TranslateError.invalidRequest("주소가 잘못됐어요")
            }
            let body = GeminiAPI.pageBody(imageJPEG: imageJPEG, context: context, mode: mode)
            let data = try await post(url, headers: GeminiAPI.headers(apiKey: r.key), body: body)
            return try GeminiAPI.parse(data, model: route.model, freeTier: route.freeTier)
        case .openai:
            guard let url = OpenAIAPI.url(base: route.baseURL) else { throw TranslateError.invalidRequest("주소가 잘못됐어요") }
            let body = OpenAIAPI.pageBody(imageJPEG: imageJPEG, model: route.model, context: context,
                                          baseURL: route.baseURL, mode: mode)
            let data = try await post(url, headers: OpenAIAPI.headers(apiKey: r.key), body: body)
            return try OpenAIAPI.parse(data, model: route.model, freeTier: route.freeTier)
        case .claude:
            throw TranslateError.invalidRequest("Claude는 스트리밍 전송으로")
        }
    }

    /// 글만(다른 표현 받기)
    static func text(_ r: KeyedRoute, prompt: String, schema: [String: Any], mode: ClaudeAPI.Mode) async throws -> AIReply {
        let route = r.route
        switch route.provider {
        case .gemini:
            guard let url = GeminiAPI.url(base: route.baseURL, model: route.model) else {
                throw TranslateError.invalidRequest("주소가 잘못됐어요")
            }
            let data = try await post(url, headers: GeminiAPI.headers(apiKey: r.key),
                                      body: GeminiAPI.textBody(prompt: prompt, schema: schema, mode: mode))
            return try GeminiAPI.parse(data, model: route.model, freeTier: route.freeTier)
        case .openai:
            guard let url = OpenAIAPI.url(base: route.baseURL) else { throw TranslateError.invalidRequest("주소가 잘못됐어요") }
            let body = OpenAIAPI.textBody(model: route.model, prompt: prompt, schema: schema, baseURL: route.baseURL, mode: mode)
            let data = try await post(url, headers: OpenAIAPI.headers(apiKey: r.key), body: body)
            return try OpenAIAPI.parse(data, model: route.model, freeTier: route.freeTier)
        case .claude:
            throw TranslateError.invalidRequest("Claude는 스트리밍 전송으로")
        }
    }

    /// 말풍선 하나의 다른 표현들 — 기본 AI로(Claude면 Claude 전송)
    static func alternatives(_ r: KeyedRoute, source: String, current: String, kind: BlockKind,
                             context: TranslationContext, summary: String) async throws -> ([String], Usage) {
        if r.route.provider == .claude {
            return try await ClaudeClient.alternatives(source: source, current: current, kind: kind, context: context,
                                                       summary: summary, apiKey: r.key)
        }
        struct Answer: Decodable { var alternatives: [String] }
        let prompt = PageRequest.alternativesPrompt(source: source, current: current, kind: kind, context: context,
                                                    pageSummary: summary)
        var mode = ClaudeAPI.Mode.full
        var used = Usage()
        let answer: Answer = try await ClaudeClient.withRetries(3) { _ in
            do {
                let reply = try await text(r, prompt: prompt, schema: PageRequest.alternativesSchema, mode: mode)
                used = used + reply.usage
                return try PageRequest.decodeJSON(Answer.self, from: reply.text)
            } catch let e as TranslateError {
                if case .invalidRequest = e, mode == .full {
                    mode = .basic
                    throw TranslateError.server(400, "기본 요청으로 다시")
                }
                throw e
            }
        }
        return (answer.alternatives, used)
    }

    /// 쓸 수 있는 모델 이름들(키 확인도 겸한다 — 돈이 들지 않는다)
    static func models(_ p: Provider, key: String, baseURL: String) async throws -> [String] {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? p.defaultBaseURL : baseURL
        let url: URL?
        let headers: [String: String]
        switch p {
        case .claude: return [ClaudeAPI.Engine.standard.model, ClaudeAPI.Engine.premium.model]
        case .gemini:
            url = GeminiAPI.modelsURL(base: base)
            headers = GeminiAPI.headers(apiKey: key)
        case .openai:
            url = OpenAIAPI.modelsURL(base: base)
            headers = OpenAIAPI.headers(apiKey: key)
        }
        guard let url else { throw TranslateError.invalidRequest("주소가 잘못됐어요") }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        for (k, v) in headers where k != "content-type" { req.setValue(v, forHTTPHeaderField: k) }
        let data = try await send(req)
        return p == .gemini ? GeminiAPI.parseModels(data) : OpenAIAPI.parseModels(data)
    }

    /// 키 확인: 맞으면 nil, 아니면 이유
    static func checkKey(_ p: Provider, key: String, baseURL: String) async -> String? {
        if p == .claude { return await ClaudeClient.checkKey(key) }
        do {
            _ = try await models(p, key: key, baseURL: baseURL)
            return nil
        } catch {
            return ClaudeClient.map(error).localizedDescription
        }
    }
}

/// 페이지 하나: 그림 준비 → 번역 AI(긴 그림은 조각마다) → 원문 지우기 → 한글 앉히기 → 저장
enum Pipeline {
    struct Job: Sendable {
        let original: URL
        let output: URL
        let thumb: URL
        let context: TranslationContext
        /// 쓸 AI 순서(기본 → 대체). 앞의 것이 실패·거절하면 다음 것으로
        let routes: [KeyedRoute]
        let edits: [String: BlockEdit]
        /// 다시 번역할 때 전의 답(고친 번역을 같은 원문 말풍선으로 옮기려고)
        let previous: PageAnswer?
        /// 기본/고급
        let engine: ClaudeAPI.Engine
    }

    struct Result: Sendable {
        var answer: PageAnswer
        var width: Int
        var height: Int
        var usage: Usage
        var hits: [[Int]]
        var edits: [String: BlockEdit]
        var engine: ClaudeAPI.Engine
        /// 실제로 번역한 AI("Gemini · gemini-2.5-flash")
        var servedBy: String
    }

    /// 말풍선 번호가 바뀌어도 사용자가 고친 것은 원문이 같은 말풍선을 따라간다
    static func remap(_ edits: [String: BlockEdit], from old: PageAnswer?, to new: PageAnswer) -> [String: BlockEdit] {
        guard let old, !edits.isEmpty else { return [:] }
        var out: [String: BlockEdit] = [:]
        var used = Set<Int>()
        for (key, e) in edits.sorted(by: { $0.key < $1.key }) {
            guard let i = Int(key), i < old.blocks.count else { continue }
            let src = old.blocks[i].source.trimmingCharacters(in: .whitespacesAndNewlines)
            if let j = new.blocks.indices.first(where: {
                !used.contains($0) && new.blocks[$0].source.trimmingCharacters(in: .whitespacesAndNewlines) == src
            }) {
                used.insert(j)
                out[String(j)] = e
            }
        }
        return out
    }

    static func translate(_ job: Job, status: @escaping @Sendable (String) -> Void) async throws -> Result {
        status("그림 준비")
        guard let work = Pixels.loadWorking(job.original) else { throw TranslateError.badResponse("그림을 열 수 없어요") }
        let w = work.bitmap.width, h = work.bitmap.height
        let tiles = Tiler.tiles(width: w, height: h)

        // 조각마다 Claude에게(긴 웹툰은 3개씩 같이)
        var answers = [PageAnswer?](repeating: nil, count: tiles.count)
        var usage = Usage()
        var servedBy: [String] = []
        try await withThrowingTaskGroup(of: (Int, PageAnswer, Usage, String).self) { group in
            var next = 0
            func launch() {
                let i = next
                next += 1
                let tile = tiles[i]
                group.addTask {
                    let (a, u, by) = try await Pipeline.ask(work.cg, tile: tile, index: i, count: tiles.count, job: job) { text in
                        status(tiles.count > 1 ? "\(i + 1)/\(tiles.count) \(text)" : text)
                    }
                    return (i, a, u, by)
                }
            }
            for _ in 0..<min(3, tiles.count) { launch() }
            while let r = try await group.next() {
                answers[r.0] = r.1
                usage = usage + r.2
                if !servedBy.contains(r.3) { servedBy.append(r.3) }
                if next < tiles.count { launch() }
            }
        }
        let all = answers.compactMap { $0 }
        let answer: PageAnswer
        if all.count == 1 {
            answer = all[0]
        } else {
            let blocks = Tiler.merge(zip(tiles, all).map { (tile: $0, blocks: $1.blocks) }, height: h)
            answer = PageAnswer(source_language: all.first?.source_language ?? "", blocks: blocks,
                                page_summary: all.map(\.page_summary).filter { !$0.isEmpty }.joined(separator: " "),
                                new_terms: all.reduce([]) { GlossaryEntry.merge($0, adding: $1.new_terms) })
        }
        status("그리는 중")
        let edits = remap(job.edits, from: job.previous, to: answer)
        let hits = try paint(work.bitmap, answer: answer, edits: edits, output: job.output, thumb: job.thumb)
        return Result(answer: answer, width: w, height: h, usage: usage, hits: hits, edits: edits, engine: job.engine,
                      servedBy: servedBy.joined(separator: " + "))
    }

    /// 조각 하나를 보내고 답의 상자를 작업 그림 좌표로 바꾼다. 기본 AI가 실패·거절하면 대체 AI로.
    /// 돌려주는 것: 답, 쓴 토큰·비용, 답한 AI 이름
    static func ask(_ image: CGImage, tile: IRect, index: Int, count: Int, job: Job,
                    status: @escaping @Sendable (String) -> Void) async throws -> (PageAnswer, Usage, String) {
        var failed: TranslateError?
        for (k, r) in job.routes.enumerated() {
            do {
                if let f = failed { status("다른 AI로 다시 · \(r.route.provider.label) (\(f.localizedDescription.prefix(40)))") }
                if r.route.provider == .claude {
                    return try await askClaude(image, tile: tile, index: index, count: count, job: job, key: r.key,
                                               status: status)
                }
                return try await askOther(image, tile: tile, index: index, count: count, job: job, route: r, status: status)
            } catch {
                // 거절·오류면 다음 AI로(취소는 그대로 멈춘다)
                let e = ClaudeClient.map(error)
                guard e != .cancelled, k + 1 < job.routes.count else { throw e }
                failed = e
            }
        }
        throw failed ?? TranslateError.badKey
    }

    /// Gemini·OpenAI 호환: 긴 변 2000px 안쪽으로 보내고 상자는 0~1000으로 받는다(서버가 그림을 더 줄여도 맞는다)
    static func askOther(_ image: CGImage, tile: IRect, index: Int, count: Int, job: Job, route: KeyedRoute,
                         status: @escaping @Sendable (String) -> Void) async throws -> (PageAnswer, Usage, String) {
        guard let crop = image.cropping(to: CGRect(x: tile.x, y: tile.y, width: tile.w, height: tile.h)) else {
            throw TranslateError.badResponse("그림 자르기 실패")
        }
        let scale = min(1, 2000 / Double(max(tile.w, tile.h)))
        let w = max(1, Int(Double(tile.w) * scale)), h = max(1, Int(Double(tile.h) * scale))
        guard let sized = Pixels.resized(crop, width: w, height: h), let jpeg = Pixels.jpeg(sized, quality: 0.88) else {
            throw TranslateError.badResponse("그림 변환 실패")
        }
        var ctx = job.context
        if count > 1 { ctx.segment = (index, count) }
        var used = Usage()
        var mode = ClaudeAPI.Mode.full
        let name = route.route.provider.label
        let reply: AIReply = try await ClaudeClient.withRetries(4) { _ in
            status("\(name)에 보내는 중")
            do {
                let r = try await AIClient.page(route, imageJPEG: jpeg, context: ctx, mode: mode)
                used = used + r.usage
                _ = try PageRequest.decodeJSON(PageAnswer.self, from: r.text)
                return r
            } catch let e as TranslateError {
                // 구조화 출력 같은 기능을 못 쓰는 모델·서버면 JSON만 쓰라고 지시해서 한 번 더
                if case .invalidRequest = e, mode == .full {
                    mode = .basic
                    throw TranslateError.server(400, "기본 요청으로 다시")
                }
                throw e
            }
        }
        let answer = try PageRequest.decodeJSON(PageAnswer.self, from: reply.text)
        let served = AIRoute(provider: route.route.provider, model: reply.model).label
        return (place(answer, tile: tile, sentWidth: 1000, sentHeight: 1000), used, served)
    }

    /// Claude: 서버가 줄이는 규칙대로 크기를 맞춰 보내 상자를 그림 픽셀로 받는다(스트리밍)
    static func askClaude(_ image: CGImage, tile: IRect, index: Int, count: Int, job: Job, key: String,
                          status: @escaping @Sendable (String) -> Void) async throws -> (PageAnswer, Usage, String) {
        guard let crop = image.cropping(to: CGRect(x: tile.x, y: tile.y, width: tile.w, height: tile.h)) else {
            throw TranslateError.badResponse("그림 자르기 실패")
        }
        var (sw, sh) = ClaudeAPI.fittedSize(width: tile.w, height: tile.h)
        guard let sized = Pixels.resized(crop, width: sw, height: sh), var jpeg = Pixels.jpeg(sized, quality: 0.88) else {
            throw TranslateError.badResponse("그림 변환 실패")
        }
        var ctx = job.context
        if count > 1 { ctx.segment = (index, count) }
        var used = Usage()
        // 계정에서 어떤 기능(서버 대체 모델·구조화 출력 등)이 막혀 400이 나면 기본 요청으로 한 번 더
        var mode = ClaudeAPI.Mode.full
        let acc = try await ClaudeClient.withRetries(5) { attempt in
            // 답이 잘렸으면 더 길게 허락하고 다시
            let body = PageRequest.body(imageJPEG: jpeg, width: sw, height: sh, context: ctx,
                                        maxTokens: attempt == 0 ? 32000 : 64000, mode: mode, engine: job.engine)
            status("보내는 중")
            do {
                let acc = try await ClaudeClient.stream(body, apiKey: key, mode: mode, engine: job.engine) { acc in
                    let n = acc.text.count
                    status(n > 0 ? "번역 쓰는 중 \(n)자" : (acc.thinking ? "읽고 생각하는 중" : "기다리는 중"))
                }
                used = used + acc.usage
                _ = try acc.decode(PageAnswer.self)
                return acc
            } catch let e as TranslateError {
                // 서버가 줄여야 한다고 크기를 알려 주면(좌표가 어긋나지 않게) 그 크기로 다시
                if let t = e.downsizeTarget, t.0 < sw || t.1 < sh,
                   let smaller = Pixels.resized(crop, width: t.0, height: t.1), let j = Pixels.jpeg(smaller, quality: 0.88) {
                    (sw, sh) = t
                    jpeg = j
                    throw TranslateError.server(400, "그림 크기 맞춰 다시")
                }
                if case .invalidRequest = e, mode == .full {
                    mode = .basic
                    throw TranslateError.server(400, "기본 요청으로 다시")
                }
                throw e
            }
        }
        let answer = try acc.decode(PageAnswer.self)
        let served = AIRoute(provider: .claude, model: acc.model ?? job.engine.model).label
        return (place(answer, tile: tile, sentWidth: sw, sentHeight: sh), used, served)
    }

    /// 보낸 그림 좌표의 상자를 작업 그림 좌표로(빈 번역·아주 작은 상자는 뺀다)
    static func place(_ answer: PageAnswer, tile: IRect, sentWidth sw: Int, sentHeight sh: Int) -> PageAnswer {
        var answer = answer
        let sx = Double(tile.w) / Double(max(1, sw)), sy = Double(tile.h) / Double(max(1, sh))
        answer.blocks = answer.blocks.compactMap { b in
            var b = b
            let r = b.box.rect
            let x0 = max(0, min(tile.w, Int((Double(r.x) * sx).rounded()))) + tile.x
            let y0 = max(0, min(tile.h, Int((Double(r.y) * sy).rounded()))) + tile.y
            let x1 = max(0, min(tile.w, Int((Double(r.maxX) * sx).rounded()))) + tile.x
            let y1 = max(0, min(tile.h, Int((Double(r.maxY) * sy).rounded()))) + tile.y
            guard x1 - x0 >= 2, y1 - y0 >= 2,
                  !b.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            b.box = .init(x0: x0, y0: y0, x1: x1, y1: y1)
            return b
        }
        return answer
    }

    /// 설정: 효과음·추임새도 번역해 그릴지(UserDefaults, 기본 켬)
    static let sfxKey = "tl.sfx"

    /// 원문을 지우고 번역을 그려 저장한다. 말풍선마다 누를 곳을 돌려준다.
    static func paint(_ bitmap: Bitmap, answer: PageAnswer, edits: [String: BlockEdit], output: URL, thumb: URL) throws -> [[Int]] {
        var active: [(Int, PageAnswer.Block, String)] = []
        for (i, b) in answer.blocks.enumerated() {
            let e = edits[String(i)]
            if e?.hidden == true { continue }
            let text = (e?.translation ?? b.translation).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            active.append((i, b, text))
        }
        // 효과음·추임새: 원래 모양으로 다시 쓰거나(못 하면 원문 그대로), 설정에서 끄면 늘 원문 그대로
        let translateSFX = UserDefaults.standard.object(forKey: Pipeline.sfxKey) as? Bool ?? true
        let refined = Refiner.refinePage(bitmap, blocks: active.map { $0.1.pageBlock }, translateSFX: translateSFX)
        var out = bitmap
        Refiner.erase(&out, refined)
        let placed = zip(active, refined).map { a, r in
            Typesetter.place(a.2, for: r, kind: a.1.blockKind,
                             metrics: FontBook.metrics(for: Typesetter.face(for: r, kind: a.1.blockKind)))
        }
        guard let base = Pixels.cgImage(out), let img = Painter.draw(base: base, texts: placed),
              let data = Pixels.jpeg(img, quality: 0.92) else { throw TranslateError.badResponse("그리기 실패") }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        Importer.makeThumb(from: output, to: thumb)
        var hits = answer.blocks.map { b -> [Int] in
            let r = b.box.rect
            return [r.x, r.y, r.w, r.h]
        }
        for (k, a) in active.enumerated() {
            let r = refined[k].layoutRect.union(a.1.box.rect)
            hits[a.0] = [r.x, r.y, r.w, r.h]
        }
        return hits
    }

    /// 고친 번역으로 다시 그린다(Claude는 부르지 않는다)
    static func repaint(original: URL, answer: PageAnswer, edits: [String: BlockEdit], output: URL, thumb: URL) throws -> [[Int]] {
        guard let work = Pixels.loadWorking(original) else { throw TranslateError.badResponse("그림을 열 수 없어요") }
        return try paint(work.bitmap, answer: answer, edits: edits, output: output, thumb: thumb)
    }
}

/// 번역 대기열: 동시에 3쪽씩, 보고 있는 쪽 근처를 먼저
@MainActor
final class Translator: ObservableObject {
    static let shared = Translator()

    /// 페이지 ID → 지금 하는 일
    @Published private(set) var live: [String: String] = [:]
    @Published private(set) var waiting: [(book: String, page: String, engine: ClaudeAPI.Engine)] = []
    private var running: [String: (book: String, task: Task<Void, Never>)] = [:]
    private var background: UIBackgroundTaskIdentifier = .invalid
    let limit = 3

    var busy: Bool { !running.isEmpty || !waiting.isEmpty }

    func isActive(_ page: String) -> Bool { running[page] != nil || waiting.contains { $0.page == page } }

    func remaining(book: String) -> Int {
        waiting.filter { $0.book == book }.count + running.values.filter { $0.book == book }.count
    }

    func enqueue(book: String, pages: [String], front: Bool = false, engine: ClaudeAPI.Engine = .standard) {
        let lib = Library.shared
        var add: [(book: String, page: String, engine: ClaudeAPI.Engine)] = []
        for p in pages where running[p] == nil {
            waiting.removeAll { $0.page == p }
            guard lib.page(book, p) != nil else { continue }
            add.append((book, p, engine))
            lib.update(book: book, page: p) { rec in
                rec.status = .queued
                rec.error = nil
            }
        }
        waiting = front ? add + waiting : waiting + add
        pump()
    }

    /// 보고 있는 쪽부터 몇 쪽을 대기열 앞으로
    func prioritize(book: String, pages: [String]) {
        let set = Set(pages)
        let first = waiting.filter { $0.book == book && set.contains($0.page) }
            .sorted { (pages.firstIndex(of: $0.page) ?? 0) < (pages.firstIndex(of: $1.page) ?? 0) }
        guard !first.isEmpty else { return }
        waiting = first + waiting.filter { !($0.book == book && set.contains($0.page)) }
    }

    func cancel(book: String, pages: [String]? = nil) {
        let set = pages.map { Set($0) }
        let lib = Library.shared
        for w in waiting where w.book == book && (set?.contains(w.page) ?? true) {
            lib.update(book: book, page: w.page) { rec in rec.status = rec.answer == nil ? .pending : .done }
        }
        waiting.removeAll { $0.book == book && (set?.contains($0.page) ?? true) }
        for (page, r) in running where r.book == book && (set?.contains(page) ?? true) { r.task.cancel() }
        pump()
    }

    private func pump() {
        while running.count < limit, !waiting.isEmpty {
            let job = waiting.removeFirst()
            let task = Task { [weak self] in
                await self?.run(book: job.book, page: job.page, engine: job.engine)
                self?.running[job.page] = nil
                self?.live[job.page] = nil
                self?.pump()
            }
            running[job.page] = (job.book, task)
        }
        // 책 한 권을 번역하는 동안 화면이 꺼지지 않게, 잠깐 다른 앱으로 가도 하던 쪽은 마치게
        UIApplication.shared.isIdleTimerDisabled = busy
        if busy && background == .invalid {
            background = UIApplication.shared.beginBackgroundTask(withName: "translate") { [weak self] in
                Task { @MainActor in self?.endBackground() }
            }
        } else if !busy {
            endBackground()
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    private func run(book: String, page: String, engine: ClaudeAPI.Engine) async {
        let lib = Library.shared
        let routes = AISettings.routes(tier: engine)
        guard let first = routes.first else {
            lib.update(book: book, page: page) { rec in
                rec.status = .failed
                rec.error = "설정에서 번역 AI(\(AISettings.primary.label)) API 키를 넣어 주세요."
            }
            return
        }
        // 정해 둔 예산을 넘지 않게
        if let stop = Budget.block(estimate: first.route.estimatedPageCost) {
            lib.update(book: book, page: page) { rec in
                rec.status = rec.answer == nil ? .failed : .done
                rec.error = stop
            }
            lib.show(stop)
            return
        }
        guard let rec = lib.page(book, page) else { return }
        lib.update(book: book, page: page) { $0.status = .working }
        let job = Pipeline.Job(original: Paths.original(book, rec.file), output: Paths.output(book, page),
                               thumb: Paths.thumb(book, page), context: lib.context(book: book, page: page),
                               routes: routes, edits: rec.edits, previous: rec.answer, engine: engine)
        do {
            let result = try await Pipeline.translate(job) { text in
                Task { @MainActor in
                    if Translator.shared.running[page] != nil { Translator.shared.live[page] = text }
                }
            }
            lib.finish(book: book, page: page, result: result)
        } catch {
            let e = ClaudeClient.map(error)
            lib.update(book: book, page: page) { r in
                if e == .cancelled {
                    r.status = r.answer == nil ? .pending : .done
                } else {
                    r.status = .failed
                    r.error = e.localizedDescription
                }
            }
        }
    }

    /// 번역은 그대로 두고 책의 번역된 쪽을 모두 새로 그린다(Claude는 부르지 않아 무료).
    /// 앱이 나아졌을 때·효과음 설정을 바꿨을 때
    func repaintAll(book: String) async {
        let lib = Library.shared
        let pages = lib.pageList(book).filter { $0.answer != nil && !isActive($0.id) }
        guard !pages.isEmpty else { return lib.show("다시 그릴 번역된 쪽이 없어요") }
        for (i, p) in pages.enumerated() {
            lib.show("다시 그리는 중 \(i + 1)/\(pages.count)쪽")
            await repaint(book: book, page: p.id)
        }
        lib.show("\(pages.count)쪽을 다시 그렸어요")
    }

    /// 고친 번역으로 다시 그리기
    func repaint(book: String, page: String) async {
        let lib = Library.shared
        guard let rec = lib.page(book, page), let answer = rec.answer else { return }
        let original = Paths.original(book, rec.file), output = Paths.output(book, page), thumb = Paths.thumb(book, page)
        let edits = rec.edits
        live[page] = "다시 그리는 중"
        do {
            let hits = try await Task.detached(priority: .userInitiated) {
                try Pipeline.repaint(original: original, answer: answer, edits: edits, output: output, thumb: thumb)
            }.value
            lib.update(book: book, page: page) { r in
                r.hits = hits
                r.version += 1
            }
        } catch {
            lib.show(ClaudeClient.map(error).localizedDescription)
        }
        live[page] = nil
    }
}
