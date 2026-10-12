import Foundation
import Photos
import UniformTypeIdentifiers

/// 받은 동영상·사진을 사진 앱에 넣는다(추가 권한만 요청).
enum MediaSaver {
    enum SaveError: LocalizedError {
        case denied
        case unsupported

        var errorDescription: String? {
            switch self {
            case .denied: "사진 앱 접근을 허용해 주세요(설정 → NAGO DL → 사진)"
            case .unsupported: "사진 앱이 이 형식을 받지 않아요"
            }
        }
    }

    static func kind(_ url: URL) -> UTType? {
        UTType(filenameExtension: url.pathExtension.lowercased())
    }

    static func canSave(_ url: URL) -> Bool {
        guard let type = kind(url) else { return false }
        // 사진 앱이 받는 것만(mkv/webm/ts는 안 받는다)
        if type.conforms(to: .image) { return true }
        return ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    static func save(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        guard let type = kind(url) else { throw SaveError.unsupported }
        let isImage = type.conforms(to: .image)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: isImage ? .photo : .video, fileURL: url, options: nil)
            }
        } catch {
            throw SaveError.unsupported
        }
    }
}
