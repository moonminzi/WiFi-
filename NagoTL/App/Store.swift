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
        }
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

    /// 파일 앱에서 고른 것들: 그림은 한 책으로 묶고, ZIP/CBZ/PDF는 하나씩 책으로
    @MainActor
    static func importFiles(_ urls: [URL]) async -> [String] {
        let lib = Library.shared
        var bookIDs: [String] = []
        var loose: [URL] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ["zip", "cbz"].contains(ext) || ext == "pdf" {
                let title = url.deletingPathExtension().lastPathComponent
                let id = lib.createBook(title: title)
                lib.show("가져오는 중: \(title)")
                let files: [String] = await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return ext == "pdf" ? Importer.pdfPages(url, book: id) : Importer.archivePages(url, book: id)
                }.value
                if files.isEmpty {
                    lib.deleteBook(id)
                    lib.show("그림을 찾지 못했어요: \(url.lastPathComponent)")
                } else {
                    _ = lib.attach(book: id, files: files)
                    bookIDs.append(id)
                }
            } else {
                loose.append(url)
            }
        }
        if !loose.isEmpty {
            let title = loose.count == 1 ? loose[0].deletingPathExtension().lastPathComponent : "그림 \(loose.count)장"
            let id = lib.createBook(title: title)
            let sorted = loose.sorted { naturalLess($0.lastPathComponent, $1.lastPathComponent) }
            let files: [String] = await Task.detached(priority: .userInitiated) {
                sorted.enumerated().compactMap { i, url in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let d = try? Data(contentsOf: url) else { return nil }
                    let e = Importer.imageExts.contains(url.pathExtension.lowercased())
                        ? url.pathExtension : Importer.ext(for: d)
                    return Importer.store(d, ext: e, book: id, index: i)
                }
            }.value
            if files.isEmpty { lib.deleteBook(id) } else {
                _ = lib.attach(book: id, files: files)
                bookIDs.append(id)
            }
        }
        return bookIDs
    }

    static func archivePages(_ url: URL, book: String) -> [String] {
        guard let zip = try? ZipReader(url: url) else { return [] }
        var out: [String] = []
        for (i, e) in zip.imageEntries.enumerated() {
            guard let data = try? zip.extract(e) else { continue }
            if let f = store(data, ext: (e.name as NSString).pathExtension, book: book, index: i) { out.append(f) }
        }
        return out
    }

    /// PDF 쪽을 그림으로(긴 변 2000px 안팎)
    static func pdfPages(_ url: URL, book: String) -> [String] {
        guard let doc = PDFDocument(url: url) else { return [] }
        var out: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
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
            if let data = img.jpegData(compressionQuality: 0.92), let f = store(data, ext: "jpg", book: book, index: i) {
                out.append(f)
            }
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
