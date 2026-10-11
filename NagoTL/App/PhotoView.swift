import NagoTLCore
import PhotosUI
import SwiftUI

/// 실제 사진(간판·메뉴·안내문·상품 등) 한 장 번역
struct PhotoView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var translator: Translator
    @EnvironmentObject private var router: Router
    @State private var camera = false
    @State private var picked: PhotosPickerItem?
    @State private var busy = false

    var body: some View {
        let bookID = library.books.first(where: { $0.kind == .photos })?.id
        let pages = bookID.map { library.pageList($0) } ?? []
        TermPage(path: "photo") {
            TermBlock(label: "translate a photo") {
                Text("간판·메뉴·안내문·상품 설명 같은 실제 사진의 글자를 한국어로 바꿔 그 자리에 그려요. 망가 한 쪽을 찍어도 돼요.")
                    .font(Term.mono(12))
                    .foregroundStyle(Term.muted)
                HStack(spacing: 8) {
                    if CameraPicker.available {
                        Button { camera = true } label: { Label("찍기", systemImage: "camera") }
                            .buttonStyle(TermButtonStyle(kind: .primary, fill: true))
                    }
                    PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                        Label("앨범에서", systemImage: "photo")
                    }
                    .buttonStyle(TermButtonStyle(kind: CameraPicker.available ? .secondary : .primary, fill: true))
                }
                if busy { StatusLine(kind: .running, text: "준비 중") }
                if Keychain.apiKey == nil { StatusLine(kind: .warn, text: "설정 탭에서 Claude API 키를 먼저 넣어 주세요") }
            }
            if let bookID, !pages.isEmpty {
                TermBlock(label: "recent (\(pages.count))") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 10) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { i, p in
                            PageCell(bookID: bookID, page: p, number: i + 1)
                                .onTapGesture { router.reader = ReaderTarget(book: bookID, start: i) }
                                .contextMenu {
                                    Button(role: .destructive) { library.deletePages(book: bookID, ids: [p.id]) } label: {
                                        Label("삭제", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { data in Task { await add(data) } }
                .ignoresSafeArea()
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                busy = true
                defer { busy = false }
                if let data = try? await item.loadTransferable(type: Data.self) { await add(data) }
            }
        }
    }

    private func add(_ data: Data) async {
        let id = library.photosBookID()
        let ids = await Importer.importImages([data], book: id, atFront: true)
        guard let page = ids.first else { return library.show("사진을 저장하지 못했어요") }
        if Keychain.apiKey != nil { translator.enqueue(book: id, pages: [page], front: true) }
        router.reader = ReaderTarget(book: id, start: 0)
    }
}
