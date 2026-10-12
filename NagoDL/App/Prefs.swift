import Foundation
import NagoDLCore

/// 설정 값(UserDefaults 키와 기본값)
enum Pref {
    static let connections = "dl.connections"
    static let maxActive = "dl.maxActive"
    static let cellular = "dl.cellular"
    static let background = "dl.background"
    static let clipboard = "dl.clipboard"
    static let notify = "dl.notify"
    static let desktopMode = "dl.desktopMode"
    static let search = "dl.search"
    static let home = "dl.home"
    static let lastPasteboard = "dl.lastPasteboard"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            connections: 8,
            maxActive: 3,
            cellular: true,
            background: true,
            clipboard: true,
            notify: true,
            desktopMode: false,
            search: SearchEngine.google.rawValue,
            home: "https://www.google.com",
        ])
    }

    static func engineSettings(_ d: UserDefaults = .standard) -> EngineSettings {
        EngineSettings(defaultConnections: max(1, min(32, d.integer(forKey: connections))),
                       maxActiveDownloads: max(1, min(10, d.integer(forKey: maxActive))),
                       allowsCellular: d.bool(forKey: cellular))
    }
}

enum SearchEngine: String, CaseIterable {
    case google, naver, duckduckgo

    var label: String {
        switch self {
        case .google: "google"
        case .naver: "naver"
        case .duckduckgo: "ddg"
        }
    }

    func url(_ query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .google: return URL(string: "https://www.google.com/search?q=\(q)")
        case .naver: return URL(string: "https://search.naver.com/search.naver?query=\(q)")
        case .duckduckgo: return URL(string: "https://duckduckgo.com/?q=\(q)")
        }
    }

    static var current: SearchEngine {
        SearchEngine(rawValue: UserDefaults.standard.string(forKey: Pref.search) ?? "") ?? .google
    }
}
