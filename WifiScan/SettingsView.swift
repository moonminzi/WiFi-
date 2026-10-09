import Network
import SwiftUI

/// settings 탭. 값은 VPNView와 같은 AppStorage 키를 쓰고, 다음 연결부터 적용된다.
struct SettingsView: View {
    @State private var vpn = VPNManager()

    @AppStorage("vpnUsername") private var username = "wifiscan"
    @AppStorage("vpnProtocol") private var proto: VPNProto = .auto
    @AppStorage("wgEngine") private var wgEngine = "neptun"
    @AppStorage("vpnFastMode") private var fastMode = true
    @AppStorage("vpnAdblock") private var adblock = false
    @AppStorage("vpnAutoConnect") private var autoConnect: VPNAutoConnect = .off
    @AppStorage("vpnKillSwitch") private var killSwitch = false
    @AppStorage("vpnAllowLAN") private var allowLAN = true
    @AppStorage("vpnCustomDNS") private var customDNS = ""

    @State private var password = ""
    @State private var showLogs = false

    private let preset = VPNPreset.password
    private let log = NagoLog.shared

    /// 연결 중에는 바꿔도 지금 연결에 안 들어가서 잠가 둔다.
    private var locked: Bool { vpn.status.isActive || vpn.status.isBusy }
    /// 자동 연결·킬 스위치는 wg로만 한다.
    private var forcedWG: Bool { autoConnect != .off || killSwitch }

    var body: some View {
        TermPage(path: "settings") {
            if locked {
                StatusLine(kind: .warn, text: "locked while connected")
            }
            accountBlock
            protocolBlock
            connectionBlock
            dnsBlock
            serverBlock
            logsBlock
            aboutBlock
        }
        .task { await vpn.reload() }
        .onChange(of: forcedWG) { _, forced in
            if forced { proto = .wireguard }
        }
        .onDisappear(perform: savePassword)
        .sheet(isPresented: $showLogs) { LogsView(vpn: vpn) }
    }

    // MARK: - 블록

    private var accountBlock: some View {
        TermBlock(label: "account") {
            TermField(key: "user", text: $username, placeholder: "wifiscan")
            TermDivider()
            if preset != nil {
                HStack(spacing: 10) {
                    Text("pw")
                        .foregroundStyle(Term.muted)
                        .frame(width: 56, alignment: .leading)
                    Text("••••••••")
                        .foregroundStyle(Term.muted)
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
            if proto != .ikev2 {
                TermDivider()
                row("engine") {
                    TermChoice(options: [(label: "neptun", value: "neptun"), (label: "go", value: "go")],
                               selection: $wgEngine)
                }
            }
            if proto != .wireguard {
                TermDivider()
                toggle("--fast", isOn: $fastMode)
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
            TermDivider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TermField(key: "custom", text: $customDNS, placeholder: "1.1.1.1", keyboard: .numbersAndPunctuation)
                Text(dnsValid ? "wg" : "invalid")
                    .font(Term.mono(12))
                    .foregroundStyle(dnsValid ? Term.muted : Term.red)
            }
            .disabled(adblock)
            .opacity(adblock ? 0.4 : 1)
        }
        .locked(locked)
    }

    private var serverBlock: some View {
        TermBlock(label: "server") {
            row("accelerator") {
                Text("on · tcp").foregroundStyle(Term.green)
            }
            .font(Term.mono(13))
        }
    }

    private var logsBlock: some View {
        TermBlock(label: "logs") {
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
            Text("nago vpn \(Self.version)")
            Text("neptun ce18515 · wireguard-go 1.0.16")
                .foregroundStyle(Term.muted)
        }
        .font(Term.mono(13))
    }

    // MARK: - 조각

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

    /// 내장 비밀번호가 없는 IPA에서 입력한 비밀번호를 키체인에 둔다(연결 때 VPNPreset.key가 읽음).
    private func savePassword() {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preset == nil, !password.isEmpty, !user.isEmpty else { return }
        _ = try? KeychainHelper.store(password: password, account: user)
        password = ""
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
