import NetworkExtension
import SwiftUI

// MARK: - 데이터

/// 통합 대시보드 API(Lambda)가 돌려주는 모든 서버 상태. 필드 이름은 서버 JSON과 같다.
struct DashData: Decodable {
    struct Node: Decodable {
        let code: String
        let city: String
        let region: String
        let type: String
        let state: String
        let ip: String?
        let up: Int?
        let idle: Int?
        let idleLimit: Int?
        let ike: Int
        let leases: [String]
        let load: String?
        let hours: Double
        let egressGB: Double
        let usd: Double
    }

    struct Peer: Decodable {
        let n: String
        let ip: String
        let name: String?
        let hsAgo: Int?
        let rx: Int64
        let tx: Int64
        let ep: String?
    }

    struct Hour: Decodable {
        let h: String
        let gb: Double
    }

    struct Month: Decodable {
        let egressGB: Double
        let freeGB: Double
        let egressUSD: Double
        let fixedUSD: Double
        let usd: Double
    }

    let ts: String
    let nodes: [Node]
    let peers: [Peer]
    let hourly: [Hour]
    let month: Month
}

enum DashAPI {
    static let endpoint = URL(string: "https://d6hphd5k56.execute-api.ap-northeast-2.amazonaws.com/?format=json")!

    static func fetch(key: String) async throws -> DashData {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.setValue(key, forHTTPHeaderField: "x-nago-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 { throw RegionAPI.APIError.forbidden }
        guard code == 200 else { throw RegionAPI.APIError.badResponse(code) }
        return try JSONDecoder().decode(DashData.self, from: data)
    }
}

// MARK: - 화면

/// 모든 서버(kr/jp/us/uk), WireGuard 피어, 송신량, 이번 달 비용을 대시보드 사이트와 같은 터미널 창으로 보여 준다.
struct DashView: View {
    @State private var vpn = VPNManager()
    @State private var data: DashData?
    @State private var errorText: String?
    @State private var loading = false

    @AppStorage("vpnUsername") private var username = "wifiscan"
    @AppStorage("vpnSavedRegion") private var savedRegion: VPNRegion = .kr

    // 서버 / 피어 관리
    @State private var managedNode: DashData.Node?
    @State private var managedPeer: DashData.Peer?
    @State private var renamePeer: DashData.Peer?
    @State private var removePeer: DashData.Peer?
    @State private var showAdd = false
    @State private var nameInput = ""
    @State private var newPeer: NewPeer?
    @State private var actionText: String?
    @State private var actionOK = true
    @State private var busy = false

