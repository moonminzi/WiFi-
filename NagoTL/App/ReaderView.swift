import NagoTLCore
import SwiftUI
import UIKit

/// 누른 말풍선
struct BlockTarget: Identifiable, Equatable {
    let page: String
    let index: Int
    var id: String { "\(page)#\(index)" }
}

/// 뷰어: 망가는 넘기기(일본 망가는 오른쪽→왼쪽), 웹툰은 세로 스크롤. 읽는 쪽부터 알아서 번역한다.
struct ReaderView: View {
    let bookID: String
    let start: Int
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var translator: Translator
    @EnvironmentObject private var router: Router
    @State private var index = 0
    @State private var showOriginal = false
    @State private var chrome = true
    @State private var editing: BlockTarget?
    @State private var shareURL: URL?
    @State private var appeared = false

    var body: some View {
        let pages = library.pageList(bookID)
        let dir = library.direction(bookID)
        ZStack {
            Color.black.ignoresSafeArea()
            if pages.isEmpty {
                Text("쪽이 없어요").font(Term.mono(14)).foregroundStyle(Term.muted)
            } else if dir == .vertical {
                vertical(pages)
            } else {
                paged(pages, rtl: dir == .rtl)
            }
            if chrome && !pages.isEmpty { overlay(pages) }
        }
        .statusBarHidden(!chrome)
        .onAppear {
            guard !appeared else { return }
            appeared = true
            index = min(max(0, start), max(0, pages.count - 1))
            readAhead(pages)
        }
        .onChange(of: index) { _, _ in readAhead(library.pageList(bookID)) }
        .sheet(item: $editing) { t in
            BlockSheet(bookID: bookID, target: t)
                .environmentObject(library)
                .environmentObject(translator)
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { item in
            ActivityView(items: [item.url])
        }
    }

    // MARK: - 넘기기·세로

    private func paged(_ pages: [PageRecord], rtl: Bool) -> some View {
        TabView(selection: $index) {
            ForEach(Array(pages.enumerated()), id: \.element.id) { i, p in
                PageView(bookID: bookID, page: p, showOriginal: showOriginal) { point in tapped(p, point) }
                    .environment(\.layoutDirection, .leftToRight)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .ignoresSafeArea()
    }

    private func vertical(_ pages: [PageRecord]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { i, p in
                        StripView(bookID: bookID, page: p, showOriginal: showOriginal) { point in tapped(p, point) }
                            .id(i)
                            .onAppear { index = i }
                    }
                }
            }
            .ignoresSafeArea()
            .onAppear { proxy.scrollTo(index, anchor: .top) }
        }
    }

    // MARK: - 위아래 막대

