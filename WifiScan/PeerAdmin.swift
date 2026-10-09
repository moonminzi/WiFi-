import CoreImage.CIFilterBuiltins
import CryptoKit
import SwiftUI

// MARK: - API

/// 서울 WireGuard 피어 관리. 대시보드 Lambda에 POST하면 서울 서버에서 nago-peer가 실행된다.
enum PeerAPI {
    struct Reply: Decodable {
        let ok: Bool?
        let error: String?
        let ip: String?
        let serverPub: String?
        let endpoint: String?
        /// 서버별 WireGuard 공개키/포트(kr/jp/us/uk)
        let servers: [String: WGServer]?
    }

    struct WGServer: Codable {
        let pub: String
        let port: Int?
    }

    enum Failure: LocalizedError {
        case server(String)

        var errorDescription: String? {
            switch self {
            case .server(let message): message
            }
        }
    }

    @discardableResult
    static func send(_ body: [String: String], key: String) async throws -> Reply {
        var request = URLRequest(url: DashAPI.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-nago-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 { throw RegionAPI.APIError.forbidden }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard code == 200, let reply, reply.ok == true else {
            throw Failure.server(reply?.error ?? "HTTP \(code)")
        }
        return reply
    }
}

// MARK: - 새 피어

/// 폰에서 키를 만들고 공개키만 서버에 등록한다. 개인키는 이 화면에서 QR/파일로 넘기고 나면 남지 않는다.
struct NewPeer: Identifiable {
    let id = UUID()
    let name: String
    let ip: String
    let config: String
    let file: URL

    static func create(name: String, key: String) async throws -> NewPeer {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let reply = try await PeerAPI.send(
            ["op": "add", "name": name, "pub": privateKey.publicKey.rawRepresentation.base64EncodedString()],
            key: key)
        guard let ip = reply.ip, let serverPub = reply.serverPub, let endpoint = reply.endpoint else {
            throw PeerAPI.Failure.server("bad reply from server")
        }
        let config = """
            [Interface]
            PrivateKey = \(privateKey.rawRepresentation.base64EncodedString())
            Address = \(ip)/32
            DNS = 1.1.1.1
            MTU = 1420

            [Peer]
            PublicKey = \(serverPub)
            Endpoint = \(endpoint)
            AllowedIPs = 0.0.0.0/0
            PersistentKeepalive = 25

            """
        let number = (Int(ip.split(separator: ".").last ?? "") ?? 1) - 1
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nago-peer-\(number).conf")
        try Data(config.utf8).write(to: file, options: [.atomic, .completeFileProtection])
        return NewPeer(name: name, ip: ip, config: config, file: file)
    }
}

/// 새 피어 QR + .conf 공유
struct PeerConfigSheet: View {
    let peer: NewPeer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            TermWindow(title: "wg peer add — \(peer.name)") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("✓ added \(peer.ip)").foregroundStyle(Term.green)
                    if let image = Self.qr(peer.config) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 6))
                            .frame(maxWidth: 320)
                            .frame(maxWidth: .infinity)
                    }
                    Text("! key shown once")
                        .foregroundStyle(Term.amber)
                    ShareLink(item: peer.file) {
                        Text("share .conf")
                    }
                    .buttonStyle(.termPrimary)
                    Button("done") { dismiss() }
                        .buttonStyle(TermButtonStyle(fill: true))
                }
                .font(Term.mono(12.5))
            }
            .padding(16)
        }
        .background(Term.bg.ignoresSafeArea())
        .foregroundStyle(Term.text)
        .onDisappear { try? FileManager.default.removeItem(at: peer.file) }
    }

    static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
