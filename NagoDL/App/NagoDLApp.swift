import SwiftUI
import UIKit

@main
struct NagoDLApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DownloadStore.shared
    @StateObject private var router = Router()
    @Environment(\.scenePhase) private var phase

    init() {
        // 탭 바도 터미널 배경색 + 고정폭 글꼴(NAGO VPN과 같은 모양)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        // Term 색은 다크·라이트 두 벌이다. 이 앱은 다크로 고정(.preferredColorScheme(.dark))이라 다크 쪽으로 보인다.
        appearance.backgroundColor = Term.UI.bg
        appearance.shadowColor = Term.UI.border
        let font = Term.uiMono(11, .semibold)
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [.font: font, .foregroundColor: Term.UI.muted]
            item.normal.iconColor = Term.UI.muted
            item.selected.titleTextAttributes = [.font: font, .foregroundColor: Term.UI.green]
            item.selected.iconColor = Term.UI.green
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(router)
                .onOpenURL { router.handle($0) }
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .active:
                store.becameActive()
                router.checkClipboard()
            case .inactive:
                store.willResignActive()
            case .background:
                store.didEnterBackground()
            @unknown default:
                break
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 기록을 읽고 백그라운드 세션을 다시 잡는다(시스템이 백그라운드로 깨운 경우에도)
        _ = DownloadStore.shared
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadStore.shared.background.setEventsCompletion(completionHandler)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        DownloadStore.shared.manager.persistAndStop()
    }
}

struct RootView: View {
    @EnvironmentObject private var store: DownloadStore
    @EnvironmentObject private var router: Router

    var body: some View {
        TabView(selection: $router.tab) {
            DownloadsView()
                .tabItem { Label("downloads", systemImage: "arrow.down.circle") }
                .tag(Router.Tab.downloads)
            BrowserView()
                .tabItem { Label("browser", systemImage: "safari") }
                .tag(Router.Tab.browser)
            SettingsView()
                .tabItem { Label("settings", systemImage: "gearshape") }
                .tag(Router.Tab.settings)
        }
        .tint(Term.green)
        .sheet(item: $router.addRequest) { request in
            AddDownloadView(request: request)
                .environmentObject(store)
                .environmentObject(router)
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Text(toast)
                    .font(Term.mono(13))
                    .foregroundStyle(Term.text)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Term.chrome, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { store.toast = nil }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.toast)
    }
}
