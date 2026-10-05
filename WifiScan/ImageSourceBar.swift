import PhotosUI
import SwiftUI

/// 촬영 / 사진 / 붙여넣기 버튼 묶음. 와이파이·계좌번호 탭에서 같이 쓴다.
struct ImageSourceBar<Extra: View>: View {
    var onImage: (UIImage) -> Void
    @ViewBuilder var extra: Extra

    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var pasteboardHasImage = UIPasteboard.general.hasImages
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: 10) {
            SourceButton(title: "촬영", systemImage: "camera") { showCamera = true }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            PhotosPicker(selection: $pickerItem, matching: .images) {
                SourceLabel(title: "사진", systemImage: "photo")
            }
            .buttonStyle(.bordered)
            SourceButton(title: "이미지 붙여넣기", systemImage: "doc.on.clipboard") {
                if let image = UIPasteboard.general.image { onImage(image) }
            }
            .disabled(!pasteboardHasImage)
            extra
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image { onImage(image) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    onImage(image)
                }
                pickerItem = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { pasteboardHasImage = UIPasteboard.general.hasImages }
        }
    }
}

extension ImageSourceBar where Extra == EmptyView {
    init(onImage: @escaping (UIImage) -> Void) {
        self.init(onImage: onImage) { EmptyView() }
    }
}

struct SourceLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.title3)
            Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
    }
}

struct SourceButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SourceLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
    }
}
