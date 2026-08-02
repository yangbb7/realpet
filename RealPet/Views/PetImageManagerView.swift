import AppKit
import SwiftUI

struct PetImageManagerView: View {
    @EnvironmentObject private var vm: PetListViewModel

    let onDismiss: () -> Void

    private var references: [PetCloudReference] {
        guard let pet = vm.pet else { return [] }
        return vm.cloudReferenceImages(for: pet)
    }
    private var remainingImageSlots: Int {
        PetImageLibraryPolicy.maximumImageCount - references.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("宠物图片管理")
                        .font(.title3.weight(.semibold))
                    Text("\(references.count)/\(PetImageLibraryPolicy.maximumImageCount) 张")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .disabled(vm.hasActiveWorkflow)
                .help("关闭")
                .accessibilityLabel("关闭")
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 108, maximum: 132), spacing: 10),
                    count: PetImageLibraryPolicy.maximumImageCount),
                spacing: 10
            ) {
                ForEach(0..<PetImageLibraryPolicy.maximumImageCount, id: \.self) { index in
                    if references.indices.contains(index) {
                        imageCell(references[index], index: index)
                    } else {
                        emptyCell
                    }
                }
            }

            HStack {
                Button {
                    presentImagePanel()
                } label: {
                    Label("添加图片", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.hasActiveWorkflow || vm.isSynchronizingCloudGallery
                    || remainingImageSlots == 0)

                Spacer()

                Button("完成", action: onDismiss)
                    .buttonStyle(.bordered)
                    .disabled(vm.hasActiveWorkflow || vm.isSynchronizingCloudGallery)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task { vm.activateCloudGallery() }
    }

    private func imageCell(_ reference: PetCloudReference, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
            if let url = vm.cloudReferencePreview(for: reference),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else if vm.isSynchronizingCloudGallery {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
            Button {
                vm.removePetImage(at: index)
            } label: {
                Image(systemName: "trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.58), in: Circle())
            }
            .buttonStyle(.borderless)
            .padding(6)
            .disabled(vm.hasActiveWorkflow || vm.isSynchronizingCloudGallery)
            .help("删除图片")
            .accessibilityLabel("删除图片")
        }
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var emptyCell: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5]))
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
            .frame(height: 132)
            .accessibilityLabel("空图片素材位")
    }

    @MainActor
    private func presentImagePanel() {
        let panel = NSOpenPanel()
        panel.title = "选择宠物图片"
        panel.prompt = "添加图片"
        panel.message = "最多还能添加 \(remainingImageSlots) 张图片"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.begin { response in
            guard response == .OK else { return }
            vm.addPetImages(urls: panel.urls)
        }
    }
}
