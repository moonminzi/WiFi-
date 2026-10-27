import Network
import SwiftUI

/// settings 탭. 값은 VPNView와 같은 AppStorage 키를 쓰고, 다음 연결부터 적용된다.
struct SettingsView: View {
    @State private var vpn = VPNManager()

    @AppStorage("vpnUsername") private var username = "wifiscan"
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("vpnProtocol") private var proto: VPNProto = .auto
    @AppStorage("wgEngine") private var wgEngine = "neptun"
    /// NepTUN 이벤트 루프 수. 2면 내려받기와 올리기(ACK 포함)가 다른 코어에서 돈다.
    /// (예전 queue 설정은 iOS에서 NepTUN이 쓰지 않아 뺐다 — README)
    @AppStorage("wgLoops") private var wgLoops = 1
    @AppStorage("vpnFastMode") private var fastMode = true
    @AppStorage("vpnAdblock") private var adblock = false
    @AppStorage("vpnAutoConnect") private var autoConnect: VPNAutoConnect = .off
    @AppStorage("vpnKillSwitch") private var killSwitch = false
    @AppStorage("vpnAllowLAN") private var allowLAN = true
    @AppStorage("vpnCustomDNS") private var customDNS = ""
    // 유니콘 HTTPS(SNI 차단 우회). 키는 UnicornSettings.Key에 모여 있다.
    @AppStorage(UnicornSettings.Key.strategy) private var uniStrategy: UnicornSettings.Strategy = .both
    @AppStorage(UnicornSettings.Key.pieces) private var uniPieces = 2
    @AppStorage(UnicornSettings.Key.sniCut) private var uniSNICut = true
    @AppStorage(UnicornSettings.Key.allPorts) private var uniAllPorts = false
    @AppStorage(UnicornSettings.Key.blockQUIC) private var uniBlockQUIC = true
    @AppStorage(UnicornSettings.Key.handleIPv6) private var uniIPv6 = true
    @AppStorage(UnicornSettings.Key.resolver) private var uniResolver: UnicornSettings.Resolver = .cloudflare

    @State private var password = ""
    /// 키체인에 비밀번호가 들어 있는지. 들어 있으면 입력칸 대신 ●●●● 로 보여 준다.
    @State private var savedPassword = false
    @State private var showLogs = false

    private let preset = VPNPreset.password
    private let log = NagoLog.shared

    /// 연결 중에는 바꿔도 지금 연결에 안 들어가서 잠가 둔다.
    private var locked: Bool { vpn.status.isActive || vpn.status.isBusy }
    /// 킬 스위치는 우리 터널(wg)로만 한다. 유니콘 HTTPS는 확장이 직접 DoH로 나가야 해서
    /// 모든 통신을 터널에 밀어 넣는 includeAllNetworks와 같이 쓰지 않는다.
    private var forcedWG: Bool { killSwitch }
    /// 자동 연결은 ikev2로 못 한다. wg나 유니콘 HTTPS처럼 우리 터널이어야 한다.
    private var needsOurTunnel: Bool { autoConnect != .off }

    var body: some View {
        TermPage(path: "settings") {
            if locked {
                StatusLine(kind: .warn, text: "locked while connected")
            }
            appearanceBlock
            if Edition.isUser {
                // 유저용: 고를 것만. 프로토콜·엔진은 기본값(auto · neptun)을 그대로 쓴다
                if preset == nil {
                    accountBlock
                }
                connectionBlock
                dnsBlock
                logsBlock
                aboutBlock
            } else {
                accountBlock
                protocolBlock
                if proto == .unicorn {
                    unicornBlock
                }
                connectionBlock
                dnsBlock
                serverBlock
                logsBlock
                aboutBlock
            }
        }
        .task {
            await vpn.reload()
            savedPassword = hasKeychainPassword
        }
        .onChange(of: username) { _, _ in savedPassword = hasKeychainPassword }
        .onChange(of: forcedWG) { _, forced in
            if forced { proto = .wireguard }
        }
        .onChange(of: killSwitch) { _, on in
            // 끄면 저장된 설정에도 바로 반영한다(다음 연결까지 기다리면 그동안 통신이 계속 막힐 수 있다).
            if !on { Task { await vpn.releaseKillSwitch() } }
        }
        .onChange(of: needsOurTunnel) { _, needed in
            if needed, !proto.usesTunnel { proto = .wireguard }
        }
        .onDisappear(perform: savePassword)
        .sheet(isPresented: $showLogs) { LogsView(vpn: vpn) }
    }

    // MARK: - 블록

