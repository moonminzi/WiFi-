import Foundation
import SwiftUI
import UIKit
import UserNotifications
import NagoDLCore

/// 화면과 엔진 사이. 엔진(DownloadManager)은 자기 큐에서 돌고, 바뀐 목록을 메인 스레드로 보내 준다.
@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    @Published private(set) var items: [DownloadSnapshot] = []
    /// 화면 아래에 잠깐 띄울 말
    @Published var toast: String?

    let manager: DownloadManager
    let background: BackgroundTransfer
    private var wasActive = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        Pref.registerDefaults()
        manager = DownloadManager(paths: .standard(), settings: Pref.engineSettings())
        background = BackgroundTransfer(manager: manager)
        manager.onSnapshots = { [weak self] snaps in
            MainActor.assumeIsolated { self?.items = snaps }
        }
        manager.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        manager.onCancelExternal = { [weak self] id in
            MainActor.assumeIsolated { self?.background.cancel(download: id) }
        }
        manager.load()
        background.activate(allowsCellular: UserDefaults.standard.bool(forKey: Pref.cellular))
    }

    // MARK: 동작

    func add(_ download: NewDownload) {
        manager.add(download)
        Notifier.requestPermissionIfNeeded()
    }

    func pause(_ id: UUID) { manager.pause(id) }
    func resume(_ id: UUID) { manager.resume(id) }
    func remove(_ id: UUID, deleteFile: Bool) { manager.remove(id, deleteFile: deleteFile) }
    func rename(_ id: UUID, to name: String) { manager.rename(id, to: name) }
    func updateURL(_ id: UUID, url: URL) { manager.updateURL(id, url: url) }
    func clearCompleted() { manager.clearCompleted() }
    func pauseAll() { manager.pauseAll() }
    func resumeAll() { manager.resumeAll() }

    func applySettings() {
        manager.update(settings: Pref.engineSettings())
    }

    func item(_ id: UUID) -> DownloadSnapshot? {
        items.first { $0.id == id }
    }

    var activeCount: Int { items.filter { $0.status == .running }.count }
    var totalSpeed: Double { items.reduce(0) { $0 + $1.speed } }

    func show(_ message: String) {
        toast = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if self?.toast == message { self?.toast = nil }
        }
    }

    private func handle(_ event: DownloadEvent) {
        let active = UIApplication.shared.applicationState == .active
        switch event {
        case .completed(_, let name):
            if active { show("✓ \(name)") } else { Notifier.post(title: "다운로드 완료", body: name) }
        case .failed(_, let name, let message):
            if active { show("✗ \(name): \(message)") } else { Notifier.post(title: "다운로드 실패", body: "\(name) — \(message)") }
        }
    }

    // MARK: 앱 생명주기

    /// 화면에 나왔다: 아직 시작 안 한 백그라운드 작업을 되찾고 여러 연결로 다시 받는다.
    func becameActive() {
        wasActive = true
        endBackgroundTask()
        background.setForeground(true)
        let manager = self.manager
        background.reclaimUnstarted {
            manager.resumeForeground()
        }
    }

    /// 화면에서 내려가기 직전(비활성). 여기서 넘겨야 작업이 "앱이 앞에 있을 때 만든 것"이 되어
    /// 시스템이 미루지 않고 바로 받는다(백그라운드에서 만든 작업은 시스템 재량으로 늦어질 수 있다).
    func willResignActive() {
        guard wasActive else { return }
        wasActive = false
        guard UserDefaults.standard.bool(forKey: Pref.background) else { return }
        let jobs = manager.detachForBackground()
        background.enqueue(jobs)
    }

    func didEnterBackground() {
        background.setForeground(false)
        // 넘기지 못한 것(이어받기 안 되는 서버 등)을 위해 몇십 초 더 달라고 한다
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "nago.dl") { [weak self] in
                MainActor.assumeIsolated {
                    self?.manager.persistAndStop()
                    self?.endBackgroundTask()
                }
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

/// 완료 알림(앱이 화면에 없을 때만)
enum Notifier {
    static func requestPermissionIfNeeded() {
        guard UserDefaults.standard.bool(forKey: Pref.notify) else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: Pref.notify) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// 다른 화면에서 "이 링크 받기" / "브라우저로 열기"를 요청할 때
struct AddRequest: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var pageURL: URL?
    var headers: [String: String] = [:]
    var suggestedName: String?
    var autoProbe = true
}

@MainActor
final class Router: ObservableObject {
    enum Tab: Hashable { case downloads, browser, settings }

    @Published var tab: Tab = .downloads
    @Published var addRequest: AddRequest?
    /// 브라우저 탭에서 열 주소
    @Published var browse: URL?
    /// 클립보드에 링크가 새로 들어옴(붙여넣기 단추를 보여 준다)
    @Published var clipboardHasLink = false

    /// nagodl://add?url=... (공유 확장, 단축어)
    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "nagodl" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let target = items.first { $0.name == "url" }?.value ?? ""
        switch url.host?.lowercased() {
        case "open", "browse":
            if let u = URL(string: target) {
                browse = u
                tab = .browser
            }
        default:
            tab = .downloads
            addRequest = AddRequest(text: target)
        }
    }

    func openAdd(_ request: AddRequest) {
        addRequest = request
    }

    func openInBrowser(_ url: URL) {
        browse = url
        tab = .browser
    }

    /// 앱으로 돌아올 때: 클립보드에 새 링크가 있는지(내용은 안 읽어서 붙여넣기 허용 창이 안 뜬다)
    func checkClipboard() {
        guard UserDefaults.standard.bool(forKey: Pref.clipboard) else {
            clipboardHasLink = false
            return
        }
        let board = UIPasteboard.general
        let seen = UserDefaults.standard.integer(forKey: Pref.lastPasteboard)
        clipboardHasLink = board.changeCount != seen && (board.hasURLs || board.hasStrings)
    }

    func clipboardHandled() {
        UserDefaults.standard.set(UIPasteboard.general.changeCount, forKey: Pref.lastPasteboard)
        clipboardHasLink = false
    }
}
