import SwiftUI

struct CapturePackView: View {
    let pet: Pet
    let manifest: PetActionManifest?
    let isBusy: Bool
    let onImport: (PetActionManifest.Action.Kind) -> Void
    let onDismiss: () -> Void

    private var requiredKinds: [PetActionManifest.Action.Kind] {
        PetActionManifest.Action.Kind.gazeCapture
            + PetActionManifest.Action.Kind.requiredResponseCapture
    }

    private var capturedKinds: Set<PetActionManifest.Action.Kind> {
        Set(manifest?.actions.compactMap { action in
            action.effectiveOrigin == .captured ? action.kind : nil
        } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实拍响应素材")
                        .font(.title3.weight(.semibold))
                    Text(pet.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(capturedKinds.intersection(requiredKinds).count)/\(requiredKinds.count)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(capturedKinds.isSuperset(of: requiredKinds) ? .green : .secondary)
            }

            ProgressView(
                value: Double(capturedKinds.intersection(requiredKinds).count),
                total: Double(requiredKinds.count))

            captureSection("鼠标注视", kinds: PetActionManifest.Action.Kind.gazeCapture)
            captureSection("互动响应", kinds: PetActionManifest.Action.Kind.requiredResponseCapture)

            Spacer(minLength: 0)

            HStack {
                Text("每段都必须是同一只宠物的实拍视频")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430, height: 470)
    }

    @ViewBuilder
    private func captureSection(
        _ title: String,
        kinds: [PetActionManifest.Action.Kind]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(kinds, id: \.self) { kind in
                CapturePackSlotRow(
                    kind: kind,
                    isCaptured: capturedKinds.contains(kind),
                    isBusy: isBusy,
                    onImport: { onImport(kind) })
            }
        }
    }
}

private struct CapturePackSlotRow: View {
    let kind: PetActionManifest.Action.Kind
    let isCaptured: Bool
    let isBusy: Bool
    let onImport: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbolName)
                .frame(width: 18)
                .foregroundStyle(isCaptured ? .green : .secondary)
            Text(kind.displayName)
                .font(.body)
            Spacer()
            Image(systemName: isCaptured ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCaptured ? .green : .secondary)
                .accessibilityLabel(isCaptured ? "已采集" : "待采集")
            Button(action: onImport) {
                Image(systemName: isCaptured ? "arrow.triangle.2.circlepath" : "video.badge.plus")
            }
            .buttonStyle(.borderless)
            .disabled(isBusy)
            .help(isCaptured ? "替换\(kind.displayName)实拍素材" : "导入\(kind.displayName)实拍素材")
            .accessibilityLabel(isCaptured ? "替换\(kind.displayName)素材" : "导入\(kind.displayName)素材")
        }
        .padding(.vertical, 5)
    }
}
