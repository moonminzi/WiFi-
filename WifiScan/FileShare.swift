import Foundation
import Observation
import UniformTypeIdentifiers

struct SharedFile: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let expiresAt: Date
    let size: Int64

    var isExpired: Bool { expiresAt < .now }
}

/// tmpfiles.org(가입 없는 임시 파일 호스팅)에 올리고 링크를 받는다.
/// 100MB까지, 정한 시간(최대 48시간)이 지나면 서버에서 지워진다. 링크를 아는 사람은 누구나 받을 수 있다.
@MainActor
@Observable
final class ShareStore {
    static let shared = ShareStore()
    static let maxUploadBytes: Int64 = 100 * 1024 * 1024
    static let maxHours = 48

    private static let endpoint = URL(string: "https://tmpfiles.org/api/v1/upload")!
    private static let historyKey = "shareHistory"

    private(set) var history: [SharedFile] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let decoded = try? JSONDecoder().decode([SharedFile].self, from: data) {
            history = decoded.filter { !$0.isExpired }
        }
    }

    func upload(
        fileAt fileURL: URL, name: String, hours: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SharedFile {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0 else { throw ShareError.message("빈 파일은 올릴 수 없어요.") }
        guard size <= Self.maxUploadBytes else { throw ShareError.message("100MB까지만 올릴 수 있어요.") }

        let hours = min(max(hours, 1), Self.maxHours)
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyURL = fileURL.deletingLastPathComponent().appendingPathComponent("upload.multipart")
        try Self.writeMultipartBody(
            to: bodyURL, boundary: boundary, fileURL: fileURL, fileName: name,
            fields: ["expire": String(hours * 3600)])
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600

        let delegate = UploadProgressDelegate(onProgress: progress)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL, delegate: delegate)

        struct UploadResponse: Decodable {
            struct Payload: Decodable { let url: String }
            let status: String
            let data: Payload?
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let body = try? JSONDecoder().decode(UploadResponse.self, from: data),
              body.status == "success", let link = body.data?.url, let url = URL(string: link)
        else {
            throw ShareError.message("업로드에 실패했어요. 잠시 뒤 다시 해 보세요.")
        }

        let file = SharedFile(
            id: url.path(), name: name, url: url,
            expiresAt: .now.addingTimeInterval(TimeInterval(hours * 3600)), size: size)
        history.insert(file, at: 0)
        persistHistory()
        return file
    }

    /// 서버에서 바로 지울 방법은 없어서, 목록에서만 뺀다(정한 시간이 지나면 서버에서도 지워짐).
    func remove(_ file: SharedFile) {
        history.removeAll { $0.id == file.id }
        persistHistory()
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    /// 큰 파일을 메모리에 다 올리지 않도록 multipart 본문을 파일로 만든다.
    private static func writeMultipartBody(
        to bodyURL: URL, boundary: String, fileURL: URL, fileName: String, fields: [String: String]
    ) throws {
        FileManager.default.createFile(atPath: bodyURL.path(), contents: nil)
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }

        var head = ""
        for (key, value) in fields {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n"
        }
        let safeName = fileName.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n"
        head += "Content-Type: \(mime)\r\n\r\n"
        try output.write(contentsOf: Data(head.utf8))

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
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
