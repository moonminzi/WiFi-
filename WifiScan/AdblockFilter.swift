import Foundation

/// 내 광고 차단 설정: 강도(light · normal · strict)와 내 규칙(나만 막기 · 나만 풀기).
/// 폰에 저장하고, VPN에 붙어 있으면 서버 nago-agent(POST /v1/dns)에 보낸다 — 서버는 터널 주소로
/// 이 폰만 그렇게 걸러 준다(같은 서버의 다른 사람은 그대로). 서버가 다시 켜지거나 다른 서버에 붙어도
/// 다음 refresh 때 다시 맞춘다
enum AdblockFilter {
    enum Level: String, CaseIterable {
        case light, normal, strict

        var note: String {
            switch self {
            case .light: return "ads only · fewest broken sites"
            case .normal: return "ads + trackers + korean ads + pop-up redirects"
            case .strict: return "+ more trackers · may break some sites"
            }
        }
    }

    enum Key {
        static let level = "dnsLevel"
        static let block = "dnsBlock"
        static let allow = "dnsAllow"
    }

    /// 서버도 500개까지만 받는다
    static let maxRules = 500

    struct Value: Equatable {
        var level: Level
        var block: [String]
        var allow: [String]

        var json: [String: Any] { ["level": level.rawValue, "block": block, "allow": allow] }
    }

    static var current: Value {
        let d = UserDefaults.standard
        return Value(level: Level(rawValue: d.string(forKey: Key.level) ?? "") ?? .normal,
                     block: list(Key.block), allow: list(Key.allow))
    }

    static func list(_ key: String) -> [String] {
        (UserDefaults.standard.string(forKey: key) ?? "").split(separator: "\n").map(String.init)
    }

    private static func save(_ key: String, _ items: [String]) {
        UserDefaults.standard.set(items.joined(separator: "\n"), forKey: key)
    }

    /// 나만 막기(풀기 목록에 있으면 거기서 뺀다)
    static func block(_ domain: String) {
        guard let d = clean(domain) else { return }
        save(Key.allow, list(Key.allow).filter { $0 != d })
        save(Key.block, Array((list(Key.block).filter { $0 != d } + [d]).suffix(maxRules)).sorted())
    }

    /// 나만 풀기(막기 목록에 있으면 거기서 뺀다)
    static func allow(_ domain: String) {
        guard let d = clean(domain) else { return }
        save(Key.block, list(Key.block).filter { $0 != d })
        save(Key.allow, Array((list(Key.allow).filter { $0 != d } + [d]).suffix(maxRules)).sorted())
    }

    static func remove(_ domain: String) {
        save(Key.block, list(Key.block).filter { $0 != domain })
        save(Key.allow, list(Key.allow).filter { $0 != domain })
    }

    /// 이 도메인에 걸린 내 규칙: "block" · "allow" · nil
    static func rule(for domain: String) -> String? {
        if list(Key.allow).contains(domain) { return "allow" }
        if list(Key.block).contains(domain) { return "block" }
        return nil
    }

    private static let domainPattern = #"^(?=.{1,253}$)([a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?\.)+[a-z0-9-]{2,63}$"#

    /// "https://Ads.Example.com/x" → "ads.example.com". 이상하면 nil
    static func clean(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        s = String(s.prefix { $0 != "/" && $0 != ":" && $0 != "?" })
        while s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix("*.") { s.removeFirst(2) }
        // 서버(nago-agent DOMAIN_RE)와 같은 규칙 — 다르면 서버가 버려서 계속 다시 보내게 된다
        let ok = s.range(of: Self.domainPattern, options: .regularExpression) != nil
        return ok ? s : nil
    }
}
