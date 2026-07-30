@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum CameraInteractionState: Equatable, Sendable {
    case disabled
    case requestingPermission
    case starting
    case running
    case denied
    case unavailable
    case failed(String)
}

private struct CameraFrameAnalysis: Sendable {
    let capturedAt: TimeInterval
    let jpegData: Data?
    let personVisible: Bool
    let detections: [CameraSemanticDetection]
}

private final class CameraFrameProcessor: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.realpet.camera.frames", qos: .userInitiated)
    var onAnalysis: (@Sendable (CameraFrameAnalysis) -> Void)?

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var interpreter = CameraGestureInterpreter()
    private var lastAnalyzedAt: TimeInterval = -.infinity
    private var lastEncodedAt: TimeInterval = -.infinity

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date().timeIntervalSince1970
        guard now - lastAnalyzedAt >= 0.18,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalyzedAt = now

        let humanRequest = VNDetectHumanRectanglesRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 2
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer, orientation: .upMirrored)
        do {
            try handler.perform([humanRequest, handRequest])
        } catch {
            return
        }

        let person = humanRequest.results?
            .max(by: { $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height })
            .map {
                NormalizedBounds(
                    x: $0.boundingBox.origin.x,
                    y: $0.boundingBox.origin.y,
                    width: $0.boundingBox.width,
                    height: $0.boundingBox.height)
            }
        let wrists = (handRequest.results ?? []).compactMap { observation -> NormalizedPoint? in
            guard let point = try? observation.recognizedPoint(.wrist) else { return nil }
            return NormalizedPoint(
                x: point.location.x,
                y: point.location.y,
                confidence: Double(point.confidence))
        }
        let detections = interpreter.process(CameraVisionSample(
            capturedAt: now, person: person, wrists: wrists))

        var jpegData: Data?
        if now - lastEncodedAt >= 0.4 {
            jpegData = encodeJPEG(pixelBuffer)
            lastEncodedAt = now
        }
        onAnalysis?(CameraFrameAnalysis(
            capturedAt: now,
            jpegData: jpegData,
            personVisible: (person?.area ?? 0) > 0.01,
            detections: detections))
    }

    func reset() {
        queue.async { [weak self] in
            self?.interpreter = CameraGestureInterpreter()
            self?.lastAnalyzedAt = -.infinity
            self?.lastEncodedAt = -.infinity
        }
    }

    private func encodeJPEG(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let properties = [
            kCGImageDestinationLossyCompressionQuality: 0.52,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

private final class CameraCaptureRunner: @unchecked Sendable {
    let session: AVCaptureSession
    private let queue = DispatchQueue(label: "com.realpet.camera.session")

    init(processor: CameraFrameProcessor) throws {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video) else {
            throw CameraCaptureError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.setSampleBufferDelegate(processor, queue: processor.queue)

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraCaptureError.configurationFailed
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        self.session = session
    }

    func start(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [session] in
            session.startRunning()
            completion(session.isRunning)
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}

private enum CameraCaptureError: LocalizedError {
    case unavailable
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "没有可用摄像头"
        case .configurationFailed: return "摄像头配置失败"
        }
    }
}

@MainActor
final class CameraInteractionAdapter: InteractionAdapter {
    var onObservation: ((InteractionObservation) -> Void)?
    var onStateChange: ((CameraInteractionState) -> Void)?
    var onVLMTrigger: (([UUID]) -> Void)?

    private(set) var state: CameraInteractionState = .disabled {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }

    private let evidenceBuffer: EphemeralEvidenceBuffer
    private let targetPetIds: () -> [UUID]
    private let processor = CameraFrameProcessor()
    private var runner: CameraCaptureRunner?
    private var wantsToRun = false
    private var vlmTriggerPolicy = CameraVLMTriggerPolicy()

    init(
        evidenceBuffer: EphemeralEvidenceBuffer,
        targetPetIds: @escaping () -> [UUID]
    ) {
        self.evidenceBuffer = evidenceBuffer
        self.targetPetIds = targetPetIds
        processor.onAnalysis = { [weak self] analysis in
            Task { @MainActor [weak self] in
                self?.consume(analysis)
            }
        }
    }

    func start() throws {
        guard !wantsToRun else { return }
        wantsToRun = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCapture()
        case .notDetermined:
            state = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.wantsToRun else { return }
                    if granted { self.startCapture() } else { self.state = .denied }
                }
            }
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .failed("无法确认摄像头权限")
        }
    }

    func stop() {
        wantsToRun = false
        runner?.stop()
        runner = nil
        processor.reset()
        vlmTriggerPolicy.reset()
        evidenceBuffer.removeAll()
        state = .disabled
    }

    private func startCapture() {
        guard wantsToRun, runner == nil else { return }
        state = .starting
        do {
            let runner = try CameraCaptureRunner(processor: processor)
            self.runner = runner
            runner.start { [weak self, weak runner] running in
                Task { @MainActor [weak self, weak runner] in
                    guard let self,
                          let runner,
                          self.runner === runner,
                          self.wantsToRun else { return }
                    self.state = running ? .running : .failed("摄像头启动失败")
                }
            }
        } catch {
            state = error is CameraCaptureError
                ? .unavailable : .failed(error.localizedDescription)
        }
    }

    private func consume(_ analysis: CameraFrameAnalysis) {
        guard wantsToRun else { return }
        if let data = analysis.jpegData {
            evidenceBuffer.append(
                data: data, capturedAt: analysis.capturedAt)
        }
        let petIds = targetPetIds().filter { $0 != UUID() }
        guard !petIds.isEmpty else { return }
        if vlmTriggerPolicy.shouldTrigger(
            capturedAt: analysis.capturedAt,
            personVisible: analysis.personVisible,
            hasSemanticChange: !analysis.detections.isEmpty
        ) {
            onVLMTrigger?(petIds)
        }
        for detection in analysis.detections {
            for petId in petIds {
                onObservation?(InteractionObservation(
                    petId: petId,
                    source: InteractionSource.cameraVision,
                    kind: detection.kind,
                    occurredAt: analysis.capturedAt,
                    expiresAt: analysis.capturedAt + 1.5,
                    confidence: detection.confidence,
                    spatial: detection.spatial))
            }
        }
    }
}
