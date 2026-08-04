import AppKit
import SwiftUI

struct MainPanelView: View {
    @EnvironmentObject var vm: PetListViewModel
    @ObservedObject var bridge: PythonBridge
    @ObservedObject private var googleLogin = SupabaseGoogleLoginCoordinator.shared
    @State private var pendingCustomActionVideoURL: URL?
    @State private var customActionName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controlHeader

                if let pet = vm.pet {
                    petDashboard(pet)
                } else {
                    emptyPetState
                }

                if bridge.isProcessing {
                    processingState
                }

                if let error = bridge.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack {
                    Text(vm.pet == nil ? "还没有桌面宠物" : "一个宠物 · 十二个动作槽位")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        vm.petLauncher.stopAll()
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                    }
                    .buttonStyle(.borderless)
                    .help("退出 RealPet")
                    .accessibilityLabel("退出 RealPet")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 540)
        .sheet(isPresented: $vm.showPetImageManager) {
            PetImageManagerView(onDismiss: { vm.dismissPetImageManager() })
                .environmentObject(vm)
        }
        .sheet(isPresented: Binding(
            get: { pendingCustomActionVideoURL != nil },
            set: { isPresented in
                if !isPresented { pendingCustomActionVideoURL = nil }
            })) {
            CustomActionNameView(
                name: $customActionName,
                onCancel: { pendingCustomActionVideoURL = nil },
                onConfirm: {
                    guard let videoURL = pendingCustomActionVideoURL else { return }
                    vm.importCustomActionVideo(url: videoURL, named: customActionName)
                    pendingCustomActionVideoURL = nil
                })
        }
        .sheet(item: Binding(
            get: { vm.pendingActionReview },
            set: { review in
                if review == nil { vm.discardPendingActionReview() }
            })) { review in
            ActionReviewView(
                review: review,
                onAccept: { vm.acceptPendingActionReview() },
                onDiscard: { vm.discardPendingActionReview() })
        }
    }

    private var controlHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("RealPet")
                    .font(.headline)
                Text("桌面宠物控制台")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if case .signedIn(let account) = googleLogin.state {
                    Text(account.displayName)
                        .disabled(true)
                    Divider()
                }
                Button("退出 Google 登录", role: .destructive) {
                    googleLogin.signOut()
                }
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("账户")
            .accessibilityLabel("Google 账户")
        }
    }

    private var emptyPetState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("建立你的宠物动作库")
                .font(.title3.weight(.semibold))
            Text("添加素材后从头部跟随开始。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                vm.presentPetImageManager()
            } label: {
                Label("宠物图片管理", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!vm.canImportPetMedia)
        }
    }

    private func petDashboard(_ pet: Pet) -> some View {
        let manifest = vm.actionManifest(for: pet)
        let editingAction = vm.motionComposerPet?.id == pet.id
            ? vm.selectedMotionAction : nil
        let installedCount = Set(manifest?.actions.map(\.kind) ?? [])
            .intersection(Set(PetActionManifest.Action.Kind.fixedActionKinds)).count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                petThumbnail(for: pet)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pet.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Label(
                        pet.status == .showing ? "桌面显示中" : "桌面未显示",
                        systemImage: pet.status == .showing ? "eye.fill" : "eye.slash")
                        .font(.footnote)
                        .foregroundStyle(pet.status == .showing ? .green : .secondary)
                }
                Button {
                    vm.presentPetImageManager()
                } label: {
                    Label("图片管理", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)
                .disabled(vm.hasActiveWorkflow)
                Spacer()
                Button {
                    if pet.status == .showing {
                        vm.hidePet(pet)
                    } else {
                        vm.showPet(pet)
                    }
                } label: {
                    Label(
                        pet.status == .showing ? "隐藏桌宠" : "显示桌宠",
                        systemImage: pet.status == .showing ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
                .disabled(vm.hasActiveWorkflow || !vm.canShowPet(pet))

                petMenu(for: pet)
            }

            HStack(spacing: 10) {
                Label("桌宠大小", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { vm.displayScale(for: pet) },
                        set: { vm.setDisplayScale($0, for: pet) }),
                    in: 0.55...1.75,
                    step: 0.05)
                Text("\(Int((vm.displayScale(for: pet) * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .accessibilityElement(children: .contain)

            HStack(alignment: .firstTextBaseline) {
                Text("动作套装")
                    .font(.headline)
                Spacer()
                Text("\(installedCount)/12 已安装")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(installedCount == 12 ? .green : .secondary)
            }

            ActionSlotGrid(
                manifest: manifest,
                selectedAction: editingAction,
                generatingAction: vm.generatingMotionAction,
                isBusy: vm.hasActiveWorkflow
            ) { action in
                vm.presentMotionComposer(for: pet, action: action)
            }

            if editingAction != nil {
                MotionComposerView(
                    pet: pet,
                    onClose: { vm.dismissMotionComposer() })
                    .environmentObject(vm)
            }

            customActions(for: pet)
        }
    }

    private func petThumbnail(for pet: Pet) -> some View {
        let reference = vm.motionReferenceImages(for: pet).first
        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.08))
            if let reference, let image = NSImage(contentsOf: reference) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .clipped()
            } else {
                Image(systemName: "pawprint.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func petMenu(for pet: Pet) -> some View {
        Menu {
            Button("宠物图片管理") { vm.presentPetImageManager() }
            Button("自定义动作") { presentCustomActionVideoPanel() }
                .disabled(!vm.canImportCustomAction(for: pet))
            Divider()
            Button("删除当前宠物", role: .destructive) { vm.deletePet(pet) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(vm.hasActiveWorkflow)
        .help("宠物管理")
    }

    @MainActor
    private func presentCustomActionVideoPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择自定义动作视频"
        panel.prompt = "选择视频"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.begin { response in
            guard response == .OK, let url = panel.urls.first else { return }
            customActionName = url.deletingPathExtension().lastPathComponent
            pendingCustomActionVideoURL = url
        }
    }

    private func customActions(for pet: Pet) -> some View {
        let actions = vm.customActions(for: pet)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("自定义动作")
                    .font(.headline)
                Spacer()
                Button {
                    presentCustomActionVideoPanel()
                } label: {
                    Label("添加", systemImage: "video.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(!vm.canImportCustomAction(for: pet))
            }

            ForEach(actions, id: \.id) { action in
                HStack(spacing: 10) {
                    Image(systemName: action.kind.symbolName)
                        .foregroundStyle(.blue)
                    Text(action.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(action.fps) FPS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        vm.playCustomAction(action, for: pet)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(vm.hasActiveWorkflow)
                    .help("播放\(action.displayName)")
                    .accessibilityLabel("播放\(action.displayName)")

                    Button(role: .destructive) {
                        vm.deleteCustomAction(action, for: pet)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(vm.hasActiveWorkflow)
                    .help("删除\(action.displayName)")
                    .accessibilityLabel("删除\(action.displayName)")
                }
                .padding(.vertical, 6)
                if action.id != actions.last?.id {
                    Divider()
                }
            }
        }
    }

    private var processingState: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressView(value: bridge.progress)
                .progressViewStyle(.linear)
            HStack {
                Text(bridge.statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("停止", role: .destructive) {
                    bridge.cancelProcessing()
                }
                .buttonStyle(.borderless)
                .font(.footnote)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.orange.opacity(0.7)).frame(height: 1)
        }
    }

}
