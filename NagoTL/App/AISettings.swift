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
    static func modelKey(_ p: Provider) -> String { "tl.ai.\(p.rawValue).model" }
    static func premiumKey(_ p: Provider) -> String { "tl.ai.\(p.rawValue).premium" }
    static func baseKey(_ p: Provider) -> String { "tl.ai.\(p.rawValue).base" }
    static func freeKey(_ p: Provider) -> String { "tl.ai.\(p.rawValue).free" }

    /// 기본 AI(처음엔 Claude)
    static var primary: Provider {
        Provider(rawValue: UserDefaults.standard.string(forKey: primaryKey) ?? "") ?? .claude
    }

    /// 기본 AI가 실패·거절하면 이걸로 한 번 더(없으면 nil)
    static var fallback: Provider? {
        guard let p = Provider(rawValue: UserDefaults.standard.string(forKey: fallbackKey) ?? ""), p != primary else {
            return nil
        }
        return p
    }

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

    /// 이번 번역에 쓸 순서(키가 있는 것만): 기본 → 대체
    static func routes(tier: ClaudeAPI.Engine) -> [KeyedRoute] {
        var order = [primary]
        if let f = fallback { order.append(f) }
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

    /// 한 쪽 어림 비용(기본 AI, 기본/고급)
    static func estimatedPageCost(tier: ClaudeAPI.Engine = .standard) -> Double {
        route(primary, tier: tier).estimatedPageCost
    }
}
