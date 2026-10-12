import Foundation
import ImageIO
import NagoTLCore
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// 말풍선 하나에 사용자가 고친 것
struct BlockEdit: Codable, Equatable {
    var translation: String?
    var hidden = false
}

/// 페이지 하나(원본 그림 + 번역 결과)
struct PageRecord: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case pending, queued, working, done, failed
    }

    var id: String
    /// pages/ 폴더 안 원본 파일 이름
    var file: String
    var status: Status = .pending
    var error: String?
    var answer: PageAnswer?
    /// 번역·그리기에 쓴 그림 크기(answer 상자 좌표 기준)
    var width = 0
    var height = 0
    /// 말풍선 번호 → 고친 것
    var edits: [String: BlockEdit] = [:]
    /// 말풍선마다 누를 수 있는 곳(x, y, w, h) — 번역 그림 좌표
    var hits: [[Int]] = []
    var usage = Usage()
    var translatedAt: Date?
    /// 그림을 다시 그릴 때마다 올린다(화면 새로고침용)
    var version = 0
    /// 지금 번역을 만든 등급(기본 / 고급)
    var engine: ClaudeAPI.Engine?
    /// 실제로 번역한 AI("Gemini · gemini-2.5-flash")
    var servedBy: String?
}

/// 책(또는 사진 모음)
struct BookRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case book, photos
    }

    enum Direction: String, Codable, CaseIterable {
        case auto, rtl, ltr, vertical

        var label: String {
            switch self {
            case .auto: "자동"
            case .rtl: "← 망가"
            case .ltr: "→ 만화"
            case .vertical: "↓ 웹툰"
            }
        }
    }

    var id: String
    var title: String
    var kind: Kind = .book
    var created = Date()
    var pageIDs: [String] = []
    /// 이 작품의 용어집(이름·지명 등) — 번역할 때마다 Claude가 새 용어를 더한다
    var glossary: [GlossaryEntry] = []
    /// 사용자가 적는 작품 메모(등장인물 관계, 말투 등)
    var note = ""
    var direction: Direction = .auto
    /// 페이지별 요약(다음 페이지 번역 때 앞 내용으로 준다)
    var summaries: [String: String] = [:]
    var sourceLanguage: String?
    var usage = Usage()
}