    private static let refreshSeconds = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TermWindow(title: "nago@vpn: ~ — all nodes — live") {
                    terminal
                }
                Text("↻ pull to refresh · auto \(Self.refreshSeconds)s")
                    .font(Term.mono(11.5))
                    .foregroundStyle(Term.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(16)
        }
        .refreshable { await load() }
        .task {
            // 이 탭이 보이는 동안만 돈다(다른 탭으로 가면 취소됨).
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(Self.refreshSeconds))
            }
        }
        .background(Term.bg.ignoresSafeArea())
        .foregroundStyle(Term.text)
        .tint(Term.green)
        .confirmationDialog(
            managedNode.map { "\($0.code) · \($0.city) · \($0.state)" } ?? "",
            isPresented: present($managedNode), titleVisibility: .visible, presenting: managedNode
        ) { node in
            if node.state == "stopped" {
                Button("start") { nodeOp("start", node) }
            } else if node.state == "running" {
                Button("reset idle timer (\(node.idle ?? 0)→0m)") { nodeOp("wake", node) }
                Button("reboot") { nodeOp("reboot", node) }
                Button("stop", role: .destructive) { nodeOp("stop", node) }
            }
        } message: { node in
            if node.code == "kr", node.state == "running" {
                Text("stop kr → WireGuard friends drop until someone connects to kr again.")
            } else if node.state != "running" && node.state != "stopped" {
                Text("\(node.state)… wait a moment.")
            }
        }
        .confirmationDialog(
            managedPeer.map(peerTitle) ?? "",
            isPresented: present($managedPeer), titleVisibility: .visible, presenting: managedPeer
        ) { peer in
            Button("kick — disconnect 60s") { run("kick", peer, extra: ["seconds": "60"]) }
            Button("reset usage counters") { run("reset", peer) }
            Button("rename") {
                nameInput = peer.name ?? ""
                renamePeer = peer
            }
            Button("remove…", role: .destructive) { removePeer = peer }
        }
        .alert("new peer", isPresented: $showAdd) {
            TextField("name (e.g. friend phone)", text: $nameInput)
            Button("add") { addPeer() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("A key is made on this phone and only its public half goes to kr.")
        }
        .alert("rename peer", isPresented: present($renamePeer), presenting: renamePeer) { peer in
            TextField("name", text: $nameInput)
            Button("save") { run("rename", peer, extra: ["name": nameInput]) }
            Button("cancel", role: .cancel) {}
        }
        .alert("remove peer?", isPresented: present($removePeer), presenting: removePeer) { peer in
            Button("remove", role: .destructive) { run("remove", peer) }
            Button("cancel", role: .cancel) {}
        } message: { peer in
            Text("\(peer.ip) \(peer.name ?? "") loses access for good. Its config stops working.")
        }
        .sheet(item: $newPeer) { PeerConfigSheet(peer: $0) }
    }

    private func peerTitle(_ peer: DashData.Peer) -> String {
        var title = "peer \(peer.n) · \(peer.ip)"
        if let name = peer.name, !name.isEmpty { title += " · " + name }
        return title
    }

    private func present<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    // MARK: 피어 관리 동작

    private func report(_ text: String, ok: Bool) {
        actionText = text
        actionOK = ok
    }

    private func run(_ op: String, _ peer: DashData.Peer, extra: [String: String] = [:]) {
        var body = ["op": op, "ip": peer.ip]
        body.merge(extra) { $1 }
        perform(body, label: "wg peer \(op) \(peer.ip)",
                done: "\(op) \(peer.ip)" + (op == "kick" ? " · back in 60s" : ""))
    }

    private func nodeOp(_ op: String, _ node: DashData.Node) {
        let done: String
        switch op {
        case "start": done = "\(node.code) booting · ~1 min"
        case "stop": done = "\(node.code) stopping"
        case "reboot": done = "\(node.code) rebooting · ~1 min"
        default: done = "\(node.code) idle timer reset"
        }
        // 켜고 끄는 건 상태가 바뀌는 데 시간이 걸려서 몇 번 더 새로 받는다.
        perform(["op": op, "node": node.code], label: "node \(op) \(node.code)", done: done,
                followUps: op == "wake" ? [] : [5, 15, 30, 60])
    }

    private func perform(_ body: [String: String], label: String, done: String, followUps: [Int] = []) {
        guard let key = VPNPreset.key(username: username) else {
            report("✗ password required → save it in the vpn tab", ok: false)
            return
        }
        busy = true
        report("> \(label) …", ok: true)
        Task {
            do {
                try await PeerAPI.send(body, key: key)
                report("✓ " + done, ok: true)
            } catch {
                busy = false
                report("✗ \(body["op"] ?? ""): \(error.localizedDescription)", ok: false)
                return
            }
            busy = false
            await load()
            for seconds in followUps {
                try? await Task.sleep(for: .seconds(seconds))
                await load()
            }
        }
    }

    private func addPeer() {
        guard let key = VPNPreset.key(username: username) else {
            report("✗ password required → save it in the vpn tab", ok: false)
            return
        }
        let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        report("> wg peer add \(name) …", ok: true)
        Task {
            defer { busy = false }
            do {
                let peer = try await NewPeer.create(name: name, key: key)
                report("✓ added \(peer.ip)", ok: true)
                newPeer = peer
                await load()
            } catch {
                report("✗ add: \(error.localizedDescription)", ok: false)
            }
        }
    }

    private func load() async {
        guard let key = VPNPreset.key(username: username) else {
            errorText = "password required → save it in the vpn tab"
            return
        }
        loading = true
        defer { loading = false }
        do {
            data = try await DashAPI.fetch(key: key)
            errorText = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: 터미널 내용

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 1) {
            line(prompt + Text(" ./status --all"))
            line(Text("# \(data?.ts ?? "--") KST · you ").foregroundStyle(Term.muted) + youText)
            if let errorText {
                line(Text("[FAIL] ").foregroundStyle(Term.red) + Text(errorText).foregroundStyle(Term.muted))
            }
            if let actionText {
                line(Text(actionText).foregroundStyle(actionOK ? Term.green : Term.red))
            }
            if let data {
                // 블록마다 자식 뷰 수를 적게 유지하려고 구역별로 묶는다.
                gap
                section {
                    command("nodes", note: "tap to start/stop")
                    ForEach(data.nodes, id: \.code) { node in
                        Button { managedNode = node } label: {
                            VStack(alignment: .leading, spacing: 1) { nodeLines(node) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
                gap
                section {
                    command("wg show wg0", note: "kr · tap a peer to manage")
                    ForEach(Array(data.peers.enumerated()), id: \.element.n) { index, peer in
                        if index > 0 { gap }
                        Button { managedPeer = peer } label: {
                            VStack(alignment: .leading, spacing: 1) { peerLines(peer) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                    gap
                    Button {
                        nameInput = ""
                        showAdd = true
                    } label: {
                        line(Text("$").font(Term.mono(12.5, .bold)).foregroundStyle(Term.green)
                            + Text(" wg peer add ") + Text("[+ new]").foregroundStyle(Term.key))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
                gap
                section {
                    command("cw netout --hourly --tz=KST", note: "all nodes")
                    hourlyLines(data.hourly)
                }
                gap
                section {
                    command("quota --egress --month")
                    quotaLines(data)
                }
                gap
                section {
                    command("cost --month --est")
                    costLines(data)
                }
            } else if loading || errorText == nil {
                line(Text("# fetching… (servers answer in ~5s)").foregroundStyle(Term.muted))
            }
            gap
            HStack(spacing: 0) {
                line(prompt + Text(" "))
                    .fixedSize()
                BlinkingCursor(width: 8, height: 15)
                Spacer(minLength: 0)
            }
        }
        .font(Term.mono(12.5))
    }

    private var prompt: Text {
        Text("nago@vpn").font(Term.mono(12.5, .bold)).foregroundStyle(Term.green)
            + Text(":")
            + Text("~").foregroundStyle(Term.path)
            + Text("$")
    }

    private var youText: Text {
        switch vpn.status {
        case .connected:
            return Text("[ OK ] up → \(savedRegion.rawValue)").foregroundStyle(Term.green)
        case .connecting, .reasserting, .disconnecting:
            return Text("[ .. ] \(vpn.status.koreanLabel)").foregroundStyle(Term.amber)
        default:
            return Text("[DOWN] vpn off").foregroundStyle(Term.muted)
        }
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            content()
        }
    }

    private var gap: some View {
        Text(" ").font(Term.mono(6))
    }

    /// 한 줄. 화면이 좁으면 줄바꿈 대신 조금 줄인다(사이트의 white-space: pre와 같은 느낌).
    private func line(_ text: Text) -> some View {
        text
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func command(_ cmd: String, note: String? = nil) -> some View {
        var t = Text("$").font(Term.mono(12.5, .bold)).foregroundStyle(Term.green) + Text(" " + cmd)
        if let note {
            t = t + Text(" # " + note).foregroundStyle(Term.muted)
        }
        return line(t)
    }

    // MARK: 서버

    private func stateTag(_ state: String) -> (String, Color) {
        switch state {
        case "running": return ("[ OK ]", Term.green)
        case "pending", "stopping": return ("[ .. ]", Term.amber)
        case "stopped": return ("[ -- ]", Term.muted)
        default: return ("[FAIL]", Term.red)
        }
    }

    @ViewBuilder
    private func nodeLines(_ node: DashData.Node) -> some View {
        let tag = stateTag(node.state)
        line(
            Text(node.code).foregroundStyle(Term.key)
                + Text(" " + pad(node.city, 7) + " ").foregroundStyle(Term.muted)
                + Text(tag.0).foregroundStyle(tag.1)
                + Text(" " + (node.ip ?? node.state)).foregroundStyle(Term.num)
        )
        line(Text("   " + nodeDetail(node)).foregroundStyle(Term.muted))
    }

    private func nodeDetail(_ node: DashData.Node) -> String {
        guard node.state == "running" else { return "\(node.type) · boots on connect" }
        var bits = [node.type]
        if let up = node.up { bits.append("up " + Self.duration(up)) }
        if let idle = node.idle, let limit = node.idleLimit { bits.append("idle \(idle)/\(limit)m") }
        bits.append("ike \(node.ike)")
        return bits.joined(separator: " · ")
    }

    // MARK: WireGuard 피어

    @ViewBuilder
    private func peerLines(_ peer: DashData.Peer) -> some View {
        let head = Text("[peer \(peer.n)]").foregroundStyle(Term.key) + Text(" \(peer.ip) ")
            + Text(peer.name.map { $0 + " " } ?? "").foregroundStyle(Term.path)
        if let ago = peer.hsAgo {
            let online = ago < 180
            line(head + Text(online ? "● online" : "○ idle").foregroundStyle(online ? Term.green : Term.amber))
            line(
                Text("  ↓ tx ").foregroundStyle(Term.muted)
                    + Text(Self.bytes(peer.tx).leftPad(9)).foregroundStyle(Term.num)
                    + Text("   ↑ rx ").foregroundStyle(Term.muted)
                    + Text(Self.bytes(peer.rx).leftPad(9)).foregroundStyle(Term.num)
            )
            line(
                Text("  hs ").foregroundStyle(Term.muted) + Text(Self.ago(ago))
                    + Text(" · ep ").foregroundStyle(Term.muted) + Text(peer.ep ?? "-")
            )
        } else {
            line(head + Text("○ idle").foregroundStyle(Term.muted))
            line(Text("  no handshake yet").foregroundStyle(Term.muted))
        }
    }

    // MARK: 송신량 / 비용

    @ViewBuilder
    private func hourlyLines(_ hours: [DashData.Hour]) -> some View {
        if hours.isEmpty {
            line(Text("# no datapoints yet").foregroundStyle(Term.muted))
        } else {
            let maximum = max(hours.map(\.gb).max() ?? 0, 0.000_001)
            ForEach(hours, id: \.h) { hour in
                line(
                    Text("\(hour.h):00 ")
                        + Text(String(format: "%6.2f GB ", hour.gb)).foregroundStyle(Term.num)
                        + bar(hour.gb, of: maximum, width: 20)
                )
            }
        }
    }

    @ViewBuilder
    private func quotaLines(_ data: DashData) -> some View {
        let used = data.month.egressGB
        line(
            Text("[") + bar(min(used, data.month.freeGB), of: data.month.freeGB, width: 18) + Text("] ")
                + Text(String(format: "%.1f", used)).foregroundStyle(Term.num)
                + Text(String(format: "/%.0fGB %.0f%%", data.month.freeGB, min(used / data.month.freeGB * 100, 100)))
        )
        line(Text(data.nodes.map { String(format: "%@ %.1f", $0.code, $0.egressGB) }.joined(separator: " · ") + " GB")
            .foregroundStyle(Term.muted))
    }

    @ViewBuilder
    private func costLines(_ data: DashData) -> some View {
        ForEach(data.nodes, id: \.code) { node in
            line(
                Text(node.code).foregroundStyle(Term.key)
                    + Text(" " + pad(node.type, 10)).foregroundStyle(Term.muted)
                    + Text(String(format: "%.1fh", node.hours).leftPad(7)).foregroundStyle(Term.num)
                    + Text(String(format: "  $%.2f", node.usd)).foregroundStyle(Term.num)
            )
        }
        line(Text(pad("egress >100GB", 22)).foregroundStyle(Term.muted)
            + Text(String(format: "$%.2f", data.month.egressUSD)).foregroundStyle(Term.num))
        line(Text("total").foregroundStyle(Term.key) + Text(" ≈ ").foregroundStyle(Term.muted)
            + Text(String(format: "$%.2f", data.month.usd)).foregroundStyle(Term.green)
            + Text(" this month (est.)").foregroundStyle(Term.muted))
    }

    private func bar(_ value: Double, of maximum: Double, width: Int) -> Text {
        var filled = maximum > 0 ? Int((value / maximum * Double(width)).rounded()) : 0
        if value > 0, filled == 0 { filled = 1 }
        filled = min(max(filled, 0), width)
        return Text(String(repeating: "█", count: filled)).foregroundStyle(Term.green)
            + Text(String(repeating: "░", count: width - filled)).foregroundStyle(Term.track)
    }

    private func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    // MARK: 숫자 꾸미기

    static func duration(_ seconds: Int) -> String {
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return String(format: "%dh%02dm", seconds / 3600, seconds % 3600 / 60) }
        return "\(seconds / 86_400)d\(seconds % 86_400 / 3600)h"
    }

    static func ago(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    static func bytes(_ n: Int64) -> String {
        let v = Double(n)
        if v >= 1e9 { return String(format: "%.2f GB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1f MB", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0f KB", v / 1e3) }
        return "\(n) B"
    }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

#Preview {
    DashView()
}