    private func overlay(_ pages: [PageRecord]) -> some View {
        let page = pages[min(index, pages.count - 1)]
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { router.reader = nil } label: { Image(systemName: "xmark") }
                Text("\(index + 1)/\(pages.count)").font(Term.mono(13)).foregroundStyle(Term.text)
                Spacer()
                Button { showOriginal.toggle() } label: {
                    Text(showOriginal ? "원문" : "번역")
                        .font(Term.mono(13, .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(showOriginal ? Term.amber : Term.green, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(Term.bg)
                }
                Menu {
                    Button { translator.enqueue(book: bookID, pages: [page.id], front: true) } label: {
                        Label(page.answer == nil ? "이 쪽 번역" : "이 쪽 다시 번역", systemImage: "arrow.clockwise")
                    }
                    Button { Task { await save(page) } } label: { Label("사진 앱에 저장", systemImage: "square.and.arrow.down") }
                    Button { shareURL = imageURL(page) } label: { Label("공유", systemImage: "square.and.arrow.up") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .font(.system(size: 18))
            .foregroundStyle(Term.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Term.bg.opacity(0.88))

            Spacer()

            status(page)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Term.bg.opacity(0.88))
        }
    }

    @ViewBuilder private func status(_ page: PageRecord) -> some View {
        if let live = translator.live[page.id] {
            StatusLine(kind: .running, text: live)
        } else {
            switch page.status {
            case .pending:
                HStack {
                    StatusLine(kind: .warn, text: Keychain.apiKey == nil ? "설정에서 API 키를 넣어 주세요" : "아직 번역 안 됨")
                    Button("번역") { translator.enqueue(book: bookID, pages: [page.id], front: true) }
                        .buttonStyle(.term)
                }
            case .queued:
                StatusLine(kind: .running, text: "번역 대기 중")
            case .working:
                StatusLine(kind: .running, text: "번역 중")
            case .failed:
                VStack(alignment: .leading, spacing: 6) {
                    StatusLine(kind: .error, text: page.error ?? "실패")
                    Button("다시 시도") { translator.enqueue(book: bookID, pages: [page.id], front: true) }
                        .buttonStyle(.term)
                }
            case .done:
                Text(showOriginal ? "원문 보는 중 — 번역 단추로 돌아가요" : "말풍선을 누르면 원문·고치기 · 이 쪽 \(page.usage.costText)")
                    .font(Term.mono(11.5))
                    .foregroundStyle(Term.muted)
            }
        }
    }

    // MARK: - 동작

    /// 보고 있는 쪽과 다음 두 쪽은 미리 번역해 둔다
    private func readAhead(_ pages: [PageRecord]) {
        guard !pages.isEmpty, Keychain.apiKey != nil else { return }
        let ahead = Array(pages[index..<min(pages.count, index + 3)])
        let need = ahead.filter { $0.status == .pending }.map(\.id)
        if !need.isEmpty { translator.enqueue(book: bookID, pages: need, front: true) }
        translator.prioritize(book: bookID, pages: ahead.map(\.id))
    }

    private func tapped(_ page: PageRecord, _ point: CGPoint?) {
        guard !showOriginal, page.answer != nil, let p = point else {
            chrome.toggle()
            return
        }
        // 누른 곳을 품은 말풍선 중 가장 작은 것
        var best: (Int, Int)?
        for (i, h) in page.hits.enumerated() where h.count == 4 {
            let r = CGRect(x: h[0], y: h[1], width: h[2], height: h[3]).insetBy(dx: -10, dy: -10)
            guard r.contains(p) else { continue }
            let area = h[2] * h[3]
            if best == nil || area < best!.1 { best = (i, area) }
        }
        if let b = best { editing = BlockTarget(page: page.id, index: b.0) } else { chrome.toggle() }
    }

    private func imageURL(_ page: PageRecord) -> URL {
        let out = Paths.output(bookID, page.id)
        if !showOriginal, page.answer != nil, FileManager.default.fileExists(atPath: out.path) { return out }
        return Paths.original(bookID, page.file)
    }

    private func save(_ page: PageRecord) async {
        do {
            try await MediaSaver.save([imageURL(page)])
            library.show("사진 앱에 저장했어요")
        } catch {
            library.show(error.localizedDescription)
        }
    }
}

/// 넘기기 모드의 한 쪽(확대 가능)
struct PageView: View {
    let bookID: String
    let page: PageRecord
    let showOriginal: Bool
    let onTap: (CGPoint?) -> Void
    @State private var image: UIImage?
    @State private var showingOutput = false

    var body: some View {
        ZoomableImage(image: image) { point in
            // 화면 그림 픽셀 → 번역 그림(작업 크기) 픽셀
            guard showingOutput, let p = point, let img = image, page.width > 0 else { return onTap(nil) }
            let k = Double(page.width) / Double(img.size.width * img.scale)
            onTap(CGPoint(x: p.x * k, y: p.y * k))
        }
        .overlay {
            if image == nil { ProgressView().tint(Term.muted) }
        }
        .task(id: "\(page.id)#\(page.version)#\(showOriginal)") {
            let out = Paths.output(bookID, page.id)
            let useOut = !showOriginal && page.answer != nil && FileManager.default.fileExists(atPath: out.path)
            let url = useOut ? out : Paths.original(bookID, page.file)
            let img = await Task.detached(priority: .userInitiated) { Pixels.display(url, maxPixel: 2600) }.value
            showingOutput = useOut
            image = img
        }
    }
}

/// 세로 모드(웹툰)의 한 쪽: 화면 폭에 맞춰 이어 붙인다
struct StripView: View {
    let bookID: String
    let page: PageRecord
    let showOriginal: Bool
    let onTap: (CGPoint?) -> Void
    @State private var image: UIImage?
    @State private var showingOutput = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture(coordinateSpace: .local) { loc in
                                    guard showingOutput, page.width > 0, geo.size.width > 0 else { return onTap(nil) }
                                    let k = Double(page.width) / Double(geo.size.width)
                                    onTap(CGPoint(x: loc.x * k, y: loc.y * k))
                                }
                        }
                    }
            } else {
                Color.black.frame(height: 400).overlay { ProgressView().tint(Term.muted) }
            }
        }
        .task(id: "\(page.id)#\(page.version)#\(showOriginal)") {
            let out = Paths.output(bookID, page.id)
            let useOut = !showOriginal && page.answer != nil && FileManager.default.fileExists(atPath: out.path)
            let url = useOut ? out : Paths.original(bookID, page.file)
            let img = await Task.detached(priority: .userInitiated) { Pixels.displayFittingWidth(url, maxWidth: 1300) }.value
            showingOutput = useOut
            image = img
        }
    }
}

/// UIScrollView로 두 손가락 확대, 두 번 눌러 확대/원래대로, 한 번 누르면 그림 픽셀 좌표를 알려 준다
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?
    let onTap: (CGPoint?) -> Void

    func makeUIView(context: Context) -> ZoomView {
        let v = ZoomView(frame: .zero)
        v.onTap = onTap
        v.setImage(image)
        return v
    }

    func updateUIView(_ v: ZoomView, context: Context) {
        v.onTap = onTap
        if v.imageView.image !== image { v.setImage(image) }
    }
}

