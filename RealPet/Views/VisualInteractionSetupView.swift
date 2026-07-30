import SwiftUI

struct VisualInteractionSetupView: View {
    private enum MessageTone {
        case success
        case warning
        case error
    }

    @ObservedObject var viewModel: PetListViewModel
    let onCancel: () -> Void

    @State private var visionEnabled: Bool
    @State private var behaviorEnabled: Bool
    @State private var endpoint: String
    @State private var visionModelName: String
    @State private var behaviorModelName: String
    @State private var installedModels: [OllamaInstalledModel] = []
    @State private var visionModels: [OllamaInstalledModel] = []
    @State private var pullModelName = "gemma3:4b"
    @State private var pullProgress: OllamaModelPullProgress?
    @State private var pullTask: Task<Void, Never>?
    @State private var isPulling = false
    @State private var isLoading = false
    @State private var message: String?
    @State private var messageTone: MessageTone = .warning

    init(viewModel: PetListViewModel, onCancel: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onCancel = onCancel
        let vision = viewModel.localVLMConfiguration
        let behavior = viewModel.localBehaviorPlannerConfiguration
        _visionEnabled = State(initialValue: vision.isEnabled)
        _behaviorEnabled = State(initialValue: behavior.isEnabled)
        _endpoint = State(initialValue:
            behavior.isEnabled ? behavior.endpoint : vision.endpoint)
        _visionModelName = State(initialValue: vision.modelName ?? "")
        _behaviorModelName = State(initialValue: behavior.modelName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                Text("本机智能设置")
                    .font(.headline)
                Spacer()
                if isLoading || isPulling {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                TextField("Ollama 地址", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isPulling)
                Button {
                    Task { await refreshModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || isPulling)
                .help("刷新本机 Ollama 模型")
                .accessibilityLabel("刷新本机 Ollama 模型")
            }

            HStack(spacing: 8) {
                TextField("Ollama 模型名称", text: $pullModelName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isPulling)
                    .onSubmit { startModelPull() }
                Button {
                    if isPulling {
                        pullTask?.cancel()
                    } else {
                        startModelPull()
                    }
                } label: {
                    Image(systemName: isPulling ? "stop.circle" : "arrow.down.circle")
                }
                .disabled(!isPulling && (normalizedPullModelName.isEmpty || isLoading))
                .help(isPulling ? "取消下载" : "下载并安装本机模型")
                .accessibilityLabel(isPulling ? "取消模型下载" : "下载并安装模型")
            }

            if isPulling, let pullProgress {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = pullProgress.fractionCompleted {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(pullProgressLabel(pullProgress))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Divider()

            Toggle("使用视觉模型理解摄像头互动", isOn: $visionEnabled)
                .toggleStyle(.checkbox)

            Picker("视觉模型", selection: $visionModelName) {
                if visionModelName.isEmpty {
                    Text("未选择").tag("")
                }
                ForEach(selectableVisionModels) { model in
                    Text(modelLabel(model)).tag(model.name)
                }
            }
            .disabled(isLoading || isPulling || selectableVisionModels.isEmpty)

            Divider()

            Toggle("使用行为模型规划自主活动", isOn: $behaviorEnabled)
                .toggleStyle(.checkbox)

            Picker("行为模型", selection: $behaviorModelName) {
                if behaviorModelName.isEmpty {
                    Text("未选择").tag("")
                }
                ForEach(selectableBehaviorModels) { model in
                    Text(modelLabel(model)).tag(model.name)
                }
            }
            .disabled(isLoading || isPulling || selectableBehaviorModels.isEmpty)

            if let message {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(message, systemImage: messageIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(messageColor)
                        .lineLimit(3)
                    Spacer()
                    if installedModels.isEmpty {
                        Link(destination: URL(string: "https://ollama.com/search")!) {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .help("获取 Ollama 模型")
                        .accessibilityLabel("获取 Ollama 模型")
                    }
                }
            } else {
                Label(
                    "行为规划只发送性格、心情和语义记忆到本机回环地址",
                    systemImage: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .task { await refreshModels() }
        .onDisappear { pullTask?.cancel() }
    }

    private var selectableVisionModels: [OllamaInstalledModel] {
        includingCurrent(visionModelName, in: visionModels)
    }

    private var selectableBehaviorModels: [OllamaInstalledModel] {
        includingCurrent(behaviorModelName, in: installedModels)
    }

    private var canSave: Bool {
        guard !isPulling else { return false }
        guard (try? LocalVLMConfiguration(
            isEnabled: visionEnabled,
            endpoint: endpoint,
            modelName: visionModelName)) != nil,
              (try? LocalBehaviorPlannerConfiguration(
                isEnabled: behaviorEnabled,
                endpoint: endpoint,
                modelName: behaviorModelName)) != nil else { return false }
        return (!visionEnabled || !visionModelName.isEmpty)
            && (!behaviorEnabled || !behaviorModelName.isEmpty)
    }

    private var normalizedPullModelName: String {
        pullModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var messageIcon: String {
        switch messageTone {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle.fill"
        }
    }

    private var messageColor: Color {
        switch messageTone {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func includingCurrent(
        _ current: String,
        in models: [OllamaInstalledModel]
    ) -> [OllamaInstalledModel] {
        guard !current.isEmpty,
              !models.contains(where: { $0.name == current }) else {
            return models
        }
        return [OllamaInstalledModel(
            name: current,
            size: 0,
            parameterSize: nil,
            quantization: nil)] + models
    }

    private func modelLabel(_ model: OllamaInstalledModel) -> String {
        guard model.size > 0 else { return model.name }
        let size = ByteCountFormatter.string(
            fromByteCount: model.size,
            countStyle: .file)
        if let parameters = model.parameterSize {
            return "\(model.name) · \(parameters) · \(size)"
        }
        return "\(model.name) · \(size)"
    }

    @MainActor
    private func refreshModels() async {
        isLoading = true
        message = nil
        do {
            let inventory = try await viewModel.discoverLocalModelInventory(
                endpoint: endpoint)
            installedModels = inventory.allModels
            visionModels = inventory.visionModels
            if installedModels.isEmpty {
                message = "Ollama 正在运行，但尚未安装模型"
                messageTone = .warning
            } else {
                if behaviorModelName.isEmpty {
                    behaviorModelName = installedModels[0].name
                }
                if visionModelName.isEmpty, let first = visionModels.first {
                    visionModelName = first.name
                }
                message = "已发现 \(installedModels.count) 个模型，其中 \(visionModels.count) 个支持视觉"
                messageTone = visionEnabled && visionModels.isEmpty ? .warning : .success
            }
        } catch {
            installedModels = []
            visionModels = []
            message = error.localizedDescription
            messageTone = .error
        }
        isLoading = false
    }

    @MainActor
    private func startModelPull() {
        let requestedModel = normalizedPullModelName
        guard !requestedModel.isEmpty, !isPulling else { return }
        guard let url = URL(string: endpoint) else {
            message = LocalVLMConfigurationError.invalidEndpoint.localizedDescription
            messageTone = .error
            return
        }

        isPulling = true
        pullProgress = OllamaModelPullProgress(
            status: "starting", completed: nil, total: nil)
        message = nil
        pullTask = Task {
            do {
                let catalog = try OllamaModelCatalog(baseURL: url)
                try await catalog.pullModel(named: requestedModel) { progress in
                    await MainActor.run { pullProgress = progress }
                }
                try Task.checkCancellation()
                await refreshModels()
                if installedModels.contains(where: { $0.name == requestedModel }) {
                    behaviorModelName = requestedModel
                }
                if visionModels.contains(where: { $0.name == requestedModel }) {
                    visionModelName = requestedModel
                }
                message = "模型 \(requestedModel) 已安装"
                messageTone = .success
            } catch {
                if Task.isCancelled
                    || (error as? URLError)?.code == .cancelled {
                    message = "已取消模型下载"
                    messageTone = .warning
                } else {
                    message = error.localizedDescription
                    messageTone = .error
                }
            }
            isPulling = false
            pullProgress = nil
            pullTask = nil
        }
    }

    private func pullProgressLabel(_ progress: OllamaModelPullProgress) -> String {
        let status: String
        switch progress.status {
        case "success": status = "模型安装完成"
        case "verifying sha256 digest": status = "正在校验模型"
        case "writing manifest": status = "正在写入模型清单"
        case "removing any unused layers": status = "正在清理模型缓存"
        case "starting": status = "正在连接 Ollama"
        default: status = "正在下载 \(normalizedPullModelName)"
        }
        guard let completed = progress.completed,
              let total = progress.total, total > 0 else { return status }
        let completedText = ByteCountFormatter.string(
            fromByteCount: completed, countStyle: .file)
        let totalText = ByteCountFormatter.string(
            fromByteCount: total, countStyle: .file)
        return "\(status) · \(completedText) / \(totalText)"
    }

    private func save() {
        do {
            try viewModel.updateLocalIntelligenceConfigurations(
                endpoint: endpoint,
                visionEnabled: visionEnabled,
                visionModelName: visionModelName,
                behaviorEnabled: behaviorEnabled,
                behaviorModelName: behaviorModelName)
            onCancel()
        } catch {
            message = error.localizedDescription
            messageTone = .error
        }
    }
}
