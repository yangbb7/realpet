import Foundation

typealias PetStatus = Pet.Status

struct Pet: Codable, Identifiable {
    let id: UUID
    var name: String
    var sourcePath: String?
    var framesDir: String?
    /// Owner-supplied still images used to establish this pet's visual identity.
    /// Optional keeps records written before photo-driven creation decodable.
    var referenceImagePaths: [String]? = nil
    var frameCount: Int
    var fps: Int
    var createdAt: Date
    var status: Status
    var personality: PetPersonality? = nil
    var rigManifestPath: String? = nil
    var detectedAnimalClass: String? = nil
    var templateProfile: PetTemplateProfile? = nil
    /// `nil` is a pre-0.3.0 record. It is deliberately interpreted as source
    /// frames when available so persisted pets migrate without reprocessing.
    var rendererKind: PetRendererKind? = nil

    enum Status: String, Codable {
        case draft        // Photos imported; the initial idle motion is not ready yet
        case detecting    // Running pet detection (~1s)
        case detected     // Detection done, waiting for user confirmation
        case processing   // Full pipeline running
        case ready        // Done, ready to show
        case showing      // Currently displayed on desktop
        case interrupted  // App quit while a transient workflow was active
        case failed       // Error occurred
    }

    /// Persisted transient states have no live Process or pending UI after an
    /// app restart. Convert them into an explicit retryable state instead of
    /// presenting an endless spinner. A displayed pet becomes ready because
    /// its desktop renderer also exits with the app.
    static func recoveringAfterLaunch(_ saved: [Pet]) -> (pets: [Pet], changed: Bool) {
        var recovered = saved
        var changed = false

        for index in recovered.indices {
            let nextStatus: Status?
            switch recovered[index].status {
            case .detecting, .detected, .processing:
                nextStatus = .interrupted
            case .showing:
                nextStatus = .ready
            case .draft, .ready, .interrupted, .failed:
                nextStatus = nil
            }

            if let nextStatus, nextStatus != recovered[index].status {
                recovered[index].status = nextStatus
                changed = true
            }
        }
        return (recovered, changed)
    }

    var preferredRenderer: PetRendererKind {
        rendererKind ?? .sourceFrames
    }

    var referenceImages: [String] {
        referenceImagePaths ?? []
    }
}
