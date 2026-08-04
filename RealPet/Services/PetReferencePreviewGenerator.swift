import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PetReferencePreviewGenerator {
    enum PreviewError: LocalizedError {
        case unreadableImage
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "宠物图片无法生成预览"
            case .encodingFailed: return "宠物图片预览编码失败"
            }
        }
    }

    static let maximumPixelDimension = 512

    /// Creates a small, display-only cache asset. The original remains private
    /// in Supabase Storage and is used directly by the video generation edge
    /// function, so this file never needs source-image fidelity.
    static func jpegPreview(
        from sourceData: Data,
        maximumPixelDimension: Int = maximumPixelDimension
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: false,
                  kCGImageSourceThumbnailMaxPixelSize:
                    max(1, maximumPixelDimension),
              ] as CFDictionary) else {
            throw PreviewError.unreadableImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PreviewError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PreviewError.encodingFailed
        }
        return output as Data
    }
}
