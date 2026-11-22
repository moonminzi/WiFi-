import Foundation

/// 앱 안(PlugIns)에 실제로 들어 있는 Safari 콘텐츠 차단기(WifiScanBlocker)를 찾는다.
/// 재서명하면 번들 ID가 바뀌므로(도구마다 붙이는 방식이 다름) 추측하지 않고 확장 폴더를 직접 본다.
/// 앱에서도, Safari 웹 확장(같은 PlugIns 폴더)에서도 쓴다.
enum BlockerLocator {
    struct Info: Decodable {
        let rules: Int
        let lists: String
        let built: String
    }

    /// PlugIns 폴더: 앱이면 Bundle.main.builtInPlugInsURL, 확장이면 자기 .appex의 옆
    static var pluginsURL: URL? {
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return Bundle.main.bundleURL.deletingLastPathComponent()
        }
        return Bundle.main.builtInPlugInsURL
    }

    /// 콘텐츠 차단기 확장의 번들
    static var blockerBundle: Bundle? {
        guard let dir = pluginsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        for url in items where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url),
                  let ext = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                  ext["NSExtensionPointIdentifier"] as? String == "com.apple.Safari.content-blocker"
            else { continue }
            return bundle
        }
        return nil
    }

    static var identifier: String? { blockerBundle?.bundleIdentifier }

    static var info: Info? {
        guard let url = blockerBundle?.url(forResource: "BlockerInfo", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }
}
