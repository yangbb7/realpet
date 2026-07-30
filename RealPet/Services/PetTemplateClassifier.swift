import AppKit
import Foundation
import Vision

struct PetTemplateClassifier {
    func classify(
        detectedClass: String,
        imageURL: URL,
        boundingBox: [Double]?
    ) async -> PetTemplateProfile? {
        let identifiers = await Task.detached(priority: .userInitiated) {
            Self.classificationIdentifiers(
                imageURL: imageURL, boundingBox: boundingBox)
        }.value
        return PetTemplateSelection.select(
            detectedClass: detectedClass,
            classificationIdentifiers: identifiers)
    }

    private static func classificationIdentifiers(
        imageURL: URL,
        boundingBox: [Double]?
    ) -> [String] {
        guard let image = NSImage(contentsOf: imageURL),
              let cgImage = image.cgImage(
                forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        let request = VNClassifyImageRequest()
        if let region = normalizedRegion(
            boundingBox, width: cgImage.width, height: cgImage.height) {
            request.regionOfInterest = region
        }
        let handler = VNImageRequestHandler(cgImage: cgImage)
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? [])
            .filter { $0.confidence >= 0.01 }
            .prefix(30)
            .map(\.identifier)
    }

    private static func normalizedRegion(
        _ boundingBox: [Double]?,
        width: Int,
        height: Int
    ) -> CGRect? {
        guard let boundingBox, boundingBox.count == 4,
              width > 0, height > 0 else { return nil }
        let x1 = max(0, min(Double(width), boundingBox[0]))
        let y1 = max(0, min(Double(height), boundingBox[1]))
        let x2 = max(x1, min(Double(width), boundingBox[2]))
        let y2 = max(y1, min(Double(height), boundingBox[3]))
        guard x2 > x1, y2 > y1 else { return nil }
        return CGRect(
            x: x1 / Double(width),
            y: 1 - y2 / Double(height),
            width: (x2 - x1) / Double(width),
            height: (y2 - y1) / Double(height))
    }
}
