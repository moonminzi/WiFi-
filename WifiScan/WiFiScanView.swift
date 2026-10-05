import SwiftUI

struct WiFiScanView: View {
    @State private var model = ScanModel()
    @State private var qr: QRPayload?
    @AppStorage("autoJoin") private var autoJoin = true

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                credentialsSection
                joinSection
            }
            .navigationTitle("와이파이 스캔")
            .sheet(item: $qr) { QRSheet(payload: $0) }
        }
    }

    // MARK: - 사진 입력

    private var sourceSection: some View {
        Section {
            if let image = model.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            ImageSourceBar(onImage: { scan($0) })
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            Toggle("인식되면 바로 연결", isOn: $autoJoin)
        } footer: {
            if model.status == .scanning {
                Label("글자 읽는 중…", systemImage: "text.viewfinder")
            } else if model.status == .notFound {
                Text("와이파이 정보를 찾지 못했어요. 종이가 화면에 꽉 차게 다시 찍거나 직접 입력하세요.")
            }
        }
    }

    // MARK: - 인식 결과

    private var credentialsSection: some View {
        Group {
            Section("네트워크 이름 (ID)") {
                TextField("SSID", text: $model.ssid)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                AlternativeChips(values: model.ssidAlternatives) { model.ssid = $0 }
            }
            Section {
                TextField("비밀번호", text: $model.password)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !model.password.isEmpty {
                    AmbiguousCharacterEditor(text: $model.password)
                }
                AlternativeChips(values: model.passwordAlternatives) { model.password = $0 }
            } header: {
                Text("비밀번호 (PW)")
            } footer: {
                if model.password.contains(where: { AmbiguousCharacterEditor.group(for: $0) != nil }) {
                    Text("색으로 표시된 글자는 손글씨에서 헷갈리기 쉬운 글자예요. 누르면 비슷한 글자로 바뀝니다.")
                }
            }
        }
    }

    // MARK: - 연결

    private var joinSection: some View {
        Section {
            Button {
                Task { await model.join() }
            } label: {
                HStack {
                    Spacer()
                    if model.status == .joining {
                        ProgressView()
                    } else {
                        Label("연결", systemImage: "wifi")
                            .font(.headline)
                    }
                    Spacer()
                }
            }
            .disabled(!model.canJoin)
            Button {
                qr = .wifi(ssid: model.ssid, password: model.password)
            } label: {
                Label("QR로 공유", systemImage: "qrcode")
            }
            .disabled(model.ssid.trimmingCharacters(in: .whitespaces).isEmpty)
        } footer: {
            switch model.status {
            case .joined(let ssid):
                Label("\(ssid)에 연결됐어요", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }

    private func scan(_ image: UIImage) {
        Task { await model.load(image, autoJoin: autoJoin) }
    }
}

// MARK: - 작은 뷰들

/// OCR이 함께 내놓은 다른 후보들. 누르면 그 값으로 바꾼다.
private struct AlternativeChips: View {
    let values: [String]
    let onSelect: (String) -> Void

    var body: some View {
        if !values.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Text("다른 후보").font(.caption).foregroundStyle(.secondary)
                    ForEach(values, id: \.self) { value in
                        Button(value) { onSelect(value) }
                            .font(.caption.monospaced())
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

/// 비밀번호를 한 글자씩 보여주고, 헷갈리는 글자를 누르면 비슷한 글자로 순환시킨다.
struct AmbiguousCharacterEditor: View {
    @Binding var text: String

    private static let groups: [[Character]] = [
        ["0", "O", "D", "Q", "o"],
        ["1", "l", "I", "i", "|"],
        ["5", "S", "s"],
        ["2", "Z", "z"],
        ["8", "B"],
        ["6", "G", "b"],
        ["9", "g", "q"],
    ]

    static func group(for c: Character) -> [Character]? {
        groups.first { $0.contains(c) }
    }

    var body: some View {
        let chars = Array(text)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(chars.indices, id: \.self) { i in
                    let c = chars[i]
                    if let group = Self.group(for: c) {
                        Button {
                            var updated = chars
                            let next = (group.firstIndex(of: c)! + 1) % group.count
                            updated[i] = group[next]
                            text = String(updated)
                        } label: {
                            cell(c).background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    } else {
                        cell(c).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
    }

    private func cell(_ c: Character) -> some View {
        Text(String(c))
            .font(.title3.monospaced().weight(.semibold))
            .frame(minWidth: 26, minHeight: 36)
    }
}
