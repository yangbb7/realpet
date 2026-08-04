import AppKit
import SwiftUI

/// The action-specific editor shown directly beneath the main action grid.
/// It does not repeat the grid or open a second workspace.
struct MotionComposerView: View {
    @EnvironmentObject private var vm: PetListViewModel

    let pet: Pet
    let onClose: () -> Void

    @State private var showServiceConfiguration = false
    @State private var seconds = 4
    @State private var assetProfile = PetAssetProfile.standard
    @State private var configurationMessage: String?
    @State private var showActionPackConfirmation = false

    private var references: [URL] {
        vm.motionReferenceImages(for: pet)
    }

    private var referenceCount: Int {
        vm.cloudReferenceImages(for: pet).count
    }

    private var selectedAction: FixedPetAction { vm.selectedMotionAction }

    private var isBusy: Bool { vm.motionWorkflowState.isBusy }

    private var manifest: PetActionManifest? { vm.actionManifest(for: pet) }

    private var headFollowInstalled: Bool {
        manifest?.actions.contains(where: { $0.kind == .gazeOrbit }) == true
    }

    private var selectedActionInstalled: Bool {
        manifest?.actions.contains(where: { $0.kind == selectedAction.kind }) == true
    }

    private var canGenerateSelectedAction: Bool {
        selectedAction == .headFollow || headFollowInstalled
    }

    private var missingActionCount: Int {
        vm.missingFixedActions(for: pet).count
    }

    private var recoverableJob: MotionGenerationJob? {
        vm.recoverableMotionJob(for: pet)
    }

    private var credentialStatus: String {
        "MiniMax H3 由 RealPet 云端安全服务处理全部原图"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("动作编辑")
                        .font(.subheadline.weight(.semibold))
                    Text("为 \(selectedAction.displayName) 准备独立动作视频")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showServiceConfiguration.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("动作服务配置")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .help("关闭")
            }

            HStack(alignment: .center, spacing: 12) {
                MotionReferenceStrip(urls: references)
                    .frame(width: 150, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Label(selectedAction.displayName, systemImage: selectedAction.symbolName)
                        .font(.headline)
                    Text(selectedActionInstalled ? "已安装独立视频" : "单视频动作槽位")
                        .font(.footnote)
                        .foregroundStyle(selectedActionInstalled ? .green : .secondary)
                    Text(credentialStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if selectedAction.requiresExistingBaseFrames && !headFollowInstalled {
                Label("请先完成“头部跟随”，再生成这个动作", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("动作提示词")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(selectedAction.prompt(referenceImageCount: referenceCount))
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                if missingActionCount > 1 {
                    Button {
                        showActionPackConfirmation = true
                    } label: {
                        Label("生成剩余 \(missingActionCount) 个动作", systemImage: "rectangle.stack.badge.play")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || referenceCount == 0)
                }
                Spacer()

                Button {
                    vm.generateAction(for: pet, action: selectedAction)
                } label: {
                    Label(
                        selectedActionInstalled ? "替换此动作视频" : "生成此动作视频",
                        systemImage: "video.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || !canGenerateSelectedAction || referenceCount == 0)
            }

            if let status = vm.motionWorkflowState.displayName {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().controlSize(.small) }
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(statusColor)
                    Spacer()
                    if isBusy {
                        Button("停止本地等待", role: .destructive) {
                            vm.cancelMotionGeneration()
                        }
                        .buttonStyle(.borderless)
                        .font(.footnote)
                        .help("服务方未提供远程取消接口；任务 ID 会保留，可稍后恢复结果")
                    }
                }
            }

            if vm.queuedActionPackRemainingCount > 0 {
                Text("动作套装还剩 \(vm.queuedActionPackRemainingCount) 个待生成")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let recoverableJob, !isBusy {
                HStack(spacing: 8) {
                    Label(recoverableJobStatus(recoverableJob), systemImage: "arrow.clockwise")
                        .font(.footnote)
                        .foregroundStyle(recoverableJob.state == .failed ? .red : .orange)
                    Spacer()
                    if recoverableJob.state != .failed {
                        Button("恢复结果") {
                            vm.resumeMotionGenerationJob(recoverableJob)
                        }
                        .buttonStyle(.borderless)
                        .font(.footnote)
                    }
                    Button("清除记录", role: .destructive) {
                        vm.discardMotionGenerationJob(recoverableJob)
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                }
            }

            if showServiceConfiguration {
                Divider()
                serviceConfiguration
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .onAppear(perform: loadConfiguration)
        .confirmationDialog(
            "生成剩余 \(missingActionCount) 个固定动作？",
            isPresented: $showActionPackConfirmation,
            titleVisibility: .visible
        ) {
            Button("开始按顺序生成") {
                vm.generateMissingActionPack(for: pet)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("每次只生成一个动作。身份校验通过后仍需确认安装；放弃任一预览会结束本次动作套装。")
        }
    }

    private var statusColor: Color {
        if case .failed = vm.motionWorkflowState { return .red }
        if isBusy { return .secondary }
        return .green
    }

    private var serviceConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("视频生成服务")
                .font(.subheadline.weight(.semibold))
            Text("MiniMax H3 云端安全服务")
                .font(.footnote.weight(.semibold))
            Text("仅提交当前 Google 账户、宠物和动作信息。RealPet 云端服务在私有图册中读取最多 \(references.count) 张原图，并使用服务端 MiniMax 凭据生成视频。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("视频模型：MiniMax H3  |  2K")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("时长", selection: $seconds) {
                Text("4 秒").tag(4)
                Text("8 秒").tag(8)
                Text("12 秒").tag(12)
                Text("15 秒").tag(15)
            }
            Picker("素材质量", selection: $assetProfile) {
                ForEach(PetAssetProfile.allCases) { profile in
                    Text("\(profile.displayName)（\(profile.detail)）").tag(profile)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                if let configurationMessage {
                    Text(configurationMessage)
                        .font(.caption)
                        .foregroundStyle(configurationMessage == "已保存" ? .green : .red)
                }
                Spacer()
                Button("保存") {
                    do {
                        try vm.saveMotionServiceConfiguration(
                            seconds: seconds)
                        vm.saveAssetProfile(assetProfile)
                        configurationMessage = "已保存"
                    } catch {
                        configurationMessage = error.localizedDescription
                    }
                }
                .disabled(isBusy)
            }
        }
    }

    private func loadConfiguration() {
        let configuration = vm.motionServiceConfiguration
        seconds = configuration.seconds
        assetProfile = vm.assetProfile
    }

    private func recoverableJobStatus(_ job: MotionGenerationJob) -> String {
        switch job.state {
        case .preparingReference: return "参考图准备被中断"
        case .submitted: return "远端任务等待恢复"
        case .downloading: return "远端任务等待下载"
        case .cancelledLocally: return "已停止本地等待，远端任务可能仍在继续"
        case .failed: return "远端任务恢复失败"
        }
    }
}

private struct MotionReferenceStrip: View {
    let urls: [URL]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.black.opacity(0.08))
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFill()
                                .clipped()
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                        if index == 0 {
                            Text("主")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.white)
                                .padding(4)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .frame(height: 64)
    }
}
