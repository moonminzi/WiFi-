import SwiftUI

// 서버 nago-agent를 쓰는 vpn 탭 조각: 광고 차단 패널 · live 화면 · 출구(친구 집) 고르기

/// `// adblock 1,234 blocked · 6.5%` — 오늘(KST) 서버 광고 차단 DNS가 막은 것. 펴면 많이 막힌 도메인
struct AdblockPanel: View {
    let agent: NagoAgent
    /// 설정의 --adblock(서버 DNS를 쓰는지)
    let adblockOn: Bool
    @Binding var folded: Bool
    let openLive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !folded {
                content
                    .transition(.opacity)
            }
        }
        .padding(folded ? 10 : 12)
        .background(Term.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border, lineWidth: 1))
    }

    private var dns: NagoAgent.DNS? { agent.me?.dns }

    /// `normal` · `strict +3 rules` — 서버가 지금 이 폰에 쓰는 강도(설정 → adblock)
    private var strength: String {
        guard let f = agent.me?.filter else { return "normal" }
        let n = f.block.count + f.allow.count
        return n > 0 ? "\(f.level) +\(n) rule\(n == 1 ? "" : "s")" : f.level
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            FoldChevron(folded: folded)
            Text("// adblock").foregroundStyle(Term.muted)
            if folded, let dns {
                Text("\(Self.grouped(dns.blocked)) blocked").foregroundStyle(Term.green).monospacedDigit()
                Text("· \(Self.percent(dns.share))").foregroundStyle(Term.muted).monospacedDigit()
            } else if folded, !adblockOn {
                Text("off").foregroundStyle(Term.muted)
            }
            Spacer(minLength: 4)
            Button(action: openLive) {
                Text("live ▸")
                    .foregroundStyle(Term.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Term.green.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(dns == nil)
            .opacity(dns == nil ? 0.4 : 1)
            .accessibilityLabel("watch domains live")
        }
        .font(Term.mono(11))
        .lineLimit(1)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.3)) { folded.toggle() } }
        .accessibilityAction(named: folded ? "expand" : "collapse") { folded.toggle() }
    }

    @ViewBuilder
    private var content: some View {
        if let dns {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .lastTextBaseline, spacing: 18) {
                    figure(Self.grouped(dns.blocked), "blocked", Term.green)
                    figure(Self.grouped(dns.queries), "lookups", Term.num)
                    Spacer(minLength: 0)
                    Text(Self.percent(dns.share))
                        .font(Term.mono(20, .bold))
                        .foregroundStyle(Term.key)
                        .monospacedDigit()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Term.track)
                        Capsule().fill(Term.green.opacity(0.85))
                            .frame(width: max(3, geo.size.width * min(dns.share * 4, 1)))
                    }
                }
                .frame(height: 3)
                if !dns.top.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        let peak = max(dns.top.first?.n ?? 1, 1)
                        ForEach(dns.top.prefix(5)) { row in
                            HStack(spacing: 8) {
                                Text("✗").foregroundStyle(Term.red)
                                Text(row.domain).foregroundStyle(Term.text).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                Capsule().fill(Term.red.opacity(0.5))
                                    .frame(width: 40 * CGFloat(row.n) / CGFloat(peak), height: 3)
                                Text("\(row.n)").foregroundStyle(Term.muted).monospacedDigit()
                                    .frame(minWidth: 28, alignment: .trailing)
                            }
                            .font(Term.mono(11))
                        }
                    }
                }
                Text("today kst · \(strength) · counted in server memory only")
                    .font(Term.mono(10))
                    .foregroundStyle(Term.muted.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        } else {
            Text(adblockOn ? "no lookups yet today on this server"
                           : "turn on --adblock (settings → dns) to count blocked ads and watch domains live")
                .font(Term.mono(11.5))
                .foregroundStyle(Term.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func figure(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(Term.mono(20, .bold))
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            Text(label).font(Term.mono(10)).foregroundStyle(Term.muted)
        }
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func percent(_ v: Double) -> String {
        String(format: v < 0.1 ? "%.1f%%" : "%.0f%%", v * 100)
    }
}

/// 실시간 도메인: 지금 이 폰이 찾는 도메인이 한 줄씩 흐른다(막힌 건 빨갛게). 서버 DNS 기록을 1초마다 받아 온다
struct LiveView: View {
    let agent: NagoAgent
    @Environment(\.dismiss) private var dismiss
    @State private var onlyBlocked = false
    @State private var paused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                Text("~/").foregroundStyle(Term.muted)
                Text("live").foregroundStyle(Term.green)
                Text(" $ ").foregroundStyle(Term.muted)
                BlinkingCursor(width: 9, height: 18)
                Spacer()
                if let dns = agent.me?.dns {
                    Text("\(AdblockPanel.grouped(dns.blocked)) ✗ · \(AdblockPanel.grouped(dns.queries))")
                        .font(Term.mono(12))
                        .foregroundStyle(Term.muted)
                        .monospacedDigit()
                }
            }
            .font(Term.mono(18, .bold))

            TermWindow(title: "nago@vpn: ~/live — dns from this phone") {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if shown.isEmpty {
                                Text("waiting for lookups… open an app or a site")
                                    .foregroundStyle(Term.muted)
                            }
                            ForEach(shown) { item in
                                row(item).id(item.id)
                            }
                        }
                        .font(Term.mono(11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 300)
                    .onChange(of: shown.last?.id) { _, last in
                        guard let last, !paused else { return }
                        withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(last, anchor: .bottom) }
                    }
                }
            }

            HStack(spacing: 8) {
                TermChoice(options: [(label: "all", value: false), (label: "blocked", value: true)], selection: $onlyBlocked)
                Spacer()
                Button(paused ? "resume" : "pause") { paused.toggle() }
                    .buttonStyle(.term)
                Button("done") { dismiss() }
                    .buttonStyle(.term)
            }
        }
        .padding(16)
        .termColumn()
        .background(Term.bg.ignoresSafeArea())
        .foregroundStyle(Term.text)
        .task {
            await agent.refresh()
            while !Task.isCancelled {
                if !paused { await agent.pollFeed() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await agent.refresh()
            }
        }
    }

    private var shown: [NagoAgent.Item] {
        onlyBlocked ? agent.feed.filter(\.b) : agent.feed
    }

    private func row(_ item: NagoAgent.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.time.string(from: Date(timeIntervalSince1970: item.t))).foregroundStyle(Term.muted)
            Text(item.b ? "✗" : "·").foregroundStyle(item.b ? Term.red : Term.muted)
            Text(item.d)
                .foregroundStyle(item.b ? Term.red : Term.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if item.r == "mine" {
                Text("mine").foregroundStyle(Term.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu { menu(item) }
    }

    /// 꾹 누르면: 나만 막기 · 나만 풀기 · 내 규칙 지우기 — 바로 서버에 보내고 다음 조회부터 바뀐다
    @ViewBuilder
    private func menu(_ item: NagoAgent.Item) -> some View {
        let rule = AdblockFilter.rule(for: item.d)
        Text(item.d)
        if rule != nil {
            Button("remove my rule", systemImage: "arrow.uturn.backward") { change { AdblockFilter.remove(item.d) } }
        }
        if item.b, rule != "allow" {
            Button("allow for me", systemImage: "checkmark.circle") { change { AdblockFilter.allow(item.d) } }
        }
        if !item.b, rule != "block" {
            Button("block for me", systemImage: "xmark.circle", role: .destructive) {
                change { AdblockFilter.block(item.d) }
            }
        }
        Button("copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.d }
    }

    private func change(_ edit: () -> Void) {
        edit()
        Task { await agent.syncFilter() }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// `// exit via  [server · kr] [home · minji-pc ●]` — 친구 집 노드가 서버에 붙어 있으면 그 집 회선으로 나갈 수 있다
struct HomeExitRow: View {
    let agent: NagoAgent
    let server: String
    /// 출구가 바뀌면(밖에서 보이는 IP가 바뀜) 다시 재라고 부른다
    let changed: () -> Void

    var body: some View {
        if let me = agent.me, !me.homes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("// exit via").foregroundStyle(Term.muted)
                    Spacer()
                    Text(hint(me)).foregroundStyle(hintColor(me))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(Term.mono(11))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip(label: "server · \(server)", on: me.exit.via == "server", online: true, id: "server")
                        ForEach(me.homes) { home in
                            chip(label: "home · \(home.name)", on: me.exit.via == home.id, online: home.online, id: home.id)
                        }
                    }
                }
                .scrollClipDisabled()
                .disabled(!me.exitAllowed || agent.switching)
                .opacity(me.exitAllowed ? 1 : 0.5)
            }
            .transition(.opacity)
        }
    }

    private func hint(_ me: NagoAgent.Me) -> String {
        if let error = agent.errorText { return "✗ " + error }
        if !me.exitAllowed { return "home exit: wg only" }
        if agent.switching { return "switching…" }
        if me.exit.via != "server", !me.exit.active { return "! home offline · using server" }
        return me.exit.via == "server" ? "friend's home ip" : "out through a home line"
    }

    private func hintColor(_ me: NagoAgent.Me) -> Color {
        if agent.errorText != nil { return Term.red }
        if me.exit.via != "server", !me.exit.active { return Term.amber }
        return Term.muted.opacity(0.7)
    }

    private func chip(label: String, on: Bool, online: Bool, id: String) -> some View {
        Button {
            guard !on else { return }
            Task {
                if await agent.setExit(id) { changed() }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(online ? Term.green : Term.muted)
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(Term.mono(12, on ? .bold : .regular))
                    .foregroundStyle(on ? Term.green : Term.num)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(on ? Term.green.opacity(0.08) : Term.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Term.green : Term.border, lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(PressScale())
        .sensoryFeedback(.selection, trigger: on)
    }
}
