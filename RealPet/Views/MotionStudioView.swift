import AppKit
import SwiftUI

struct MotionStudioView: View {
    @EnvironmentObject private var vm: PetListViewModel

    let pet: Pet
    let onDismiss: () -> Void

    @State private var selectedKind: PetActionManifest.Action.Kind = .idle
    @State private var naturalPrompt = ""
    @State private var optimizedPrompt = ""
    @State private var petDescription = ""
    @State private var warnings: [String] = []
    @State private var showServiceConfiguration = false
    @State private var baseURL = ""
    @State private var promptModel = ""
    @State private var agnesBaseURL = ""
    @State private var imageModel = ""
    @State private var miniMaxBaseURL = ""
    @State private var videoModel = ""
    @State private var seconds = 4
    @State private var promptAPIKey = ""
    @State private var agnesAPIKey = ""
    @State private var miniMaxAPIKey = ""
    @State private var configurationMessage: String?

    private var references: [URL] {
        vm.motionReferenceImages(for: pet)
    }

    private var actionKinds: [PetActionManifest.Action.Kind] {
        if pet.framesDir == nil { return [.idle] }
        return [.idle] + PetActionManifest.Action.Kind.importable
    }

    private var isBusy: Bool { vm.motionWorkflowState.isBusy }

    private var hasAllCredentials: Bool {
        vm.hasPromptMotionServiceCredential
            && vm.hasAgnesMotionServiceCredential
            && vm.hasMiniMaxMotionServiceCredential
    }

    private var hasGenerationCredentials: Bool {
        vm.hasAgnesMotionServiceCredential && vm.hasMiniMaxMotionServiceCredential
    }

    private var credentialStatus: String {
        switch (
            vm.hasPromptMotionServiceCredential,
            vm.hasAgnesMotionServiceCredential,
            vm.hasMiniMaxMotionServiceCredential
        ) {
        case (true, true, true): return "三组 Key 已配置"
        case (false, _, _): return "待配置 Prompt Key"
        case (_, false, _): return "待配置 Agnes Key"
        case (_, _, false): return "待配置 MiniMax Key"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("动作工作台")
                        .font(.title3.weight(.semibold))
                    Text(pet.name)
                        .font(.subheadline)
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
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .help("关闭")
            }

            MotionReferenceStrip(urls: references)

            HStack(spacing: 10) {
                Label("动作", systemImage: selectedKind.symbolName)
                    .font(.subheadline.weight(.medium))
                Picker("动作", selection: $selectedKind) {
                    ForEach(actionKinds, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 165)
                Spacer()
                Text(credentialStatus)
                    .font(.caption)
                    .foregroundStyle(hasAllCredentials ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("自然语言描述")
                    .font(.subheadline.weight(.medium))
                TextEditor(text: $naturalPrompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(height: 78)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(isBusy)
            }

            HStack {
                Button {
                    Task {
                        guard let result = await vm.optimizeMotionPrompt(
                            for: pet, kind: selectedKind,
                            naturalLanguage: naturalPrompt) else { return }
                        optimizedPrompt = result.optimizedPrompt
                        petDescription = result.petDescription
                        warnings = result.warnings
                    }
                } label: {
                    Label("优化 Prompt", systemImage: "wand.and.stars")
                }
                .disabled(isBusy || naturalPrompt.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button {
                    vm.generateMotion(
                        for: pet, kind: selectedKind,
                        optimizedPrompt: optimizedPrompt)
                } label: {
                    Label("生成动作", systemImage: "video.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || optimizedPrompt.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty || !hasGenerationCredentials)
            }

            if !optimizedPrompt.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("适配 MiniMax H3 的 Prompt")
                        .font(.subheadline.weight(.medium))
                    TextEditor(text: $optimizedPrompt)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(7)
                        .frame(height: 90)
                        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .disabled(isBusy)
                    if !petDescription.isEmpty {
                        Text(petDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let status = vm.motionWorkflowState.displayName {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().controlSize(.small) }
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(statusColor)
                    Spacer()
                    if isBusy {
                        Button("停止", role: .destructive) {
                            vm.cancelMotionGeneration()
                        }
                        .buttonStyle(.borderless)
                        .font(.footnote)
                    }
                }
            }

            if showServiceConfiguration {
                Divider()
                serviceConfiguration
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: loadConfiguration)
    }

    private var statusColor: Color {
        if case .failed = vm.motionWorkflowState { return .red }
        if isBusy { return .secondary }
        return .green
    }

    private var serviceConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt 中转站")
                .font(.subheadline.weight(.semibold))
            TextField("Prompt API Base URL", text: $baseURL)
                .textFieldStyle(.roundedBorder)
            TextField("提示词模型", text: $promptModel)
                .textFieldStyle(.roundedBorder)
            SecureField(
                vm.hasPromptMotionServiceCredential
                    ? "新的 Prompt API Key（留空则不修改）" : "Prompt API Key",
                text: $promptAPIKey)
                .textFieldStyle(.roundedBorder)
            Divider()
            Text("Agnes 官方直连")
                .font(.subheadline.weight(.semibold))
            TextField("Agnes API Base URL", text: $agnesBaseURL)
                .textFieldStyle(.roundedBorder)
            TextField("参考图模型", text: $imageModel)
                .textFieldStyle(.roundedBorder)
            SecureField(
                vm.hasAgnesMotionServiceCredential
                    ? "新的 Agnes API Key（留空则不修改）" : "Agnes API Key",
                text: $agnesAPIKey)
                .textFieldStyle(.roundedBorder)
            Divider()
            Text("MiniMax 官方直连")
                .font(.subheadline.weight(.semibold))
            TextField("MiniMax API Base URL", text: $miniMaxBaseURL)
                .textFieldStyle(.roundedBorder)
            Text("\(videoModel)  |  2K  |  首帧比例自适应")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("时长", selection: $seconds) {
                Text("4 秒").tag(4)
                Text("8 秒").tag(8)
                Text("12 秒").tag(12)
            }
            SecureField(
                vm.hasMiniMaxMotionServiceCredential
                    ? "新的 MiniMax API Key（留空则不修改）" : "MiniMax API Key",
                text: $miniMaxAPIKey)
                .textFieldStyle(.roundedBorder)
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
                            baseURLString: baseURL,
                            promptModel: promptModel,
                            agnesBaseURLString: agnesBaseURL,
                            imageModel: imageModel,
                            miniMaxBaseURLString: miniMaxBaseURL,
                            videoModel: videoModel,
                            seconds: seconds,
                            size: "1152x768",
                            promptAPIKey: promptAPIKey,
                            agnesAPIKey: agnesAPIKey,
                            miniMaxAPIKey: miniMaxAPIKey)
                        promptAPIKey = ""
                        agnesAPIKey = ""
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
        baseURL = configuration.baseURLString
        promptModel = configuration.promptModel
        agnesBaseURL = configuration.resolvedAgnesBaseURLString
        imageModel = configuration.imageModel ?? ""
        miniMaxBaseURL = configuration.resolvedMiniMaxBaseURLString
        videoModel = configuration.videoModel
        seconds = configuration.seconds
        if naturalPrompt.isEmpty {
            naturalPrompt = pet.framesDir == nil
                ? "让它在原地自然待机，轻微眨眼和呼吸。"
                : "让它\(selectedKind.displayName)，动作自然且完整。"
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