enum Paths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("NagoTL", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var books: URL { root.appendingPathComponent("books", isDirectory: true) }
    static func book(_ id: String) -> URL { books.appendingPathComponent(id, isDirectory: true) }
    static func bookFile(_ id: String) -> URL { book(id).appendingPathComponent("book.json") }
    static func pagesDir(_ id: String) -> URL { book(id).appendingPathComponent("pages", isDirectory: true) }
    static func original(_ book: String, _ file: String) -> URL { pagesDir(book).appendingPathComponent(file) }
    static func record(_ book: String, _ page: String) -> URL { pagesDir(book).appendingPathComponent(page + ".json") }
    static func output(_ book: String, _ page: String) -> URL {
        Paths.book(book).appendingPathComponent("out", isDirectory: true).appendingPathComponent(page + ".jpg")
    }
    static func thumb(_ book: String, _ page: String) -> URL {
        Paths.book(book).appendingPathComponent("thumbs", isDirectory: true).appendingPathComponent(page + ".jpg")
    }
    static var exports: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 서재: 책·페이지 기록을 들고 있고 파일에 저장한다(모든 변경은 메인 스레드에서)
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var books: [BookRecord] = []
    /// 불러온 책의 페이지들
    @Published private(set) var pages: [String: [String: PageRecord]] = [:]
    @Published var toast: String?
    /// 파일 가져오는 중이면 무엇을 얼마나(서재 화면에 보인다)
    @Published var importing: String?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        load()
    }

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.books, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: Paths.books, includingPropertiesForKeys: nil)) ?? []
        books = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("book.json")) else { return nil }
            return try? decoder.decode(BookRecord.self, from: data)
        }.sorted { $0.created > $1.created }
        // 번역 도중 앱이 꺼졌던 페이지는 다시 대기로
        for b in books { _ = pageList(b.id) }
    }

    func book(_ id: String) -> BookRecord? { books.first { $0.id == id } }

    /// 책의 페이지들(순서대로). 처음 부르면 파일에서 읽는다.
    func pageList(_ bookID: String) -> [PageRecord] {
        guard let b = book(bookID) else { return [] }
        if pages[bookID] == nil {
            var map: [String: PageRecord] = [:]
            for id in b.pageIDs {
                if let data = try? Data(contentsOf: Paths.record(bookID, id)),
                   var rec = try? decoder.decode(PageRecord.self, from: data) {
                    if rec.status == .working || rec.status == .queued { rec.status = rec.answer == nil ? .pending : .done }
                    map[id] = rec
                }
            }
            pages[bookID] = map
        }
        let map = pages[bookID] ?? [:]
        return b.pageIDs.compactMap { map[$0] }
    }

    func page(_ bookID: String, _ id: String) -> PageRecord? {
        if pages[bookID] == nil { _ = pageList(bookID) }
        return pages[bookID]?[id]
    }

    func update(book bookID: String, page id: String, save: Bool = true, _ change: (inout PageRecord) -> Void) {
        guard var rec = page(bookID, id) else { return }
        change(&rec)
        pages[bookID]?[id] = rec
        if save { write(rec, book: bookID) }
    }

    func updateBook(_ id: String, _ change: (inout BookRecord) -> Void) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[i])
        write(books[i])
    }

    private func write(_ rec: PageRecord, book: String) {
        if let data = try? encoder.encode(rec) { try? data.write(to: Paths.record(book, rec.id), options: .atomic) }
    }

    private func write(_ b: BookRecord) {
        if let data = try? encoder.encode(b) { try? data.write(to: Paths.bookFile(b.id), options: .atomic) }
    }

    // MARK: - 만들기·지우기

    func createBook(title: String, kind: BookRecord.Kind = .book) -> String {
        let id = UUID().uuidString
        let fm = FileManager.default
        for dir in [Paths.pagesDir(id), Paths.output(id, "x").deletingLastPathComponent(),
                    Paths.thumb(id, "x").deletingLastPathComponent()] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let b = BookRecord(id: id, title: title, kind: kind)
        books.insert(b, at: 0)
        pages[id] = [:]
        write(b)
        return id
    }

    /// 사진 번역 모음(하나뿐)
    func photosBookID() -> String {
        if let b = books.first(where: { $0.kind == .photos }) { return b.id }
        return createBook(title: "사진 번역", kind: .photos)
    }

    /// 이미 pages/에 저장된 원본 파일들을 페이지로 붙인다
    func attach(book bookID: String, files: [String], atFront: Bool = false) -> [String] {
        var ids: [String] = []
        for file in files {
            let id = (file as NSString).deletingPathExtension
            let rec = PageRecord(id: id, file: file)
            pages[bookID, default: [:]][id] = rec
            write(rec, book: bookID)
            ids.append(id)
        }
        updateBook(bookID) { b in b.pageIDs = atFront ? ids + b.pageIDs : b.pageIDs + ids }
        return ids
    }

    func deleteBook(_ id: String) {
        Translator.shared.cancel(book: id)
        books.removeAll { $0.id == id }
        pages[id] = nil
        try? FileManager.default.removeItem(at: Paths.book(id))
    }

    func deletePages(book bookID: String, ids: [String]) {
        Translator.shared.cancel(book: bookID, pages: ids)
        guard let b = book(bookID) else { return }
        for id in ids {
            if let rec = page(bookID, id) { try? FileManager.default.removeItem(at: Paths.original(bookID, rec.file)) }
            for url in [Paths.record(bookID, id), Paths.output(bookID, id), Paths.thumb(bookID, id)] {
                try? FileManager.default.removeItem(at: url)
            }
            pages[bookID]?[id] = nil
        }
        let gone = Set(ids)
        updateBook(bookID) { $0.pageIDs = b.pageIDs.filter { !gone.contains($0) } }
    }

    // MARK: - 번역 결과

    /// Claude에게 줄 맥락: 용어집, 작품 메모, 바로 앞 페이지들 요약
    func context(book bookID: String, page id: String) -> TranslationContext {
        guard let b = book(bookID) else { return TranslationContext() }
        var previous: [String] = []
        if b.kind == .book, let i = b.pageIDs.firstIndex(of: id) {
            for pid in b.pageIDs[..<i].suffix(3) {
                if let s = b.summaries[pid], !s.isEmpty { previous.append(s) }
            }
        }
        return TranslationContext(glossary: b.glossary, previousSummaries: previous, bookNote: b.note)
    }

    func finish(book bookID: String, page id: String, result: Pipeline.Result) {
        update(book: bookID, page: id) { rec in
            rec.status = .done
            rec.error = nil
            rec.answer = result.answer
            rec.edits = result.edits
            rec.width = result.width
            rec.height = result.height
            rec.hits = result.hits
            rec.usage = rec.usage + result.usage
            rec.translatedAt = Date()
            rec.version += 1
            rec.engine = result.engine
            rec.servedBy = result.servedBy.isEmpty ? nil : result.servedBy
        }
        Budget.add(result.usage.dollars)
        updateBook(bookID) { b in
            b.usage = b.usage + result.usage
            if b.kind == .book {
                b.glossary = GlossaryEntry.merge(b.glossary, adding: result.answer.new_terms)
                b.summaries[id] = result.answer.page_summary
            }
            if !result.answer.source_language.isEmpty { b.sourceLanguage = result.answer.source_language }
        }
    }

    /// 실제 읽는 방향
    func direction(_ bookID: String) -> BookRecord.Direction {
        guard let b = book(bookID) else { return .ltr }
        if b.direction != .auto { return b.direction }
        if b.kind == .photos { return .ltr }
        // 세로로 긴 그림이 대부분이면 웹툰
        let recs = pageList(bookID).filter { $0.width > 0 }
        if recs.count >= 1, recs.filter({ Double($0.height) > Double($0.width) * 2.2 }).count * 2 > recs.count {
            return .vertical
        }
        if let lang = b.sourceLanguage { return lang == "ja" ? .rtl : .ltr }
        return .rtl
    }

    var totalUsage: Usage { books.reduce(Usage()) { $0 + $1.usage } }

    func show(_ message: String) {
        toast = message
        let current = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self.toast == current { self.toast = nil }
        }
    }
}

