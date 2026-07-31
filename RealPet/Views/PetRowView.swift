import SwiftUI

struct PetRowView: View {
    let pet: Pet
    let interactiveModel: InteractivePetModelManifest?
    let actionManifest: PetActionManifest?
    let canShow: Bool
    let behaviorSnapshot: PetBehaviorSnapshot?
    let workflowLabel: String?
    let workflowLocked: Bool
    let onRetry: () -> Void
    let onOpenMotionStudio: () -> Void
    let onSetPersonality: (PetPersonality.Preset) -> Void
    let onEditPersonality: () -> Void
    let onShow: () -> Void
    let onHide: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(pet.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                    } else if pet.status == .showing, let behaviorSnapshot {
                        Image(systemName: behaviorSnapshot.mood.symbolName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(moodColor(behaviorSnapshot.mood))
                            .frame(width: 10, height: 10)
                    } else {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(workflowLabel ?? statusSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .help(behaviorHelp)
                }
            }

            Spacer()

            if pet.status == .failed || pet.status == .interrupted {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Retry")
            }

            Button(action: onOpenMotionStudio) {
                Image(systemName: "wand.and.stars")
            }
            .buttonStyle(.borderless)
            .disabled(isBusy || workflowLocked || pet.referenceImages.isEmpty && pet.framesDir == nil)
            .help("生成宠物动作")

            Menu {
                ForEach(PetPersonality.Preset.builtIn, id: \.self) { preset in
                    Button(action: { onSetPersonality(preset) }) {
                        Label {
                            Text(preset.displayName)
                        } icon: {
                            Image(systemName: preset == personalityPreset
                                  ? "checkmark" : preset.symbolName)
                        }
                    }
                }
                Divider()
                Button(action: onEditPersonality) {
                    Label {
                        Text("自定义…")
                    } icon: {
                        Image(systemName: personalityPreset == .custom
                              ? "checkmark" : PetPersonality.Preset.custom.symbolName)
                    }
                }
            } label: {
                Image(systemName: personalityPreset.symbolName)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("性格：\(personalityPreset.displayName)")

            Button(action: {
                if pet.status == .showing { onHide() } else { onShow() }
            }) {
                Image(systemName: pet.status == .showing ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .disabled(isBusy || pet.status == .failed || pet.status == .interrupted
                      || pet.status == .detected || !canShow)
            .help(showButtonHelp)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.borderless)
            .disabled(isBusy)
            .help("Delete")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    private var isBusy: Bool {
        pet.status == .detecting || pet.status == .processing
            || workflowLabel != nil
    }

    private var personalityPreset: PetPersonality.Preset {
        pet.personality?.preset ?? .balanced
    }

    private var actionModeText: String {
        if pet.status == .draft {
            return "待生成待机动作"
        }
        if pet.framesDir != nil, pet.preferredRenderer == .sourceFrames {
            return "实拍宠物"
        }
        switch interactiveModel?.stage {
        case .cubismCompiled where canShow:
            return "Live2D"
        case .cubismCompiled:
            return "Live2D 文件不完整"
        case .partsPrepared:
            return "Live2D 待编译"
        case nil:
            return "待生成 Live2D"
        }
    }

    private var showButtonHelp: String {
        if pet.status == .showing { return "隐藏桌面宠物" }
        if canShow { return "显示桌面宠物" }
        if pet.preferredRenderer == .sourceFrames {
            return "等待源视频帧处理完成"
        }
        switch interactiveModel?.stage {
        case .partsPrepared:
            return "Live2D 模型正在自动完成"
        case .cubismCompiled:
            return "Live2D 模型文件或运行时不完整"
        case nil:
            return "请先生成 Live2D 模型"
        }
    }

    private var statusSummary: String {
        let state = pet.status == .showing
            ? (behaviorSnapshot?.mood.displayName ?? statusText)
            : statusText
        return "\(state) · \(personalityPreset.displayName) · \(actionModeText) · \(captureCoverageText)"
    }

    private var captureCoverageText: String {
        let total = PetActionManifest.Action.Kind.defaultMouseInteraction.count
        let installed = Set(actionManifest?.actions.map(\.kind) ?? [])
        let required = Set(PetActionManifest.Action.Kind.defaultMouseInteraction)
        return "鼠标动作 \(installed.intersection(required).count)/\(total)"
    }

    private var behaviorHelp: String {
        guard pet.status == .showing, let behaviorSnapshot else {
            return statusSummary
        }
        return behaviorSnapshot.isPaused
            ? "当前心情：\(behaviorSnapshot.mood.displayName)，自主行为已暂停"
            : "当前心情：\(behaviorSnapshot.mood.displayName)"
    }

    private func moodColor(_ mood: PetMood) -> Color {
        switch mood {
        case .calm: return .secondary
        case .curious: return .blue
        case .happy: return .pink
        case .playful: return .orange
        case .cautious: return .yellow
        case .resting: return .gray
        }
    }

    private var statusColor: Color {
        switch pet.status {
        case .draft: return .secondary
        case .processing: return .orange
        case .ready: return .green
        case .showing: return .blue
        case .failed: return .red
        case .interrupted: return .gray
        case .detecting: return .orange
        case .detected: return .yellow
        }
    }

    private var statusText: String {
        switch pet.status {
        case .draft: return "待生成动作"
        case .detecting: return "准备中…"
        case .detected: return "Confirm pet"
        case .processing: return "处理中…"
        case .ready: return "Ready"
        case .showing: return "Showing"
        case .failed: return "Failed"
        case .interrupted: return "已中断，可重试"
        }
    }
}
