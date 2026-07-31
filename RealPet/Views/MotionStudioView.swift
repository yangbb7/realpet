import AppKit
import SwiftUI

struct MotionStudioView: View {
    @EnvironmentObject private var vm: PetListViewModel

    let pet: Pet
    let onDismiss: () -> Void

    @State private var selectedScenario: DefaultMouseInteractionScenario = .pointerTracking
    @State private var showServiceConfiguration = false
    @State private var agnesBaseURL = ""
    @State private var imageModel = ""
    @State private var miniMaxBaseURL = ""
    @State private var videoModel = ""
    @State private var seconds = 4
    @State private var agnesAPIKey = ""
    @State private var miniMaxAPIKey = ""
    @State private var configurationMessage: String?

    private var references: [URL] {
        vm.motionReferenceImages(for: pet)
    }

    private var isBusy: Bool { vm.motionWorkflowState.isBusy }

    private var hasGenerationCredentials: Bool {
        vm.hasAgnesMotionServiceCredential && vm.hasMiniMaxMotionServiceCredential
    }

    private var credentialStatus: String {
        switch (vm.hasAgnesMotionServiceCredential, vm.hasMiniMaxMotionServiceCredential) {
        case (true, true): return "两组 Key 已配置"
        case (false, true): return "待配置 Agnes Key"
        case (true, false): return "待配置 MiniMax Key"
        case (false, false): return "待配置服务 Key"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("默认鼠标动作")
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
                Label("默认场景", systemImage: selectedScenario.symbolName)
                    .font(.subheadline.weight(.medium))
                Picker("默认场景", selection: $selectedScenario) {
                    ForEach(DefaultMouseInteractionScenario.allCases) { scenario in
                        Text(scenario.displayName).tag(scenario)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                Spacer()
                Text(credentialStatus)
                    .font(.caption)
                    .foregroundStyle(hasGenerationCredentials ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("预置 MiniMax H3 Prompt")
                    .font(.subheadline.weight(.medium))
                TextEditor(text: .constant(selectedScenario.debugPrompt))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(height: selectedScenario == .pointerTracking ? 188 : 112)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(true)
            }

            HStack {
                Spacer()

                Button {
                    vm.generateDefaultMotionScenario(
                        for: pet, scenario: selectedScenario)
                } label: {
                    Label("生成默认动作", systemImage: "video.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || !hasGenerationCredentials)
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
                            agnesBaseURLString: agnesBaseURL,
                            imageModel: imageModel,
                            miniMaxBaseURLString: miniMaxBaseURL,
                            videoModel: videoModel,
                            seconds: seconds,
                            agnesAPIKey: agnesAPIKey,
                            miniMaxAPIKey: miniMaxAPIKey)
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
        agnesBaseURL = configuration.resolvedAgnesBaseURLString
        imageModel = configuration.imageModel ?? ""
        miniMaxBaseURL = configuration.resolvedMiniMaxBaseURLString
        videoModel = configuration.videoModel
        seconds = configuration.seconds
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