/// 쓸 돈 한도: 정해 둔 금액을 넘으면 번역을 멈춘다(실제 청구는 Anthropic 콘솔 기준, 여기 숫자는 어림)
enum Budget {
    static let limitKey = "tl.budget"
    static let spentKey = "tl.spent"

    static var limit: Double {
        let v = UserDefaults.standard.double(forKey: limitKey)
        return v > 0 ? v : 5
    }

    static var spent: Double { UserDefaults.standard.double(forKey: spentKey) }

    static var remaining: Double { max(0, limit - spent) }

    static func add(_ dollars: Double) {
        guard dollars > 0 else { return }
        UserDefaults.standard.set(spent + dollars, forKey: spentKey)
    }

    /// 이 엔진으로 한 쪽을 더 하면 한도를 넘는가 — 넘으면 안내 문구
    static func block(estimate: Double) -> String? {
        guard spent + estimate > limit else { return nil }
        return String(format: "예산 $%.2f 중 $%.2f를 썼어요. 설정에서 예산을 늘리면 이어서 번역해요.", limit, spent)
    }
}

/// 가져오기: 사진·그림 파일·ZIP/CBZ·PDF → 페이지 원본 파일
enum Importer {
    static let cbz = UTType(importedAs: "com.nagotl.cbz", conformingTo: .zip)
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif", "avif", "tif", "tiff"]

