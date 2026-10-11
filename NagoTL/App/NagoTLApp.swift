import NagoTLCore
import SwiftUI
import UIKit

@main
struct NagoTLApp: App {
    @StateObject private var library = Library.shared
    @StateObject private var translator = Translator.shared
    @StateObject private var router = Router()

    init() {
        // 탭 바도 터미널 배경색 + 고정폭 글꼴(NAGO VPN·DL과 같은 모양)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Term.bg)
        appearance.shadowColor = UIColor(Term.border)
        let font = Term.uiMono(11, .semibold)
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance,
                     appearance.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [.font: font, .foregroundColor: UIColor(Term.muted)]
            item.normal.iconColor = UIColor(Term.muted)
            item.selected.titleTextAttributes = [.font: font, .foregroundColor: UIColor(Term.green)]
            item.selected.iconColor = UIColor(Term.green)
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Term.bg)
        nav.shadowColor = UIColor(Term.border)
        nav.titleTextAttributes = [.font: Term.uiMono(15, .semibold), .foregroundColor: UIColor(Term.text)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(translator)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // 다른 앱의 "공유 → NAGO TL"/"다음으로 열기"로 받은 파일
                    Task { @MainActor in
                        let ids = await Importer.importFiles([url])
                        // 받은 편지함(Documents/Inbox)에 복사된 건 가져온 뒤 지운다
                        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
                        if let id = ids.first {
                            router.tab = .library
                            router.path = [id]
                        }
                    }
                }
        }
    }
}

/// 탭·화면 이동
@MainActor
final class Router: ObservableObject {
    enum Tab: Hashable { case library, photo, settings }

    @Published var tab: Tab = .library
    /// 서재 탭의 내비게이션 경로(책 ID)
    @Published var path: [String] = []
    /// 열려 있는 뷰어
    @Published var reader: ReaderTarget?
}

struct ReaderTarget: Identifiable, Equatable {
    let book: String
    let start: Int
    var id: String { "\(book)#\(start)" }
}

struct RootView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var router: Router

    var body: some View {
        TabView(selection: $router.tab) {
            NavigationStack(path: $router.path) {
                LibraryView()
                    .navigationDestination(for: String.self) { id in BookView(bookID: id) }
            }
            .tabItem { Label("library", systemImage: "books.vertical") }
            .tag(Router.Tab.library)

            NavigationStack {
                PhotoView()
            }
            .tabItem { Label("photo", systemImage: "camera.viewfinder") }
            .tag(Router.Tab.photo)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("settings", systemImage: "gearshape") }
            .tag(Router.Tab.settings)
        }
        .tint(Term.green)
        .fullScreenCover(item: $router.reader) { target in
            ReaderView(bookID: target.book, start: target.start)
                .environmentObject(library)
                .environmentObject(Translator.shared)
                .environmentObject(router)
        }
        .overlay(alignment: .bottom) {
            if let toast = library.toast {
                Text(toast)
                    .font(Term.mono(13))
                    .foregroundStyle(Term.text)
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Term.chrome, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { library.toast = nil }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: library.toast)
    }
}

/// 목록에 쓰는 작은 그림(파일에서 읽어 둔다)
struct ThumbView: View {
    let url: URL
    var version = 0
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Term.surface
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(Term.muted)
            }
        }
        .clipped()
        .task(id: "\(url.path)#\(version)") {
            let u = url
            image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: u.path) }.value
        }
    }
}

extension Usage {
    var costText: String { String(format: "$%.2f", dollars) }
}
