import AppKit
import Foundation
import Vision

enum PetFeatureExtractor {
    private static let minimumConfidence: Float = 0.35

    static func extract(from framesDirectory: URL) -> PetFeatureManifest? {
        guard #available(macOS 14.0, *) else { return nil }
        let frames = frameURLs(in: framesDirectory)
        guard !frames.isEmpty else { return nil }
        let sampled = sample(frames, maximum: 12)
        return sampled.compactMap { candidate(for: $0) }
            .max(by: { $0.confidence < $1.confidence })
    }

    private static func candidate(for frameURL: URL) -> PetFeatureManifest? {
        guard let image = NSImage(contentsOf: frameURL),
              let cgImage = image.cgImage(
                forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let request = VNDetectAnimalBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = (request.results ?? []).max(by: {
            $0.confidence < $1.confidence
        }) else { return nil }

        let leftEye = landmark(observation, joint: .leftEye)
        let rightEye = landmark(observation, joint: .rightEye)
        let nose = landmark(observation, joint: .nose)
        let leftEar = landmark(observation, joint: .leftEarTop)
        let rightEar = landmark(observation, joint: .rightEarTop)
        let neck = landmark(observation, joint: .neck)
        let leftFrontPaw = landmark(observation, joint: .leftFrontPaw)
        let rightFrontPaw = landmark(observation, joint: .rightFrontPaw)
        let head = headRegion(
            landmarks: [leftEye, rightEye, nose, leftEar, rightEar, neck]
                .compactMap { $0 })
        guard head != nil || (leftEye != nil && rightEye != nil && nose != nil) else {
            return nil
        }
        let points = [leftEye, rightEye, nose, leftEar, rightEar, neck]
            .compactMap { $0 }
        let confidence = points.map(\.confidence).reduce(0, +)
            / Double(max(1, points.count))
        return PetFeatureManifest(
            version: PetFeatureManifest.currentVersion,
            sourceFrame: frameURL.lastPathComponent,
            confidence: confidence,
            head: head,
            leftEye: leftEye,
            rightEye: rightEye,
            nose: nose,
            leftFrontPaw: leftFrontPaw,
            rightFrontPaw: rightFrontPaw)
    }

    private static func landmark(
        _ observation: VNAnimalBodyPoseObservation,
        joint: VNAnimalBodyPoseObservation.JointName
    ) -> PetFeatureManifest.Landmark? {
        guard let point = try? observation.recognizedPoint(joint),
              point.confidence >= minimumConfidence else { return nil }
        return PetFeatureManifest.Landmark(
            x: Double(point.location.x),
            y: Double(point.location.y),
            confidence: Double(point.confidence))
    }

    private static func headRegion(
        landmarks: [PetFeatureManifest.Landmark]
    ) -> PetFeatureManifest.Region? {
        guard landmarks.count >= 3 else { return nil }
        let minX = landmarks.map(\.x).min() ?? 0
        let maxX = landmarks.map(\.x).max() ?? 1
        let minY = landmarks.map(\.y).min() ?? 0
        let maxY = landmarks.map(\.y).max() ?? 1
        // Extend around the feature cluster. The lower extension includes the
        // mouth while the upper extension covers ears without claiming torso.
        let paddingX = max(0.06, (maxX - minX) * 0.65)
        let paddingY = max(0.06, (maxY - minY) * 0.45)
        let x = max(0, minX - paddingX)
        let y = max(0, minY - paddingY * 0.8)
        let right = min(1, maxX + paddingX)
        let top = min(1, maxY + paddingY)
        let confidence = landmarks.map(\.confidence).reduce(0, +)
            / Double(landmarks.count)
        guard right > x, top > y else { return nil }
        return PetFeatureManifest.Region(
            x: x, y: y, width: right - x, height: top - y,
            confidence: confidence)
    }

    private static func frameURLs(in directory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        let pngs = entries.filter {
            $0.pathExtension.lowercased() == "png"
                && $0.lastPathComponent.hasPrefix("frame_")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if !pngs.isEmpty { return pngs }
        return entries.filter {
            $0.pathExtension.lowercased() == "jpg"
                && $0.lastPathComponent.hasPrefix("frame_")
                && !$0.lastPathComponent.hasSuffix("_a.jpg")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func sample(_ frames: [URL], maximum: Int) -> [URL] {
        guard frames.count > maximum else { return frames }
        return (0..<maximum).map { index in
            frames[index * (frames.count - 1) / max(1, maximum - 1)]
        }
    }
}
