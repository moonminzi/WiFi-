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

    static func request(_ url: URL, apiKey: String) -> URLRequest {
        var req = URLRequest(url: url)
        for (k, v) in ClaudeAPI.headers(apiKey: apiKey) { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// 요청 하나를 스트리밍으로 받는다. progress는 0.3초마다 부른다.
    static func stream(_ body: Data, apiKey: String,
                       progress: @escaping @Sendable (StreamAccumulator) -> Void) async throws -> StreamAccumulator {
        var req = request(ClaudeAPI.endpoint, apiKey: apiKey)
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
        let body = PageRequest.alternativesBody(source: source, current: current, kind: kind, context: context,
                                                pageSummary: summary)
        let acc = try await ClaudeClient.withRetries(3) { _ in
            let acc = try await ClaudeClient.stream(body, apiKey: apiKey) { _ in }
            _ = try acc.decode(Answer.self)
            return acc
        }
        return (try acc.decode(Answer.self).alternatives, acc.usage)
    }
}

/// 페이지 하나: 그림 준비 → Claude(긴 그림은 조각마다) → 원문 지우기 → 한글 앉히기 → 저장
enum Pipeline {
    struct Job: Sendable {
        let original: URL
        let output: URL
        let thumb: URL
        let context: TranslationContext
        let apiKey: String
        let edits: [String: BlockEdit]
    }

    struct Result: Sendable {
        var answer: PageAnswer
        var width: Int
        var height: Int
        var usage: Usage
        var hits: [[Int]]
    }

    static func translate(_ job: Job, status: @escaping @Sendable (String) -> Void) async throws -> Result {
        status("그림 준비")
        guard let work = Pixels.loadWorking(job.original) else { throw TranslateError.badResponse("그림을 열 수 없어요") }
        let w = work.bitmap.width, h = work.bitmap.height
        let tiles = Tiler.tiles(width: w, height: h)

        // 조각마다 Claude에게(긴 웹툰은 3개씩 같이)
        var answers = [PageAnswer?](repeating: nil, count: tiles.count)
        var usage = Usage()
        try await withThrowingTaskGroup(of: (Int, PageAnswer, Usage).self) { group in
            var next = 0
            func launch() {
                let i = next
                next += 1
                let tile = tiles[i]
                group.addTask {
                    let (a, u) = try await Pipeline.ask(work.cg, tile: tile, index: i, count: tiles.count, job: job) { text in
                        status(tiles.count > 1 ? "\(i + 1)/\(tiles.count) \(text)" : text)
                    }
                    return (i, a, u)
                }
            }
            for _ in 0..<min(3, tiles.count) { launch() }
            while let r = try await group.next() {
                answers[r.0] = r.1
                usage = usage + r.2
                if next < tiles.count { launch() }
            }
        }
        let all = answers.compactMap { $0 }
        var answer: PageAnswer
        if all.count == 1 {
            answer = all[0]
        } else {
            let blocks = Tiler.merge(zip(tiles, all).map { (tile: $0, blocks: $1.blocks) }, height: h)
            answer = PageAnswer(source_language: all.first?.source_language ?? "", blocks: blocks,
                                page_summary: all.map(\.page_summary).filter { !$0.isEmpty }.joined(separator: " "),
                                new_terms: all.reduce([]) { GlossaryEntry.merge($0, adding: $1.new_terms) })
        }
        status("그리는 중")
        let hits = try paint(work.bitmap, answer: answer, edits: job.edits, output: job.output, thumb: job.thumb)
        return Result(answer: answer, width: w, height: h, usage: usage, hits: hits)
    }

    /// 조각 하나를 보내고 답의 상자를 작업 그림 좌표로 바꾼다
    static func ask(_ image: CGImage, tile: IRect, index: Int, count: Int, job: Job,
                    status: @escaping @Sendable (String) -> Void) async throws -> (PageAnswer, Usage) {
        guard let crop = image.cropping(to: CGRect(x: tile.x, y: tile.y, width: tile.w, height: tile.h)) else {
            throw TranslateError.badResponse("그림 자르기 실패")
        }
        let (sw, sh) = ClaudeAPI.fittedSize(width: tile.w, height: tile.h)
        guard let sized = Pixels.resized(crop, width: sw, height: sh), let jpeg = Pixels.jpeg(sized, quality: 0.88) else {
            throw TranslateError.badResponse("그림 변환 실패")
        }
        var ctx = job.context
        if count > 1 { ctx.segment = (index, count) }
        var used = Usage()
        let acc = try await ClaudeClient.withRetries { attempt in
            // 답이 잘렸으면 더 길게 허락하고 다시
            let body = PageRequest.body(imageJPEG: jpeg, width: sw, height: sh, context: ctx,
                                        maxTokens: attempt == 0 ? 32000 : 64000)
            status("보내는 중")
            let acc = try await ClaudeClient.stream(body, apiKey: job.apiKey) { acc in
                let n = acc.text.count
                status(n > 0 ? "번역 쓰는 중 \(n)자" : (acc.thinking ? "읽고 생각하는 중" : "기다리는 중"))
            }
            used = used + acc.usage
            _ = try acc.decode(PageAnswer.self)
            return acc
        }
        var answer = try acc.decode(PageAnswer.self)
        let sx = Double(tile.w) / Double(sw), sy = Double(tile.h) / Double(sh)
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
        return (answer, used)
    }

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
        let refined = Refiner.refinePage(bitmap, blocks: active.map { PageBlock(box: $0.1.box.rect, kind: $0.1.blockKind) })
        var out = bitmap
        Refiner.erase(&out, refined)
        let placed = zip(active, refined).map { a, r in
            Typesetter.place(a.2, for: r, kind: a.1.blockKind, metrics: FontBook.metrics)
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
    @Published private(set) var waiting: [(book: String, page: String)] = []
    private var running: [String: (book: String, task: Task<Void, Never>)] = [:]
    let limit = 3

    var busy: Bool { !running.isEmpty || !waiting.isEmpty }

    func isActive(_ page: String) -> Bool { running[page] != nil || waiting.contains { $0.page == page } }

    func remaining(book: String) -> Int {
        waiting.filter { $0.book == book }.count + running.values.filter { $0.book == book }.count
    }

    func enqueue(book: String, pages: [String], front: Bool = false) {
        let lib = Library.shared
        var add: [(book: String, page: String)] = []
        for p in pages where running[p] == nil {
            waiting.removeAll { $0.page == p }
            guard lib.page(book, p) != nil else { continue }
            add.append((book, p))
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
                await self?.run(book: job.book, page: job.page)
                self?.running[job.page] = nil
                self?.live[job.page] = nil
                self?.pump()
            }
            running[job.page] = (job.book, task)
        }
        // 책 한 권을 번역하는 동안 화면이 꺼지지 않게
        UIApplication.shared.isIdleTimerDisabled = busy
    }

    private func run(book: String, page: String) async {
        let lib = Library.shared
        guard let key = Keychain.apiKey, !key.isEmpty else {
            lib.update(book: book, page: page) { rec in
                rec.status = .failed
                rec.error = "설정에서 Claude API 키를 넣어 주세요."
            }
            return
        }
        guard let rec = lib.page(book, page) else { return }
        lib.update(book: book, page: page) { $0.status = .working }
        let job = Pipeline.Job(original: Paths.original(book, rec.file), output: Paths.output(book, page),
                               thumb: Paths.thumb(book, page), context: lib.context(book: book, page: page),
                               apiKey: key, edits: rec.edits)
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
