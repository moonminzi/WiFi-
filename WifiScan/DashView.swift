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
        /// 임시 서버 나라(만들고 지우는 서버). 지금 떠 있거나 이번 달에 쓴 나라만 온다
        let onDemand: Bool?
        /// 이번 달에 만든 서버 수(임시 서버 나라)
        let servers: Int?

        var isOnDemand: Bool { onDemand == true }
    }

    struct Peer: Decodable {
        let n: String
        let ip: String
        let name: String?
        /// 이 피어의 DNS를 서버가 광고 차단 DNS로 돌리는지(대시보드에서 피어별로 켬)
        let adblock: Bool?
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
    @State private var fetchedAt: Date?

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
            VStack(alignment: .leading, spacing: 14) {
                header
                if let data {
                    FleetPanel(data: data, liveCode: vpn.status == .connected ? savedRegion.rawValue : nil)
                }
                TermWindow(title: "nago@vpn: ~") {
                    terminal
                }
            }
            .padding(16)
            .termColumn()
        }
        .refreshable { await load() }
        .statusBarScrim()
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
        .alert("new peer", isPresented: $showAdd) {
            TextField("name", text: $nameInput)
            Button("add") { addPeer() }
            Button("cancel", role: .cancel) {}
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
            Text("\(peer.ip) \(peer.name ?? "")")
        }
        .sheet(item: $newPeer) { PeerConfigSheet(peer: $0) }
    }

    /// `~/dash $▌` + 마지막으로 받은 때
    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            Text("~/").foregroundStyle(Term.muted)
            Text("dash").foregroundStyle(Term.green)
            Text(" $ ").foregroundStyle(Term.muted)
            BlinkingCursor()
            Spacer(minLength: 8)
            Group {
                if loading {
                    Text("fetching…")
                } else if let fetchedAt {
                    Text(fetchedAt, style: .relative) + Text(" ago")
                }
            }
            .font(Term.mono(11))
            .foregroundStyle(Term.muted)
        }
        .font(Term.mono(22, .bold))
        .padding(.top, 8)
    }

    private func peerTitle(_ peer: DashData.Peer) -> String {
        var title = "peer \(peer.n) · \(peer.ip)"
        if let name = peer.name, !name.isEmpty { title += " · " + name }
        return title
    }

    private func present<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    // 관리 메뉴는 누른 줄에 붙인다. 아이패드에서는 메뉴가 붙은 뷰를 가리키는 말풍선으로 뜨는데,
    // 화면 전체(ScrollView)에 붙이면 가리킬 곳이 없어 화면 밖으로 잘렸다. 아이폰은 그대로 아래에서 올라온다.

    private func managing(_ node: DashData.Node) -> Binding<Bool> {
        Binding(get: { managedNode?.code == node.code }, set: { if !$0 { managedNode = nil } })
    }

    private func managing(_ peer: DashData.Peer) -> Binding<Bool> {
        Binding(get: { managedPeer?.n == peer.n }, set: { if !$0 { managedPeer = nil } })
    }

    @ViewBuilder
    private func nodeActions(_ node: DashData.Node) -> some View {
        if node.isOnDemand {
            // 만드는 건 vpn 탭에서 연결할 때. 여기서는 떠 있는 서버를 바로 지우기만
            if node.state == "running" || node.state == "pending" {
                Button("delete now", role: .destructive) { nodeOp("drop", node) }
            }
        } else if node.state == "stopped" {
            Button("start") { nodeOp("start", node) }
        } else if node.state == "running" {
            Button("reset idle (\(node.idle ?? 0)m)") { nodeOp("wake", node) }
            Button("reboot") { nodeOp("reboot", node) }
            Button("stop", role: .destructive) { nodeOp("stop", node) }
        }
    }

    @ViewBuilder
    private func peerActions(_ peer: DashData.Peer) -> some View {
        Button(peer.adblock == true ? "adblock off" : "adblock on") {
            run("flags", peer, extra: ["adblock": peer.adblock == true ? "0" : "1"])
        }
        Button("kick 60s") { run("kick", peer, extra: ["seconds": "60"]) }
        Button("reset usage") { run("reset", peer) }
        Button("rename") {
            nameInput = peer.name ?? ""
            renamePeer = peer
        }
        Button("remove…", role: .destructive) { removePeer = peer }
    }

    // MARK: 피어 관리 동작

    private func report(_ text: String, ok: Bool) {
        actionText = text
        actionOK = ok
    }

    private func run(_ op: String, _ peer: DashData.Peer, extra: [String: String] = [:]) {
        var body = ["op": op, "ip": peer.ip]
        body.merge(extra) { $1 }
        let what = op == "flags" ? "adblock \(extra["adblock"] == "1" ? "on" : "off")" : op
        perform(body, label: "wg peer \(what) \(peer.ip)",
                done: "\(what) \(peer.ip)" + (op == "kick" ? " · back in 60s" : ""))
    }

    private func nodeOp(_ op: String, _ node: DashData.Node) {
        let done: String
        switch op {
        case "start": done = "\(node.code) booting · ~1 min"
        case "stop": done = "\(node.code) stopping"
        case "reboot": done = "\(node.code) rebooting · ~1 min"
        case "drop": done = "\(node.code) deleting"
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
        if Demo.on {
            data = Demo.dash
            fetchedAt = Date().addingTimeInterval(-12)
            return
        }
        guard let key = VPNPreset.key(username: username) else {
            errorText = "password required → save it in the vpn tab"
            return
        }
        loading = true
        defer { loading = false }
        do {
            data = try await DashAPI.fetch(key: key)
            fetchedAt = Date()
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
                    command("nodes")
                    ForEach(data.nodes, id: \.code) { node in
                        Button { managedNode = node } label: {
                            VStack(alignment: .leading, spacing: 1) { nodeLines(node) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .confirmationDialog("\(node.code) · \(node.city) · \(node.state)",
                                            isPresented: managing(node), titleVisibility: .visible) {
                            nodeActions(node)
                        }
                    }
                }
                gap
                section {
                    command("wg show")
                    ForEach(Array(data.peers.enumerated()), id: \.element.n) { index, peer in
                        if index > 0 { gap }
                        Button { managedPeer = peer } label: {
                            VStack(alignment: .leading, spacing: 1) { peerLines(peer) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .confirmationDialog(peerTitle(peer), isPresented: managing(peer), titleVisibility: .visible) {
                            peerActions(peer)
                        }
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
                    command("cw netout --hourly --tz=KST")
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
                line(Text("# fetching…").foregroundStyle(Term.muted))
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

    private func command(_ cmd: String) -> some View {
        line(Text("$").font(Term.mono(12.5, .bold)).foregroundStyle(Term.green) + Text(" " + cmd))
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
                + Text(" " + (node.ip ?? Self.noAddress(node))).foregroundStyle(Term.num)
        )
        line(Text("   " + nodeDetail(node)).foregroundStyle(Term.muted))
    }

    /// IP가 없을 때: 임시 서버 나라는 서버 자체가 없다
    static func noAddress(_ node: DashData.Node) -> String {
        node.isOnDemand && node.state == "stopped" ? "no server" : node.state
    }

    /// 임시 서버 나라 한 줄: 떠 있으면 가동 시간, 아니면 이번 달에 만든 수
    static func onDemandDetail(_ node: DashData.Node, withType: Bool) -> String {
        if node.state == "running" {
            var bits = withType ? [node.type] : []
            if let up = node.up { bits.append("up " + duration(up)) }
            bits.append("on demand · deletes after \(node.idleLimit ?? 30)m idle")
            return bits.joined(separator: " · ")
        }
        let made = node.servers ?? 0
        return "on demand · \(made) server\(made == 1 ? "" : "s") this month"
    }

    private func nodeDetail(_ node: DashData.Node) -> String {
        if node.isOnDemand { return Self.onDemandDetail(node, withType: true) }
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
            + Text(peer.adblock == true ? "adblock " : "").foregroundStyle(Term.green)
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

// MARK: - 한눈에 보기

/// 터미널 창 위의 요약: 서버 카드(불빛·가동 시간·접속 수)와 이번 달 송신량 게이지 + 시간별 막대.
struct FleetPanel: View {
    let data: DashData
    /// 지금 이 폰이 붙어 있는 서버
    let liveCode: String?

    var body: some View {
        VStack(spacing: 8) {
            FleetMap(nodes: data.nodes, liveCode: liveCode)
                .aspectRatio(FleetMap.aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Term.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border, lineWidth: 1))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(data.nodes, id: \.code) { node in
                    NodeCard(node: node, live: node.code == liveCode)
                }
            }
            MonthCard(month: data.month, hourly: data.hourly)
        }
    }
}

private struct NodeCard: View {
    let node: DashData.Node
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                    .shadow(color: node.state == "stopped" ? .clear : color, radius: 3)
                Text(node.code).font(Term.mono(15, .bold)).foregroundStyle(Term.key)
                Text(node.city).font(Term.mono(11)).foregroundStyle(Term.muted).lineLimit(1)
                Spacer(minLength: 0)
                if live {
                    Text("you").font(Term.mono(10, .semibold)).foregroundStyle(Term.bg)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Term.green, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            Text(node.ip ?? DashView.noAddress(node))
                .font(Term.mono(12))
                .foregroundStyle(node.ip == nil ? Term.muted : Term.num)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(Term.mono(11))
                .foregroundStyle(Term.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            // 안 쓰면 알아서 꺼지기까지(유휴 타이머)
            if node.state == "running", let idle = node.idle, let limit = node.idleLimit, limit > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    GeometryReader { geo in
                        let left = 1 - min(Double(idle) / Double(limit), 1)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Term.track)
                            Capsule().fill(left < 0.2 ? Term.amber : Term.green.opacity(0.7))
                                .frame(width: max(3, geo.size.width * left))
                        }
                    }
                    .frame(height: 3)
                    Text("auto-stop in \(DashView.duration(max(limit - idle, 0) * 60))")
                        .font(Term.mono(9.5))
                        .foregroundStyle(Term.muted)
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Term.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(live ? Term.green.opacity(0.6) : Term.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch node.state {
        case "running": Term.green
        case "pending", "stopping": Term.amber
        case "stopped": Term.muted
        default: Term.red
        }
    }

    private var detail: String {
        if node.isOnDemand { return DashView.onDemandDetail(node, withType: false) }
        guard node.state == "running" else { return "boots on connect" }
        var bits: [String] = []
        if let up = node.up { bits.append("up " + DashView.duration(up)) }
        bits.append("ike \(node.ike)")
        return bits.joined(separator: " · ")
    }
}

private struct MonthCard: View {
    let month: DashData.Month
    let hourly: [DashData.Hour]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("// this month").font(Term.mono(11)).foregroundStyle(Term.muted)
                Spacer()
                Text(String(format: "$%.2f", month.usd)).font(Term.mono(18, .bold)).foregroundStyle(Term.green)
                Text("est.").font(Term.mono(10)).foregroundStyle(Term.muted)
            }
            GeometryReader { geo in
                let used = min(month.egressGB / max(month.freeGB, 0.001), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Term.track)
                    Capsule().fill(used > 0.85 ? Term.amber : Term.green)
                        .frame(width: max(4, geo.size.width * used))
                }
            }
            .frame(height: 6)
            HStack {
                Text(String(format: "egress %.1f / %.0f GB", month.egressGB, month.freeGB))
                Spacer()
                Text(String(format: "%.0f%%", min(month.egressGB / max(month.freeGB, 0.001) * 100, 100)))
            }
            .font(Term.mono(11))
            .foregroundStyle(Term.muted)

            if !hourly.isEmpty {
                let peak = max(hourly.map(\.gb).max() ?? 0, 0.000_001)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(hourly, id: \.h) { hour in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(hour.gb > 0 ? Term.green.opacity(0.35 + 0.65 * hour.gb / peak) : Term.track)
                            .frame(height: max(2, 28 * hour.gb / peak))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 28, alignment: .bottom)
                HStack {
                    Text("\(hourly.first?.h ?? ""):00")
                    Spacer()
                    Text("netout / hour")
                    Spacer()
                    Text("\(hourly.last?.h ?? ""):00")
                }
                .font(Term.mono(9.5))
                .foregroundStyle(Term.muted)
            }
        }
        .padding(12)
        .background(Term.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border, lineWidth: 1))
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
