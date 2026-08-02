import Foundation

typealias PetStatus = Pet.Status

struct PetDesktopPosition: Codable, Equatable {
    var x: Double
    var y: Double
}

struct Pet: Codable, Identifiable {
    let id: UUID
    var name: String
    var sourcePath: String?
    var framesDir: String?
    /// Owner-supplied still images used to establish this pet's visual identity.
    /// Legacy local paths are migrated into `cloudReferenceImages` after the
    /// owner signs in. They remain optional so existing installations recover.
    var referenceImagePaths: [String]? = nil
    /// The signed-in owner's cloud gallery. Image bytes stay in private
    /// Storage; this record keeps only opaque object paths and display metadata.
    var cloudReferenceImages: [PetCloudReference]? = nil
    /// The Google/Supabase owner of this local video and action catalog.
    /// `nil` records predate mandatory sign-in and are claimed once by the
    /// first account that completes the one-time gallery migration.
    var cloudOwnerID: UUID? = nil
    var frameCount: Int
    var fps: Int
    var createdAt: Date
    var status: Status
    /// Legacy-only persisted field. New runtime behavior uses one fixed,
    /// deterministic interaction policy and does not expose personality.
    var personality: PetPersonality? = nil
    var rigManifestPath: String? = nil
    var detectedAnimalClass: String? = nil
    var templateProfile: PetTemplateProfile? = nil
    /// `nil` is a pre-0.3.0 record. It is deliberately interpreted as source
    /// frames when available so persisted pets migrate without reprocessing.
    var rendererKind: PetRendererKind? = nil
    /// Per-pet desktop presentation scale. Optional keeps existing pet records
    /// decodable and gives them the conservative default below.
    var displayScale: Double? = nil
    /// The lower-left window origin last chosen by the owner. Optional keeps
    /// records created before position persistence decodable.
    var desktopPosition: PetDesktopPosition? = nil

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
        // Version 1 of the product may have persisted multiple pets. The
        // desktop runtime now has one global owner-pet slot, so retain the most
        // recently created record without touching older asset directories.
        var recovered = saved.max { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }.map { [$0] } ?? []
        var changed = recovered.count != saved.count

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

    var cloudReferences: [PetCloudReference] {
        cloudReferenceImages ?? []
    }

    var resolvedDisplayScale: Double {
        min(1.75, max(0.55, displayScale ?? 1.0))
    }
}
