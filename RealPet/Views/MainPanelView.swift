import SwiftUI
import UniformTypeIdentifiers

struct MainPanelView: View {
    @EnvironmentObject var vm: PetListViewModel
    @ObservedObject var bridge: PythonBridge

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
            // Header
            HStack {
                Image(systemName: "pawprint.fill")
                    .foregroundColor(.accentColor)
                Text("RealPet")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle(
                    isOn: Binding(
                        get: { vm.speechInteractionEnabled },
                        set: { vm.setSpeechInteractionEnabled($0) })
                ) {
                    Image(systemName: speechIconName)
                        .foregroundStyle(speechColor)
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(!vm.hasVisiblePet && !vm.speechInteractionEnabled)
                .help(vm.speechInteractionHelp)
                .accessibilityLabel("语音互动")

                Toggle(
                    isOn: Binding(
                        get: { vm.cameraInteractionEnabled },
                        set: { vm.setCameraInteractionEnabled($0) })
                ) {
                    Image(systemName: cameraIconName)
                        .foregroundStyle(cameraColor)
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(!vm.hasVisiblePet && !vm.cameraInteractionEnabled)
                .help(vm.cameraInteractionHelp)
                .accessibilityLabel("视觉互动")

                Button {
                    vm.showVisionModelSetup = true
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(visionModelColor)
                }
                .buttonStyle(.borderless)
                .help(vm.localIntelligenceHelp)
                .accessibilityLabel("本机智能设置")
            }

            Divider()

            // Photo-first creation flow. The legacy video path remains available
            // for owners who want to install footage captured from their pet.
            Button(action: { vm.showPhotoPicker = true }) {
                HStack {
                    Image(systemName: "photo.badge.plus")
                    Text("导入宠物照片")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(vm.hasActiveWorkflow)
            .fileImporter(
                isPresented: $vm.showPhotoPicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    vm.importPhotos(urls: urls)
                }
            }

            Button("导入实拍视频") { vm.showFilePicker = true }
                .buttonStyle(.borderless)
                .font(.footnote)
                .disabled(vm.hasActiveWorkflow)
                .fileImporter(
                    isPresented: $vm.showFilePicker,
                    allowedContentTypes: [
                        UTType.movie,
                        UTType.quickTimeMovie,
                        UTType.mpeg4Movie
                    ],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        vm.importVideo(url: url)
                    }
                }

            // Progress section
            if bridge.isProcessing {
                VStack(spacing: 6) {
                    ProgressView(value: bridge.progress)
                        .progressViewStyle(.linear)

                    HStack {
                        Text(bridge.statusText)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Stop") {
                            bridge.cancelProcessing()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                    }
                }
                .padding(8)
                .background(Color.black.opacity(0.05))
                .cornerRadius(6)
            }

            // Error
            if let error = bridge.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .lineLimit(3)
            }

            // Pet list
            if !vm.pets.isEmpty {
                Divider()

                VStack(spacing: 0) {
                    ForEach(vm.pets) { pet in
                        PetRowView(
                            pet: pet,
                            interactiveModel: vm.interactiveModel(for: pet),
                            actionManifest: vm.actionManifest(for: pet),
                            canShow: vm.canShowPet(pet),
                            behaviorSnapshot: vm.behaviorSnapshots[pet.id],
                            workflowLabel: vm.rigGenerationLabel(for: pet),
                            workflowLocked: vm.hasActiveWorkflow,
                            onRetry: { vm.retryPet(pet) },
                            onOpenMotionStudio: { vm.presentMotionStudio(for: pet) },
                            onSetPersonality: { vm.setPersonality($0, for: pet) },
                            onEditPersonality: { vm.presentPersonalityEditor(for: pet) },
                            onShow: { vm.showPet(pet) },
                            onHide: { vm.hidePet(pet) },
                            onDelete: { vm.deletePet(pet) }
                        )

                        if pet.id != vm.pets.last?.id {
                            Divider().padding(.leading, 8)
                        }
                    }
                }
            }

            Divider()

            // Quit
            Button("Quit") {
                vm.petLauncher.stopAll()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 300)
        .sheet(item: $vm.personalitySetupPet) { pet in
            PersonalityEditorView(
                pet: pet,
                onCancel: { vm.cancelPersonalityEditor() },
                onSave: { personality in
                    vm.setPersonality(personality, for: pet)
                    vm.cancelPersonalityEditor()
                })
        }
        .sheet(isPresented: $vm.showVisionModelSetup) {
            VisualInteractionSetupView(
                viewModel: vm,
                onCancel: { vm.showVisionModelSetup = false })
        }
        .sheet(item: $vm.motionStudioPet) { pet in
            MotionStudioView(
                pet: pet,
                onDismiss: { vm.dismissMotionStudio() })
                .environmentObject(vm)
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

    private var cameraIconName: String {
        switch vm.cameraInteractionState {
        case .denied, .unavailable, .failed: return "video.slash"
        case .running: return "video.fill"
        default: return "video"
        }
    }

    private var speechIconName: String {
        switch vm.speechInteractionState {
        case .denied, .restricted, .unavailable, .failed: return "mic.slash"
        case .listening: return "mic.fill"
        default: return "mic"
        }
    }

    private var speechColor: Color {
        switch vm.speechInteractionState {
        case .listening: return .green
        case .requestingPermission, .starting: return .orange
        case .denied, .restricted, .unavailable, .failed: return .red
        default: return .secondary
        }
    }

    private var cameraColor: Color {
        switch vm.cameraInteractionState {
        case .running: return .green
        case .requestingPermission, .starting: return .orange
        case .denied, .unavailable, .failed: return .red
        default: return .secondary
        }
    }

    private var visionModelColor: Color {
        if case .failed = vm.localVLMRuntimeState { return .red }
        if case .failed = vm.localBehaviorPlannerRuntimeState { return .red }
        if case .inferencing = vm.localVLMRuntimeState { return .orange }
        if case .planning = vm.localBehaviorPlannerRuntimeState { return .orange }
        if case .ready = vm.localVLMRuntimeState { return .green }
        if case .ready = vm.localBehaviorPlannerRuntimeState { return .green }
        return .secondary
    }
}
