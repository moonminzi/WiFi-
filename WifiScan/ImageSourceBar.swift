import PhotosUI
import SwiftUI

/// cam / photos / paste 버튼 묶음. 와이파이·계좌번호 탭에서 같이 쓴다.
struct ImageSourceBar<Extra: View>: View {
    var onImage: (UIImage) -> Void
    @ViewBuilder var extra: Extra

    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var pasteboardHasImage = UIPasteboard.general.hasImages
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: 8) {
            Button { showCamera = true } label: { Label("cam", systemImage: "camera") }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("photos", systemImage: "photo")
            }
            Button {
                if let image = UIPasteboard.general.image { onImage(image) }
            } label: {
                Label("img", systemImage: "doc.on.clipboard")
            }
            .disabled(!pasteboardHasImage)
            extra
        }
        .buttonStyle(TermButtonStyle(fill: true))
        .labelStyle(.titleAndIcon)
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