    private var accountBlock: some View {
        TermBlock(label: "account") {
            // 유저용은 이름을 기본값(wifiscan) 그대로 쓰고 비밀번호만 받는다
            if !Edition.isUser {
                TermField(key: "user", text: $username, placeholder: "wifiscan")
                TermDivider()
            }
            if preset != nil || savedPassword {
                HStack(spacing: 10) {
                    Text("pw")
                        .foregroundStyle(Term.muted)
                        .frame(width: 56, alignment: .leading)
                    Text("••••••••")
                        .foregroundStyle(Term.muted)
                    Text(preset != nil ? "built-in" : "keychain")
                        .font(Term.mono(11))
                        .foregroundStyle(Term.muted)
                    Spacer()
                    // 내장 비밀번호는 못 바꾸지만, 키체인에 넣은 건 다시 입력할 수 있게 둔다.
                    if preset == nil {
                        Button("change") { savedPassword = false }
                            .buttonStyle(.term)
                    }
                }
                .font(Term.mono(15))
            } else {
                TermField(key: "pw", text: $password, placeholder: "keychain", secure: true)
                    .onSubmit(savePassword)
            }
        }
        .locked(locked)
    }

    private var protocolBlock: some View {
        TermBlock(label: "protocol") {
            TermChoice(options: VPNProto.allCases.map { (label: $0.label, value: $0) }, selection: $proto)
                .disabled(forcedWG)
                .opacity(forcedWG ? 0.5 : 1)
            if proto == .auto || proto == .wireguard {
                TermDivider()
                row("engine") {
                    TermChoice(options: [(label: "nagotun", value: "neptun"), (label: "go", value: "go")],
                               selection: $wgEngine)
                }
                if wgEngine == "neptun" {
                    TermDivider()
                    row("loops") {
                        TermChoice(options: [1, 2].map { (label: "\($0)", value: $0) }, selection: $wgLoops)
                    }
                }
            }
            if proto == .auto || proto == .ikev2 {
                TermDivider()
                toggle("--fast", isOn: $fastMode)
            }
        }
        .locked(locked)
    }

    /// 유니콘 HTTPS: TLS 첫 패킷(ClientHello)에 평문으로 들어 있는 도메인 이름(SNI)을
    /// 쪼개 보내 차단 장비가 읽지 못하게 한다. 서버를 거치지 않는다.
    private var unicornBlock: some View {
        TermBlock(label: "unicorn https") {
            VStack(alignment: .leading, spacing: 8) {
                key("split")
                TermChoice(options: UnicornSettings.Strategy.allCases.map { (label: $0.label, value: $0) },
                           selection: $uniStrategy)
            }
            if uniStrategy == .off {
                StatusLine(kind: .warn, text: "split off → cannot connect")
            } else {
                TermDivider()
                row("pieces") {
                    TermChoice(options: [2, 3, 4, 5].map { (label: "\($0)", value: $0) }, selection: $uniPieces)
                }
                TermDivider()
                toggle("--sni-cut", isOn: $uniSNICut)
                toggle("--all-ports", isOn: $uniAllPorts)
                toggle("--block-quic", isOn: $uniBlockQUIC)
                toggle("--ipv6", isOn: $uniIPv6)
            }
            TermDivider()
            VStack(alignment: .leading, spacing: 8) {
                key("doh")
                TermChoice(options: UnicornSettings.Resolver.allCases.map { (label: $0.label, value: $0) },
                           selection: $uniResolver)
            }
            if uniResolver == .off {
                Text("plain dns · \(DNSList.parse(customDNS)?.joined(separator: ",") ?? "1.1.1.1")")
                    .font(Term.mono(12))
                    .foregroundStyle(Term.muted)
            }
            if killSwitch {
                StatusLine(kind: .warn, text: "kill-switch forces wg")
            }
        }
        .locked(locked)
    }

    private var connectionBlock: some View {
        TermBlock(label: "connection") {
            VStack(alignment: .leading, spacing: 8) {
                key("auto-connect")
                TermChoice(options: VPNAutoConnect.allCases.map { (label: $0.label, value: $0) },
                           selection: $autoConnect)
            }
            TermDivider()
            toggle("--kill-switch", isOn: $killSwitch)
            if killSwitch {
                toggle("--allow-lan", isOn: $allowLAN)
                // includeAllNetworks를 켠 채 앱을 다시 설치하면 iOS가 모든 통신을 막아 버릴 수 있다.
                StatusLine(kind: .warn, text: "turn off before app updates")
            }
        }
        .locked(locked)
    }

    private var dnsBlock: some View {
        TermBlock(label: "dns") {
            toggle("--adblock", isOn: $adblock)
            if !Edition.isUser {
                TermDivider()
                customDNSRow
            }
        }
        .locked(locked)
    }