final class ZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onTap: ((CGPoint?) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
        single.require(toFail: double)
        addGestureRecognizer(single)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ img: UIImage?) {
        imageView.image = img
        setZoomScale(1, animated: false)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale <= 1.001 {
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
            return
        }
        let p = g.location(in: imageView)
        let s: CGFloat = 2.5
        let size = CGSize(width: bounds.width / s, height: bounds.height / s)
        zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height),
             animated: true)
    }

    @objc private func singleTapped(_ g: UITapGestureRecognizer) {
        guard let img = imageView.image, img.size.width > 0, img.size.height > 0 else {
            onTap?(nil)
            return
        }
        let p = g.location(in: imageView)
        let b = imageView.bounds
        let scale = min(b.width / img.size.width, b.height / img.size.height)
        let fit = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let origin = CGPoint(x: (b.width - fit.width) / 2, y: (b.height - fit.height) / 2)
        let x = (p.x - origin.x) / scale * img.scale
        let y = (p.y - origin.y) / scale * img.scale
        if x < 0 || y < 0 || x > img.size.width * img.scale || y > img.size.height * img.scale {
            onTap?(nil)
        } else {
            onTap?(CGPoint(x: x, y: y))
        }
    }
}

/// 말풍선 하나: 원문, 번역 고치기, 다른 표현, 원문 그대로 두기
struct BlockSheet: View {
    let bookID: String
    let target: BlockTarget
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var translator: Translator
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var hidden = false
    @State private var alternatives: [String] = []
    @State private var loading = false
    @State private var altError: String?
    @State private var loaded = false

    private var page: PageRecord? { library.page(bookID, target.page) }
    private var block: PageAnswer.Block? {
        guard let a = page?.answer, target.index < a.blocks.count else { return nil }
        return a.blocks[target.index]
    }

    var body: some View {
        NavigationStack {
            TermPage(path: "bubble") {
                if let block {
                    TermBlock(label: "source · \(block.kind)") {
                        Text(block.source)
                            .font(Term.mono(15))
                            .foregroundStyle(Term.text)
                            .textSelection(.enabled)
                        if !block.note.isEmpty {
                            Text("※ " + block.note).font(Term.mono(12)).foregroundStyle(Term.amber)
                        }
                    }
                    TermBlock(label: "translation") {
                        TextEditor(text: $text)
                            .font(Term.mono(15))
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)
                            .background(Term.bg)
                        if text != block.translation {
                            Button { text = block.translation } label: { Label("Claude 번역으로 되돌리기", systemImage: "arrow.uturn.backward") }
                                .buttonStyle(.term)
                        }
                        Toggle(isOn: $hidden) {
                            Text("이 말풍선은 원문 그대로 두기").font(Term.mono(13))
                        }
                        .tint(Term.green)
                    }
                    TermBlock(label: "alternatives") {
                        Button {
                            Task { await loadAlternatives(block) }
                        } label: {
                            Label(alternatives.isEmpty ? "다른 표현 3개 받기" : "다시 받기", systemImage: "sparkles")
                        }
                        .buttonStyle(.term)
                        .disabled(loading)
                        if loading { StatusLine(kind: .running, text: "Claude가 고르는 중") }
                        if let altError { StatusLine(kind: .error, text: altError) }
                        ForEach(alternatives, id: \.self) { alt in
                            Button { text = alt } label: {
                                Text(alt)
                                    .font(Term.mono(14))
                                    .foregroundStyle(text == alt ? Term.green : Term.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(Term.bg, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(text == alt ? Term.green : Term.border))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button { save(block) } label: { Label("저장하고 다시 그리기", systemImage: "checkmark") }
                        .buttonStyle(.termPrimary)
                } else {
                    Text("말풍선을 찾지 못했어요").font(Term.mono(14)).foregroundStyle(Term.muted)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.font(Term.mono(14)) }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            guard !loaded, let block, let page else { return }
            loaded = true
            let e = page.edits[String(target.index)]
            text = e?.translation ?? block.translation
            hidden = e?.hidden ?? false
        }
    }

    private func loadAlternatives(_ block: PageAnswer.Block) async {
        guard let key = Keychain.apiKey else {
            altError = "설정에서 API 키를 넣어 주세요"
            return
        }
        loading = true
        altError = nil
        defer { loading = false }
        do {
            let ctx = library.context(book: bookID, page: target.page)
            let (alts, usage) = try await ClaudeClient.alternatives(
                source: block.source, current: text, kind: block.blockKind, context: ctx,
                summary: page?.answer?.page_summary ?? "", apiKey: key)
            alternatives = alts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            library.update(book: bookID, page: target.page) { $0.usage = $0.usage + usage }
            library.updateBook(bookID) { $0.usage = $0.usage + usage }
        } catch {
            altError = ClaudeClient.map(error).localizedDescription
        }
    }

    private func save(_ block: PageAnswer.Block) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        library.update(book: bookID, page: target.page) { rec in
            let edit = BlockEdit(translation: trimmed == block.translation ? nil : trimmed, hidden: hidden)
            rec.edits[String(target.index)] = edit.translation == nil && !edit.hidden ? nil : edit
        }
        let book = bookID, page = target.page
        Task { await translator.repaint(book: book, page: page) }
        dismiss()
    }
}
