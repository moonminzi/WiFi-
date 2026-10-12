import NagoTLCore
import SwiftUI

/// 설정 탭의 번역 AI 고르기: 기본 AI, 막히면 쓸 대체 AI, AI마다 키·모델·주소
struct AISection: View {
    @AppStorage(AISettings.primaryKey) private var primary: Provider = .claude
    @AppStorage(AISettings.fallbackKey) private var fallback = AISettings.autoFallback
    @AppStorage(AISettings.retryKey) private var retryMissing = true
    @State private var editing: Provider = AISettings.primary

    var body: some View {
        TermBlock(label: "translate ai") {
            Text("기본 AI").font(Term.mono(12)).foregroundStyle(Term.key)
            TermChoice(options: primaryOptions, selection: $primary)
            Text("막히면 다시 할 AI(거절·오류일 때)").font(Term.mono(12)).foregroundStyle(Term.key)
            TermChoice(options: fallbackOptions, selection: $fallback)
            Toggle(isOn: $retryMissing) {
                Text("번역이 그림에 안 들어간 곳이 있으면 이 AI로 그 쪽을 한 번 더 받아 빈자리만 채우기")
                    .font(Term.mono(12))
                    .foregroundStyle(Term.text)
            }
            .tint(Term.green)
            TermDivider()
            Text("AI별 설정").font(Term.mono(12)).foregroundStyle(Term.key)
            TermChoice(options: editOptions, selection: $editing)
            ProviderConfigView(provider: editing)
                .id(editing)
        }
        .onChange(of: primary) { _, p in
            // 기본과 같은 걸 대체로 둘 수는 없다
            if fallback == p.rawValue { fallback = AISettings.autoFallback }
            editing = p
        }
    }
}

extension AISection {
    var primaryOptions: [(label: String, value: Provider)] {
        Provider.allCases.map { p in (label: p.label, value: p) }
    }

    var fallbackOptions: [(label: String, value: String)] {
        var out: [(label: String, value: String)] = [(label: "자동", value: AISettings.autoFallback), (label: "없음", value: "")]
        for p in Provider.allCases where p != primary { out.append((label: p.label, value: p.rawValue)) }
        return out
    }

    /// 키를 넣은 AI는 ✓
    var editOptions: [(label: String, value: Provider)] {
        Provider.allCases.map { p in
            let mark = Keychain.key(p) == nil ? "" : " ✓"
            return (label: p.label + mark, value: p)
        }
    }
}

/// AI 하나의 키·모델·주소
struct ProviderConfigView: View {
    let provider: Provider
    @AppStorage private var model: String
    @AppStorage private var premium: String
    @AppStorage private var base: String
    @AppStorage private var free: Bool
    @State private var key = ""
    @State private var saved: String?
    @State private var checking = false
    @State private var check: (ok: Bool, text: String)? = nil
    @State private var models: [String] = []
    @State private var loadingModels = false

