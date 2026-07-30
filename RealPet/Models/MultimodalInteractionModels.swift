import Foundation

struct MultimodalEvidenceFrame: Sendable {
    let id: UUID
    let capturedAt: TimeInterval
    let mimeType: String
    let data: Data
}

struct EphemeralEvidenceSnapshot: Sendable {
    let evidence: ObservationEvidence
    let expiresAt: TimeInterval
    let frames: [MultimodalEvidenceFrame]
}

struct VLMInferenceRequest: Sendable {
    let id: UUID
    let petId: UUID
    let issuedAt: TimeInterval
    let expiresAt: TimeInterval
    let evidence: ObservationEvidence
    let frames: [MultimodalEvidenceFrame]
    let context: [String: String]
}

struct VLMInferenceResult: Sendable {
    let kind: String
    let confidence: Double
    let actor: String?
    let target: String?
    let spatial: SpatialContext?
    let attributes: [String: String]

    init(
        kind: String,
        confidence: Double,
        actor: String? = "local_user",
        target: String? = "pet",
        spatial: SpatialContext? = nil,
        attributes: [String: String] = [:]
    ) {
        self.kind = kind
        self.confidence = confidence
        self.actor = actor
        self.target = target
        self.spatial = spatial
        self.attributes = attributes
    }
}

protocol VLMInteractionModel: Sendable {
    func infer(_ request: VLMInferenceRequest) async throws -> VLMInferenceResult
}

enum VLMInferenceError: Error, Equatable {
    case noObservation
}
