import Foundation

/// Metadata for an owner photo held in the authenticated user's private
/// Supabase Storage namespace. The file bytes are deliberately not copied
/// into the local pet record: videos and extracted frames remain local, while
/// identity photos are managed from the signed-in cloud gallery.
struct PetCloudReference: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let objectPath: String
    let mimeType: String
    let originalFilename: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        objectPath: String,
        mimeType: String,
        originalFilename: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.objectPath = objectPath
        self.mimeType = mimeType
        self.originalFilename = originalFilename
        self.createdAt = createdAt
    }
}