    init(provider: Provider) {
        self.provider = provider
        _model = AppStorage(wrappedValue: "", AISettings.modelKey(provider))
        _premium = AppStorage(wrappedValue: "", AISettings.premiumKey(provider))
        _base = AppStorage(wrappedValue: "", AISettings.baseKey(provider))
        _free = AppStorage(wrappedValue: false, AISettings.freeKey(provider))
        _saved = State(initialValue: Keychain.key(provider))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let saved {
                StatusLine(kind: .ok, text: "키 저장됨 · …" + String(saved.suffix(6)))
            } else {
                StatusLine(kind: .warn, text: "키가 없어요")
            }
            TermField(key: "key", text: $key, placeholder: placeholder, secure: true)
            HStack(spacing: 8) {
                Button {
                    Keychain.setKey(key, for: provider)
                    saved = Keychain.key(provider)
                    key = ""
                    Task { await verify() }
                } label: { Label("저장", systemImage: "key") }
                    .buttonStyle(TermButtonStyle(kind: .primary))
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { Task { await verify() } } label: { Label("확인", systemImage: "checkmark.shield") }
                    .buttonStyle(.term)
                    .disabled(saved == nil || checking)
                if saved != nil {
                    Button {
                        Keychain.setKey(nil, for: provider)
                        saved = nil
                        check = nil
                    } label: { Label("지우기", systemImage: "trash") }
                        .buttonStyle(.termDanger)
                }
            }
            if checking { StatusLine(kind: .running, text: "확인 중") }
            if let check { StatusLine(kind: check.ok ? .ok : .error, text: check.text) }

            if provider == .claude {
                Text("기본 Claude Haiku 5.5 · 고급 Claude Opus 5.5")
                    .font(Term.mono(12))
                    .foregroundStyle(Term.text)
            } else {
                if provider == .openai {
                    TermField(key: "url", text: $base, placeholder: provider.defaultBaseURL, keyboard: .URL)
                    HStack(spacing: 6) {
                        ForEach(Self.presets.indices, id: \.self) { i in
                            Button(Self.presets[i].label) {
                                base = Self.presets[i].url
                                models = []
                            }
                            .buttonStyle(.term)
                        }
                    }
                }
                TermField(key: "model", text: $model, placeholder: provider.defaultModel)
                TermField(key: "pro", text: $premium, placeholder: provider.defaultPremiumModel)
                HStack(spacing: 8) {
                    Button { Task { await loadModels() } } label: { Label("모델 목록", systemImage: "list.bullet") }
                        .buttonStyle(.term)
                        .disabled(saved == nil || loadingModels)
                    if !models.isEmpty {
                        Menu {
                            ForEach(models, id: \.self) { m in Button(m) { model = m } }
                        } label: { Label("기본", systemImage: "chevron.down") }
                            .buttonStyle(.term)
                        Menu {
                            ForEach(models, id: \.self) { m in Button(m) { premium = m } }
                        } label: { Label("고급", systemImage: "chevron.down") }
                            .buttonStyle(.term)
                    }
                }
                if loadingModels { StatusLine(kind: .running, text: "모델 불러오는 중") }
                Toggle(isOn: $free) {
                    Text("무료 등급 키(쓴 돈을 0으로 셈)").font(Term.mono(12)).foregroundStyle(Term.text)
                }
                .tint(Term.green)
                Text(costLine)
                    .font(Term.mono(11.5))
                    .foregroundStyle(Term.muted)
            }
            Text(help)
                .font(Term.mono(11.5))
                .foregroundStyle(Term.muted)
        }
    }

    static let presets: [(label: String, url: String)] = [
        ("OpenAI", "https://api.openai.com/v1"),
        ("OpenRouter", "https://openrouter.ai/api/v1"),
        ("xAI", "https://api.x.ai/v1"),
    ]

    private var costLine: String {
        let standard = Usage.money(AISettings.route(provider, tier: .standard).estimatedPageCost)
        let premium = Usage.money(AISettings.route(provider, tier: .premium).estimatedPageCost)
        return "한 쪽 어림 \(standard) · 고급 \(premium)"
    }

    private var placeholder: String {
        switch provider {
        case .claude: "sk-ant-…"
        case .gemini: "AIza…"
        case .openai: "sk-…"
        }
    }

    private var help: String {
        switch provider {
        case .claude:
            "console.anthropic.com → API Keys에서 만들어요."
        case .gemini:
            "aistudio.google.com → Get API key에서 만들어요(무료 등급이 있어요 — 하루 쓸 수 있는 양이 정해져 있음). "
                + "만화의 싸움·노출 장면 때문에 막히지 않게 조정할 수 있는 안전 필터는 꺼서 보내요."
        case .openai:
            "OpenAI(platform.openai.com), OpenRouter(openrouter.ai — 키 하나로 여러 회사 모델, 그림 읽는 모델만 목록에), "
                + "xAI(console.x.ai)처럼 OpenAI 방식 API면 주소만 바꿔 쓰면 돼요. 그림을 읽는 모델이어야 해요."
        }
    }

    private func verify() async {
        guard let k = Keychain.key(provider) else { return }
        checking = true
        check = nil
        let err = await AIClient.checkKey(provider, key: k, baseURL: base)
        checking = false
        check = err == nil ? (true, "키가 맞아요") : (false, err ?? "")
    }

    private func loadModels() async {
        guard let k = Keychain.key(provider) else { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            models = try await AIClient.models(provider, key: k, baseURL: base)
            check = models.isEmpty ? (false, "쓸 수 있는 모델이 없어요") : (true, "모델 \(models.count)개")
        } catch {
            check = (false, ClaudeClient.map(error).localizedDescription)
        }
    }
}