    /// 그림 데이터를 책 폴더에 저장하고 파일 이름을 돌려준다
    static func store(_ data: Data, ext: String, book: String, index: Int) -> String? {
        let name = String(format: "%05d-", index) + UUID().uuidString.prefix(8).lowercased() + "." + ext.lowercased()
        do {
            try data.write(to: Paths.original(book, name), options: .atomic)
            makeThumb(from: Paths.original(book, name), to: Paths.thumb(book, (name as NSString).deletingPathExtension))
            return name
        } catch {
            return nil
        }
    }

    static func ext(for data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if b.count >= 12, String(decoding: b[4...11], as: UTF8.self).hasPrefix("ftyp") {
            let brand = String(decoding: b[8...11], as: UTF8.self)
            return brand.hasPrefix("avif") ? "avif" : "heic"
        }
        return "jpg"
    }

    /// 사진 앱에서 고른 그림들 → 책(새로 만들거나 이어 붙이기). 붙인 페이지 ID들
    static func importImages(_ datas: [Data], book: String, atFront: Bool = false) async -> [String] {
        let start = await MainActor.run { Library.shared.book(book)?.pageIDs.count ?? 0 }
        let files: [String] = await Task.detached(priority: .userInitiated) {
            datas.enumerated().compactMap { i, d in
                Importer.store(d, ext: Importer.ext(for: d), book: book, index: start + i)
            }
        }.value
        return await MainActor.run { Library.shared.attach(book: book, files: files, atFront: atFront) }
    }

    /// 파일 앱에서 고를 수 있는 종류
    static var fileTypes: [UTType] { [.image, .zip, cbz, .pdf] }

    enum Kind { case archive, pdf, image }

