import Foundation

@MainActor
final class VLMInteractionAdapter: InteractionAdapter {
    var onObservation: ((InteractionObservation) -> Void)?
    var onInferenceActivityChange: ((Bool) -> Void)?
    var onInferenceError: ((String) -> Void)?

    private let model: VLMInteractionModel
    private let evidenceBuffer: EphemeralEvidenceBuffer
    private let now: () -> TimeInterval
    private var activeRequestId: UUID?
    private var activeTargetPetIds: [UUID] = []
    private var inferenceTask: Task<Void, Never>?
    private var isRunning = false

    init(
        model: VLMInteractionModel,
        evidenceBuffer: EphemeralEvidenceBuffer,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.model = model
        self.evidenceBuffer = evidenceBuffer
        self.now = now
    }

    func start() throws {
        isRunning = true
    }

    func stop() {
        isRunning = false
        activeRequestId = nil
        activeTargetPetIds = []
        inferenceTask?.cancel()
        inferenceTask = nil
        onInferenceActivityChange?(false)
        evidenceBuffer.removeAll()
    }

    @discardableResult
    func submit(
        petId: UUID,
        lookback: TimeInterval = 2,
        maximumLatency: TimeInterval = 4,
        context: [String: String] = [:]
    ) -> Bool {
        submit(
            petIds: [petId],
            lookback: lookback,
            maximumLatency: maximumLatency,
            context: context)
    }

    @discardableResult
    func submit(
        petIds: [UUID],
        lookback: TimeInterval = 2,
        maximumLatency: TimeInterval = 4,
        context: [String: String] = [:]
    ) -> Bool {
        var seen = Set<UUID>()
        let targets = petIds.filter {
            $0 != UUID() && seen.insert($0).inserted
        }
        guard isRunning,
              activeRequestId == nil,
              let primaryPetId = targets.first,
              maximumLatency >= 0.25 else { return false }

        let issuedAt = now()
        let expiresAt = issuedAt + min(maximumLatency, 10)
        guard let snapshot = evidenceBuffer.makeSnapshot(
            now: issuedAt, lookback: lookback, expiresAt: expiresAt) else {
            return false
        }

        let request = VLMInferenceRequest(
            id: UUID(), petId: primaryPetId,
            issuedAt: issuedAt, expiresAt: expiresAt,
            evidence: snapshot.evidence,
            frames: snapshot.frames,
            context: context)
        activeRequestId = request.id
        activeTargetPetIds = targets
        onInferenceActivityChange?(true)
        let model = self.model
        inferenceTask = Task { [weak self] in
            do {
                let result = try await model.infer(request)
                guard !Task.isCancelled else { return }
                self?.complete(request: request, result: result)
            } catch VLMInferenceError.noObservation {
                guard !Task.isCancelled else { return }
                self?.finish(requestId: request.id)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish(requestId: request.id)
                self?.onInferenceError?(error.localizedDescription)
            }
        }
        return true
    }

    private func complete(
        request: VLMInferenceRequest,
        result: VLMInferenceResult
    ) {
        guard activeRequestId == request.id else { return }
        defer { finish(requestId: request.id) }

        let completedAt = now()
        guard completedAt <= request.expiresAt,
              InteractionKind.multimodalAllowed.contains(result.kind),
              result.confidence.isFinite,
              result.confidence > 0,
              result.confidence <= 1 else { return }

        let observation = InteractionObservation(
            petId: request.petId,
            source: InteractionSource.cameraVLM,
            kind: result.kind,
            occurredAt: request.evidence.endedAt,
            expiresAt: request.expiresAt,
            confidence: result.confidence,
            actor: result.actor,
            target: result.target,
            spatial: result.spatial,
            evidence: request.evidence,
            attributes: result.attributes)
        guard observation.isFresh(at: completedAt) else { return }
        for petId in activeTargetPetIds {
            onObservation?(InteractionObservation(
                petId: petId,
                source: observation.source,
                kind: observation.kind,
                occurredAt: observation.occurredAt,
                expiresAt: observation.expiresAt,
                confidence: observation.confidence,
                actor: observation.actor,
                target: observation.target,
                spatial: observation.spatial,
                evidence: observation.evidence,
                attributes: observation.attributes))
        }
    }

    private func finish(requestId: UUID) {
        guard activeRequestId == requestId else { return }
        activeRequestId = nil
        activeTargetPetIds = []
        inferenceTask = nil
        onInferenceActivityChange?(false)
    }
}