    private var customDNSRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TermField(key: "custom", text: $customDNS, placeholder: "1.1.1.1", keyboard: .numbersAndPunctuation)
            Text(dnsValid ? "wg" : "invalid")
                .font(Term.mono(12))
                .foregroundStyle(dnsValid ? Term.muted : Term.red)
        }
        .disabled(adblock)
        .opacity(adblock ? 0.4 : 1)
    }

    private var serverBlock: some View {
        TermBlock(label: "server") {
            row("accelerator") {
                Text("on · tcp").foregroundStyle(Term.green)
            }
            .font(Term.mono(13))
        }
    }

    /// 마지막 몇 줄(연결 단계 · 실패 이유 — 예전 vpn 탭의 boot log)을 바로 보여 주고, 전체는 view로
    private var logsBlock: some View {
        TermBlock(label: "logs") {
            let recent = Array(log.lines.suffix(6))
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, line in
                        // "MM-dd HH:mm:ss 내용"에서 날짜는 떼고 시각부터
                        Text(String(line.dropFirst(6)))
                            .foregroundStyle(line.contains("✗") ? Term.red : Term.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(Term.mono(10.5))
            }
            Button {
                showLogs = true
            } label: {
                HStack {
                    Text("view")
                    Spacer()
                    Text("\(log.lines.count) lines").foregroundStyle(Term.muted)
                }
            }
            .buttonStyle(TermButtonStyle(fill: true))
        }
    }

    private var aboutBlock: some View {
        TermBlock(label: "about") {
            Text("nago vpn \(Self.version) · \(Edition.label)")
            if !Edition.isUser {
                Text("nagotun 2.2.3-nago.1 (neptun ce18515) · wireguard-go 1.0.16")
                    .foregroundStyle(Term.muted)
            }
        }
        .font(Term.mono(13))
    }

    // MARK: - 조각

    /// 색 모드: 기기 설정을 따르거나 다크·라이트로 고정. 연결 중에도 바꿀 수 있다(잠그지 않음)
    private var appearanceBlock: some View {
        TermBlock(label: "appearance") {
            TermChoice(options: Appearance.allCases.map { (label: $0.rawValue, value: $0) }, selection: $appearance)
        }
        .animation(.easeInOut(duration: 0.3), value: appearance)
    }

    private func key(_ text: String) -> some View {
        Text(text)
            .font(Term.mono(13))
            .foregroundStyle(Term.muted)
    }

    private func row<Content: View>(_ name: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            key(name)
            content()
        }
    }

    private func toggle(_ name: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { key(name) }
            .tint(Term.green)
    }

    private var dnsValid: Bool {
        customDNS.trimmingCharacters(in: .whitespaces).isEmpty || DNSList.parse(customDNS) != nil
    }

    private var hasKeychainPassword: Bool {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { return false }
        return KeychainHelper.read(account: user)?.isEmpty == false
    }

    /// 내장 비밀번호가 없는 IPA에서 입력한 비밀번호를 키체인에 둔다(연결 때 VPNPreset.key가 읽음).
    private func savePassword() {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preset == nil, !password.isEmpty, !user.isEmpty else { return }
        _ = try? KeychainHelper.store(password: password, account: user)
        password = ""
        savedPassword = true
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// 직접 넣는 DNS. "1.1.1.1, 8.8.8.8" → ["1.1.1.1", "8.8.8.8"], 하나라도 IP가 아니면 nil.
enum DNSList {
    static func parse(_ text: String) -> [String]? {
        let items = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard !items.isEmpty,
              items.allSatisfy({ IPv4Address($0) != nil || IPv6Address($0) != nil }) else { return nil }
        return items
    }
}

// MARK: - 로그 화면

struct LogsView: View {
    let vpn: VPNManager
    @State private var tunnel: VPNManager.TunnelReport?
    @Environment(\.dismiss) private var dismiss
    private let log = NagoLog.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TermWindow(title: "nago@vpn: ~/logs") {
                    VStack(alignment: .leading, spacing: 2) {
                        if let tunnel {
                            Text("# tunnel").foregroundStyle(Term.muted)
                            if let stats = tunnel.stats, !stats.isEmpty {
                                Text(stats).foregroundStyle(Term.green)
                            }
                            ForEach(Array(tunnel.lines.enumerated()), id: \.offset) { Text($0.element) }
                            Text(" ")
                        }
                        Text("# app").foregroundStyle(Term.muted)
                        if log.lines.isEmpty {
                            Text("(empty)").foregroundStyle(Term.muted)
                        }
                        ForEach(Array(log.lines.enumerated()), id: \.offset) { Text($0.element) }
                    }
                    .font(Term.mono(11))
                    .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Button("copy") { UIPasteboard.general.string = allText }
                        .buttonStyle(.term)
                    Button("clear") { log.clear() }
                        .buttonStyle(.termDanger)
                    Spacer()
                    Button("done") { dismiss() }
                        .buttonStyle(.term)
                }
            }
            .padding(16)
            .termColumn()
        }
        .background(Term.bg.ignoresSafeArea())
        .foregroundStyle(Term.text)
        .task { tunnel = await vpn.tunnelReport() }
    }

    private var allText: String {
        var out: [String] = []
        if let tunnel {
            out.append("# tunnel")
            if let stats = tunnel.stats { out.append(stats) }
            out += tunnel.lines
        }
        out.append("# app")
        out += log.lines
        return out.joined(separator: "\n")
    }
}

private extension View {
    func locked(_ on: Bool) -> some View {
        disabled(on).opacity(on ? 0.5 : 1)
    }
}
