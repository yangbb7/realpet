@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

private enum SpeechInteractionError: LocalizedError {
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "当前语言的语音识别服务不可用"
        case .onDeviceRecognitionUnavailable:
            return "当前语言不支持设备端语音识别"
        case .microphoneUnavailable:
            return "没有可用的麦克风输入"
        }
    }
}

@MainActor
final class SpeechInteractionAdapter: InteractionAdapter {
    var onObservation: ((InteractionObservation) -> Void)?
    var onStateChange: ((SpeechInteractionState) -> Void)?

    private(set) var state: SpeechInteractionState = .disabled {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }

    private let targetPetIds: () -> [UUID]
    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartTask: Task<Void, Never>?
    private var recognitionGeneration: UUID?
    private var inputTapInstalled = false
    private var wantsToRun = false
    private var interpreter = SpeechCommandInterpreter()

    init(
        locale: Locale = SpeechInteractionAdapter.preferredLocale(),
        targetPetIds: @escaping () -> [UUID]
    ) {
        self.locale = locale
        self.targetPetIds = targetPetIds
    }

    func start() throws {
        guard !wantsToRun else { return }
        wantsToRun = true
        requestSpeechAuthorizationIfNeeded()
    }

    func stop() {
        wantsToRun = false
        restartTask?.cancel()
        restartTask = nil
        stopCurrentRecognition()
        interpreter.reset()
        state = .disabled
    }

    private func requestSpeechAuthorizationIfNeeded() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            requestMicrophoneAuthorizationIfNeeded()
        case .notDetermined:
            state = .requestingPermission
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, self.wantsToRun else { return }
                    switch status {
                    case .authorized:
                        self.requestMicrophoneAuthorizationIfNeeded()
                    case .denied:
                        self.state = .denied
                    case .restricted:
                        self.state = .restricted
                    case .notDetermined:
                        self.state = .failed("无法确认语音识别权限")
                    @unknown default:
                        self.state = .failed("无法确认语音识别权限")
                    }
                }
            }
        case .denied:
            state = .denied
        case .restricted:
            state = .restricted
        @unknown default:
            state = .failed("无法确认语音识别权限")
        }
    }

    private func requestMicrophoneAuthorizationIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecognition()
        case .notDetermined:
            state = .requestingPermission
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.wantsToRun else { return }
                    if granted {
                        self.startRecognition()
                    } else {
                        self.state = .denied
                    }
                }
            }
        case .denied:
            state = .denied
        case .restricted:
            state = .restricted
        @unknown default:
            state = .failed("无法确认麦克风权限")
        }
    }

    private func startRecognition() {
        guard wantsToRun else { return }
        state = .starting
        do {
            let recognizer = try makeRecognizer()
            let engine = AVAudioEngine()
            audioEngine = engine
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw SpeechInteractionError.microphoneUnavailable
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.taskHint = .confirmation
            input.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: format
            ) { buffer, _ in
                request.append(buffer)
            }
            inputTapInstalled = true
            engine.prepare()
            try engine.start()

            let generation = UUID()
            recognitionGeneration = generation
            self.recognizer = recognizer
            recognitionRequest = request
            recognitionTask = recognizer.recognitionTask(with: request) {
                [weak self] result, error in
                Task { @MainActor [weak self] in
                    self?.consume(
                        result: result,
                        error: error,
                        generation: generation)
                }
            }
            state = .listening
        } catch {
            stopCurrentRecognition()
            state = .unavailable(error.localizedDescription)
        }
    }

    private func makeRecognizer() throws -> SFSpeechRecognizer {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else {
            throw SpeechInteractionError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechInteractionError.onDeviceRecognitionUnavailable
        }
        return recognizer
    }

    private func consume(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        generation: UUID
    ) {
        guard wantsToRun, recognitionGeneration == generation else { return }
        if let result {
            let detections = interpreter.process(
                transcript: result.bestTranscription.formattedString,
                isFinal: result.isFinal,
                capturedAt: Date().timeIntervalSince1970)
            publish(detections)
            if result.isFinal {
                scheduleRestart()
                return
            }
        }
        if let error {
            stopCurrentRecognition()
            state = .failed(error.localizedDescription)
        }
    }

    private func publish(_ detections: [SpeechSemanticDetection]) {
        guard !detections.isEmpty else { return }
        let petIds = Array(Set(targetPetIds())).filter { $0 != UUID() }
        guard !petIds.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        for detection in detections
        where InteractionKind.speechAllowed.contains(detection.kind) {
            for petId in petIds {
                onObservation?(InteractionObservation(
                    petId: petId,
                    source: InteractionSource.speech,
                    kind: detection.kind,
                    occurredAt: now,
                    expiresAt: now + 2,
                    confidence: detection.confidence,
                    attributes: ["recognition": "on_device"]))
            }
        }
    }

    private func scheduleRestart() {
        stopCurrentRecognition()
        guard wantsToRun else { return }
        interpreter.resetUtterance()
        state = .starting
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.wantsToRun else { return }
            self.restartTask = nil
            self.startRecognition()
        }
    }

    private func stopCurrentRecognition() {
        recognitionGeneration = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if inputTapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        audioEngine?.stop()
        audioEngine = nil
        recognizer = nil
    }

    nonisolated private static func preferredLocale() -> Locale {
        let preferred = Locale.preferredLanguages.first ?? "zh-CN"
        return Locale(identifier: preferred)
    }
}
