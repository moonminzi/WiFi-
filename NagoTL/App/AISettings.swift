import Foundation
import NagoTLCore

/// 키를 붙인 AI(이번 번역에 쓸 것)
struct KeyedRoute: Sendable {
    let route: AIRoute
    let key: String
}

/// 번역 AI 고르기(설정 탭). 키는 키체인, 나머지는 UserDefaults
enum AISettings {
    static let primaryKey = "tl.ai.primary"
    static let fallbackKey = "tl.ai.fallback"
    static let retryKey = "tl.ai.retryMissing"
    /// 대체 AI 설정값: 자동 = 키를 넣은 다른 AI 아무거나, "" = 쓰지 않음
    static let autoFallback = "auto"
    static func modelKey(_ p: Provider) -> String { "tl.ai.\(p.rawValue).model" }
    static func premiumKey(_ p: Provider) -> String { "tl.ai.\(p.rawValue).premium" }
    static func baseKey(_ p: Provider) -> String { "tl.ai.\(p.rawValue).base" }
    static func freeKey(_ p: Provider) -> String { "tl.ai.\(p.rawValue).free" }

    /// 기본 AI(처음엔 Claude)
    static var primary: Provider {
        Provider(rawValue: UserDefaults.standard.string(forKey: primaryKey) ?? "") ?? .claude
    }

    /// 기본 AI가 실패·거절하면, 또 번역이 안 들어간 곳이 있으면 이걸로 한 번 더(없으면 nil).
    /// 처음엔 자동: 키를 넣어 둔 다른 AI(Gemini 키를 넣어 두기만 하면 따로 고르지 않아도 쓴다)
    static var fallback: Provider? {
        let saved = UserDefaults.standard.string(forKey: fallbackKey) ?? autoFallback
        if saved == autoFallback {
            return Provider.allCases.first { $0 != primary && !(Keychain.key($0) ?? "").isEmpty }
        }
        guard let p = Provider(rawValue: saved), p != primary else { return nil }
        return p
    }

    /// 번역했는데 그림에 안 들어간 곳이 있으면 대체 AI로 그 쪽을 한 번 더 받아 채울지(처음엔 켬)
    static var retryMissing: Bool { UserDefaults.standard.object(forKey: retryKey) as? Bool ?? true }

    /// 기본/고급 모델 이름(Claude는 Haiku/Opus 고정, 나머지는 설정값, 비었으면 기본값)
    static func model(_ p: Provider, tier: ClaudeAPI.Engine) -> String {
        if p == .claude { return tier.model }
        let saved = UserDefaults.standard.string(forKey: tier == .premium ? premiumKey(p) : modelKey(p)) ?? ""
        let v = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? (tier == .premium ? p.defaultPremiumModel : p.defaultModel) : v
    }

    static func route(_ p: Provider, tier: ClaudeAPI.Engine) -> AIRoute {
        AIRoute(provider: p, model: model(p, tier: tier), baseURL: UserDefaults.standard.string(forKey: baseKey(p)),
                freeTier: UserDefaults.standard.bool(forKey: freeKey(p)))
    }

    /// 이번 번역에 쓸 순서(키가 있는 것만): 기본 → 대체. first를 주면 그 AI부터(읽기 화면의 "다른 AI로 다시 번역")
    static func routes(tier: ClaudeAPI.Engine, first: Provider? = nil) -> [KeyedRoute] {
        var order = [primary]
        if let f = fallback { order.append(f) }
        if let first {
            order.removeAll { $0 == first }
            order.insert(first, at: 0)
        }
        return order.compactMap { p in
            guard let k = Keychain.key(p), !k.isEmpty else { return nil }
            return KeyedRoute(route: route(p, tier: tier), key: k)
        }
    }

    /// 번역할 수 있는가(키가 있는 AI가 하나라도)
    static var ready: Bool { !routes(tier: .standard).isEmpty }

    /// 화면에 보일 이름
    static func displayName(_ p: Provider, tier: ClaudeAPI.Engine) -> String {
        p == .claude ? tier.label : model(p, tier: tier)
    }

    /// 키를 넣어 둔 AI들(읽기 화면에서 "이 AI로 다시 번역"을 보여 줄 것)
    static var keyed: [Provider] { Provider.allCases.filter { !(Keychain.key($0) ?? "").isEmpty } }

    /// 한 쪽 어림 비용(기본 AI, 기본/고급)
    static func estimatedPageCost(tier: ClaudeAPI.Engine = .standard) -> Double {
        route(primary, tier: tier).estimatedPageCost
    }
}
