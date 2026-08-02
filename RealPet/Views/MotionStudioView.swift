import AppKit
import SwiftUI

/// The action-specific editor shown directly beneath the main action grid.
/// It does not repeat the grid or open a second workspace.
struct MotionComposerView: View {
    @EnvironmentObject private var vm: PetListViewModel

    let pet: Pet
    let onClose: () -> Void

    @State private var showServiceConfiguration = false
    @State private var videoProvider: MotionVideoProvider = .agnes
    @State private var miniMaxBaseURL = ""
    @State private var seconds = 4
    @State private var miniMaxAPIKey = ""
    @State private var configurationMessage: String?

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

    private var recoverableJob: MotionGenerationJob? {
        vm.recoverableMotionJob(for: pet)
    }

    private var credentialStatus: String {
        switch vm.motionServiceConfiguration.provider {
        case .agnes: return "Agnes 使用云端图库的第一张原图"
        case .miniMaxH3: return "MiniMax H3 使用云端图库中的全部原图"
        }
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
                Text(selectedAction.prompt(
                    referenceImageCount: referenceCount,
                    provider: vm.motionServiceConfiguration.provider))
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
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
            Picker("视频模型", selection: $videoProvider) {
                ForEach(MotionVideoProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            if videoProvider == .agnes {
                Text("Agnes Video V2.0")
                    .font(.footnote.weight(.semibold))
                Text("由 RealPet 统一管理官方直连与凭据。生成时自动上传第一张原始宠物图片到原图桶，作为主参考图；不会调用 Agnes Image。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("原图存储与 Agnes 凭据均由 RealPet 管理，临时参考图地址在 24 小时后失效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("MiniMax H3 官方直连")
                    .font(.footnote.weight(.semibold))
                TextField("MiniMax API Base URL", text: $miniMaxBaseURL)
                    .textFieldStyle(.roundedBorder)
                Text("生成时直接发送全部 \(references.count) 张上传原图作为多参考，不经过 Supabase 或 Agnes Image。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField(
                    "新的 MiniMax API Key（留空则不修改）",
                    text: $miniMaxAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            Text("视频模型：\(videoProvider.modelName)  |  1152x768  |  24 fps")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("时长", selection: $seconds) {
                Text("4 秒").tag(4)
                Text("8 秒").tag(8)
                Text("12 秒").tag(12)
                Text("15 秒").tag(15)
                if videoProvider == .agnes {
                    Text("18 秒").tag(18)
                }
            }
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
                            provider: videoProvider,
                            miniMaxBaseURLString: miniMaxBaseURL,
                            seconds: seconds,
                            miniMaxAPIKey: miniMaxAPIKey)
                        miniMaxAPIKey = ""
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
        videoProvider = configuration.provider
        miniMaxBaseURL = configuration.resolvedMiniMaxBaseURLString
        seconds = configuration.seconds
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
