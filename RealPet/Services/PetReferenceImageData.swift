import AppKit
import Foundation

enum PetReferenceImageDataError: LocalizedError {
    case unreadable

    var errorDescription: String? { "宠物参考图无法读取" }
}

struct PetReferenceImageData {
    let data: Data
    let mimeType: String

    /// Video APIs accept JPEG, PNG, and WebP references. Photos imported from
    /// macOS are often HEIC, so normalize unsupported formats before upload.
    static func load(from url: URL) throws -> PetReferenceImageData {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw PetReferenceImageDataError.unreadable
        }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .init(data: data, mimeType: "image/jpeg")
        case "png": return .init(data: data, mimeType: "image/png")
        case "webp": return .init(data: data, mimeType: "image/webp")
        default:
            guard let image = NSImage(contentsOf: url),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let jpeg = bitmap.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: 0.92]) else {
                throw PetReferenceImageDataError.unreadable
            }
            return .init(data: jpeg, mimeType: "image/jpeg")
        }
    }
}
