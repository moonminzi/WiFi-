import Foundation
import Observation
import Security
import UniformTypeIdentifiers

struct SharedFile: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let expiresAt: Date
    let size: Int64

    var isExpired: Bool { expiresAt < .now }
}

/// 내 Cloudflare Worker(worker/ 폴더)에 파일을 올리고 링크를 받는다.
@MainActor
@Observable
final class ShareStore {
    static let shared = ShareStore()
    static let maxUploadBytes: Int64 = 100 * 1024 * 1024

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "shareServerURL") }
    }
    var token: String {
        didSet { Keychain.set(token, for: "uploadToken") }
    }
    private(set) var history: [SharedFile] = []

    var isConfigured: Bool { baseURL != nil && !token.isEmpty }

    private init() {
        serverURL = UserDefaults.standard.string(forKey: "shareServerURL") ?? ""
        token = Keychain.string(for: "uploadToken") ?? ""
        if let data = UserDefaults.standard.data(forKey: "shareHistory"),
           let decoded = try? JSONDecoder().decode([SharedFile].self, from: data) {
            history = decoded.filter { !$0.isExpired }
        }
    }

    /// "qr-share.abc.workers.dev" 처럼 입력해도 되게 https://를 붙이고 끝의 /를 뗀다.
    var baseURL: URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    // MARK: - API

    func ping() async throws {
        let request = try makeRequest(path: "/ping", method: "GET")
        _ = try await send(request)
    }

    func upload(
        fileAt fileURL: URL, name: String, hours: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SharedFile {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0 else { throw ShareError.message("빈 파일은 올릴 수 없어요.") }
        guard size <= Self.maxUploadBytes else { throw ShareError.message("100MB까지만 올릴 수 있어요.") }

        var request = try makeRequest(
            path: "/upload", method: "PUT",
            query: [URLQueryItem(name: "name", value: name), URLQueryItem(name: "hours", value: String(hours))])
        let type = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600

        let delegate = UploadProgressDelegate(onProgress: progress)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL, delegate: delegate)
        try check(data, response)

        struct UploadResponse: Decodable {
            let id: String
            let url: URL
            let expiresAt: Date
            let size: Int64
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: string))
            }
            return date
        }
        let result = try decoder.decode(UploadResponse.self, from: data)
        let file = SharedFile(id: result.id, name: name, url: result.url, expiresAt: result.expiresAt, size: result.size)
        history.insert(file, at: 0)
        persistHistory()
        return file
    }

    /// 공유 중지: 서버에서 지우고 목록에서도 뺀다. 이미 만료된 것은 목록에서만 뺀다.
    func stopSharing(_ file: SharedFile) async {
        if !file.isExpired, let request = try? makeRequest(path: "/f/\(file.id)", method: "DELETE") {
            _ = try? await send(request)
        }
        history.removeAll { $0.id == file.id }
        persistHistory()
    }

    func pruneExpired() {
        let before = history.count
        history.removeAll(where: \.isExpired)
        if history.count != before { persistHistory() }
    }

    // MARK: - 내부

    private func makeRequest(path: String, method: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let baseURL, !token.isEmpty else { throw ShareError.message("먼저 설정에서 Worker 주소와 비밀번호를 넣어 주세요.") }
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            // URLComponents는 '+'를 그대로 두는데, 서버는 '+'를 공백으로 읽는다
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(data, response)
        return data
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ShareError.message("서버 응답이 이상해요.") }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let error: String }
            if let body = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw ShareError.message(body.error)
            }
            throw ShareError.message(http.statusCode == 404
                ? "Worker 주소를 다시 확인해 주세요. (404)"
                : "서버 오류 (\(http.statusCode))")
        }
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "shareHistory")
        }
    }
}

enum ShareError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

/// 업로드 비밀번호는 UserDefaults 대신 키체인에 둔다.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "WifiScan"

    static func string(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