    /// 확장자로, 모르는 확장자면 파일 앞머리로
    static func kind(of url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if ext == "zip" || ext == "cbz" { return .archive }
        if ext == "pdf" { return .pdf }
        if imageExts.contains(ext) { return .image }
        let head: [UInt8] = withAccess(url) {
            guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? h.close() }
            return [UInt8]((try? h.read(upToCount: 8)) ?? Data())
        }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .archive }
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }
        return .image
    }

    /// 보안 범위가 걸린 주소면 읽는 동안만 열어 둔다(선택기가 준 복사본이면 아무 일 없음)
    static func withAccess<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// 그림으로 읽히는 데이터인가(빈 파일·맥 부가 파일 같은 건 뺀다)
    static func isImage(_ data: Data) -> Bool {
        guard !data.isEmpty, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(src) != nil && CGImageSourceGetCount(src) > 0
    }

    /// 선택기·다른 앱이 이 앱 안에 만들어 준 복사본인가(가져온 뒤 지운다). 사용자의 원본은 건드리지 않는다
    static func isOurCopy(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox").resolvingSymlinksInPath().path
        return path.hasPrefix(tmp + "/") || path.hasPrefix(inbox + "/")
    }

    /// 지금 가져오는 중인 것(서재 화면에 보인다)
    @MainActor
    static func report(_ text: String) {
        Library.shared.importing = text
    }

    /// 파일 앱·다른 앱에서 받은 것들: 그림은 한 책으로 묶고, ZIP/CBZ/PDF는 하나씩 책으로. 만든 책 ID들
    @MainActor
    static func importFiles(_ urls: [URL]) async -> [String] {
        let lib = Library.shared
        var bookIDs: [String] = []
        var problems: [String] = []
        var loose: [URL] = []
        for (n, url) in urls.enumerated() {
            let title = url.deletingPathExtension().lastPathComponent
            report("가져오는 중: \(title)" + (urls.count > 1 ? " (\(n + 1)/\(urls.count))" : ""))
            let kind = await Task.detached(priority: .userInitiated) { Importer.kind(of: url) }.value
            switch kind {
            case .archive:
                let r = await importArchive(url, title: title)
                bookIDs += r.ids
                problems += r.problems
            case .pdf:
                let r = await importPDF(url, title: title)
                bookIDs += r.ids
                problems += r.problems
            case .image:
                loose.append(url)
            }
        }
        if !loose.isEmpty {
            let r = await importLoose(loose)
            bookIDs += r.ids
            problems += r.problems
        }
        for url in urls where isOurCopy(url) { try? FileManager.default.removeItem(at: url) }
        lib.importing = nil
        if !problems.isEmpty {
            lib.show(problems.joined(separator: "\n"))
        } else if bookIDs.isEmpty {
            lib.show("가져올 그림을 찾지 못했어요")
        } else if bookIDs.count > 1 {
            lib.show("책 \(bookIDs.count)권을 가져왔어요")
        }
        return bookIDs
    }

    /// 낱장 그림들 → 한 책(파일 이름 순서: 2가 10보다 앞)
    @MainActor
    static func importLoose(_ urls: [URL]) async -> (ids: [String], problems: [String]) {
        let lib = Library.shared
        let title = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "그림 \(urls.count)장"
        let id = lib.createBook(title: title)
        let sorted = urls.sorted { naturalLess($0.lastPathComponent, $1.lastPathComponent) }
        let files: [String] = await Task.detached(priority: .userInitiated) {
            var out: [String] = []
            for (i, url) in sorted.enumerated() {
                let data = Importer.withAccess(url) { try? Data(contentsOf: url) }
                if let d = data, Importer.isImage(d) {
                    let e = Importer.imageExts.contains(url.pathExtension.lowercased()) ? url.pathExtension : Importer.ext(for: d)
                    if let f = Importer.store(d, ext: e, book: id, index: i) { out.append(f) }
                }
                await Importer.report("가져오는 중: 그림 \(i + 1)/\(sorted.count)장")
            }
            return out
        }.value
        guard !files.isEmpty else {
            lib.deleteBook(id)
            return ([], ["그림 파일을 읽지 못했어요"])
        }
        _ = lib.attach(book: id, files: files)
        let skipped = sorted.count - files.count
        return ([id], skipped > 0 ? ["\(skipped)장은 그림으로 읽히지 않아 뺐어요"] : [])
    }

    /// ZIP/CBZ 하나 → 책 하나. 그림 없이 ZIP/CBZ/PDF만 들어 있으면(여러 권 묶음) 그것들을 권마다 책으로
    @MainActor
    static func importArchive(_ url: URL, title: String, nested: Bool = false) async -> (ids: [String], problems: [String]) {
        let lib = Library.shared
        let opened: Result<ZipReader, Error> = await Task.detached(priority: .userInitiated) {
            Result { try Importer.withAccess(url) { try ZipReader(url: url) } }
        }.value
        let zip: ZipReader
        switch opened {
        case let .success(z): zip = z
        case let .failure(e): return ([], ["\(title): \(e.localizedDescription)"])
        }
        let images = zip.imageEntries
        if images.isEmpty {
            let inner = nested ? [] : zip.innerBooks
            guard !inner.isEmpty else {
                let locked = zip.entries.contains { $0.encrypted }
                return ([], [title + (locked ? ": 암호가 걸린 ZIP이라 열 수 없어요" : ": 안에 그림 파일이 없어요")])
            }
            var ids: [String] = []
            var problems: [String] = []
            for (k, e) in inner.enumerated() {
                let name = e.name.split(separator: "/").last.map(String.init) ?? e.name
                let sub = (name as NSString).deletingPathExtension
                report("가져오는 중: \(title) · \(k + 1)/\(inner.count)권")
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("inner-" + UUID().uuidString)
                    .appendingPathExtension((name as NSString).pathExtension.lowercased())
                let ok: Bool = await Task.detached(priority: .userInitiated) {
                    guard let d = try? zip.extract(e) else { return false }
                    return (try? d.write(to: tmp)) != nil
                }.value
                guard ok else {
                    problems.append("\(sub): 꺼내지 못했어요")
                    continue
                }
                let r: (ids: [String], problems: [String])
                if tmp.pathExtension == "pdf" {
                    r = await importPDF(tmp, title: sub)
                } else {
                    r = await importArchive(tmp, title: sub, nested: true)
                }
                try? FileManager.default.removeItem(at: tmp)
                ids += r.ids
                problems += r.problems
            }
            return (ids, problems)
        }
        let id = lib.createBook(title: title)
        let total = images.count
        let files: [String] = await Task.detached(priority: .userInitiated) {
            var out: [String] = []
            for (i, e) in images.enumerated() {
                if let data = try? zip.extract(e), Importer.isImage(data),
                   let f = Importer.store(data, ext: (e.name as NSString).pathExtension, book: id, index: i) {
                    out.append(f)
                }
                if i % 3 == 2 || i == total - 1 { await Importer.report("가져오는 중: \(title) · \(i + 1)/\(total)쪽") }
            }
            return out
        }.value
        guard !files.isEmpty else {
            lib.deleteBook(id)
            let locked = images.contains { $0.encrypted }
            return ([], [title + (locked ? ": 암호가 걸린 ZIP이라 열 수 없어요" : ": 그림을 하나도 읽지 못했어요")])
        }
        _ = lib.attach(book: id, files: files)
        return ([id], files.count < total ? ["\(title): \(total - files.count)쪽은 읽지 못해 뺐어요"] : [])
    }

    /// PDF → 책 하나(쪽마다 긴 변 2000px 안팎 그림으로)
    @MainActor
    static func importPDF(_ url: URL, title: String) async -> (ids: [String], problems: [String]) {
        let lib = Library.shared
        let id = lib.createBook(title: title)
        let files: [String] = await Task.detached(priority: .userInitiated) {
            await Importer.pdfPages(url, book: id) { n, total in
                await Importer.report("가져오는 중: \(title) · \(n)/\(total)쪽")
            }
        }.value
        guard !files.isEmpty else {
            lib.deleteBook(id)
            return ([], ["\(title): PDF를 열지 못했어요(암호가 걸렸거나 깨진 파일)"])
        }
        _ = lib.attach(book: id, files: files)
        return ([id], [])
    }

    static func pdfPages(_ url: URL, book: String, progress: (Int, Int) async -> Void) async -> [String] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return [] }
        var out: [String] = []
        for i in 0..<doc.pageCount {
            let file: String? = autoreleasepool {
                guard let page = doc.page(at: i) else { return nil }
                let box = page.bounds(for: .mediaBox)
                let scale = min(4, max(1, 2000 / max(box.width, box.height)))
                let size = CGSize(width: (box.width * scale).rounded(), height: (box.height * scale).rounded())
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                    UIColor.white.setFill()
                    ctx.fill(CGRect(origin: .zero, size: size))
                    ctx.cgContext.translateBy(x: 0, y: size.height)
                    ctx.cgContext.scaleBy(x: scale, y: -scale)
                    page.draw(with: .mediaBox, to: ctx.cgContext)
                }
                guard let data = img.jpegData(compressionQuality: 0.92) else { return nil }
                return store(data, ext: "jpg", book: book, index: i)
            }
            if let file { out.append(file) }
            await progress(i + 1, doc.pageCount)
        }
        return out
    }

    /// 목록용 작은 그림
    static func makeThumb(from src: URL, to dst: URL, maxPixel: Int = 420) {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { return }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
              let data = Pixels.jpeg(cg, quality: 0.8) else { return }
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: dst, options: .atomic)
    }
}
