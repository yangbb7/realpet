import SwiftUI

struct ActionSlotGrid: View {
    let manifest: PetActionManifest?
    let selectedAction: FixedPetAction?
    let generatingAction: FixedPetAction?
    let isBusy: Bool
    let onSelect: (FixedPetAction) -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 92), spacing: 8), count: 4)

    private var installedKinds: Set<PetActionManifest.Action.Kind> {
        Set(manifest?.actions.map(\.kind) ?? [])
    }

    private var headFollowInstalled: Bool {
        installedKinds.contains(.gazeOrbit)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(FixedPetAction.allCases) { action in
                ActionSlotTile(
                    action: action,
                    state: state(for: action),
                    isSelected: selectedAction == action,
                    isBusy: isBusy && generatingAction != action
                ) {
                    onSelect(action)
                }
            }
        }
    }

    private func state(for action: FixedPetAction) -> ActionSlotState {
        if generatingAction == action { return .generating }
        if installedKinds.contains(action.kind) { return .installed }
        if action.requiresExistingBaseFrames && !headFollowInstalled {
            return .needsHeadFollow
        }
        return .available
    }
}

private enum ActionSlotState: Equatable {
    case installed
    case generating
    case needsHeadFollow
    case available

    var label: String {
        switch self {
        case .installed: return "已安装"
        case .generating: return "生成中"
        case .needsHeadFollow: return "等待头部"
        case .available: return "未生成"
        }
    }

    var tint: Color {
        switch self {
        case .installed: return .green
        case .generating: return .orange
        case .needsHeadFollow: return .secondary
        case .available: return .blue
        }
    }
}

private struct ActionSlotTile: View {
    let action: FixedPetAction
    let state: ActionSlotState
    let isSelected: Bool
    let isBusy: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: action.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    if state == .installed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    } else if state == .generating {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .foregroundStyle(state.tint)

                Text(action.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(state.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(state.tint)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(9)
            .frame(height: 76, alignment: .topLeading)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(border, lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.64 : 1)
        .help("\(action.displayName)：\(state.label)")
        .accessibilityLabel("\(action.displayName)，\(state.label)")
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        return Color.primary.opacity(0.045)
    }

    private var border: Color {
        isSelected ? .accentColor : Color.primary.opacity(0.10)
    }
}
