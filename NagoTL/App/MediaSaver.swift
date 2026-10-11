import Foundation
import Photos

/// 번역한 그림을 사진 앱에 넣는다(추가 권한만 요청)
enum MediaSaver {
    enum SaveError: LocalizedError {
        case denied
        case failed

        var errorDescription: String? {
            switch self {
            case .denied: "사진 앱 접근을 허용해 주세요(설정 → NAGO TL → 사진)"
            case .failed: "사진 앱에 저장하지 못했어요"
            }
        }
    }

    static func save(_ urls: [URL]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        // 한 번에 너무 많이 넣으면 실패할 수 있어 나눠서
        var i = 0
        while i < urls.count {
            let batch = Array(urls[i..<min(urls.count, i + 40)])
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for url in batch {
                        PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
                    }
                }
            } catch {
                throw SaveError.failed
            }
            i += 40
        }
    }
}
