import AppKit
import Combine
import ImageIO
import SwiftUI

struct ActionReviewView: View {
    let review: PetListViewModel.PendingActionReview
    let onAccept: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(review.origin == .generated ? "确认生成动作" : "确认自定义动作")
                    .font(.title3.weight(.semibold))
                Text(review.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("确认预览中的宠物动作确实为「\(review.displayName)」后再安装")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            CapturedFrameSequencePreview(
                framesDirectory: review.framesDirectory,
                fps: review.fps)

            HStack(spacing: 8) {
                Label("\(review.frameCount) 帧", systemImage: "film")
                Label("\(review.fps) FPS", systemImage: "speedometer")
                if let identitySimilarity = review.identitySimilarity {
                    Label(
                        String(format: "外观 %.0f%%", identitySimilarity * 100),
                        systemImage: "checkmark.seal")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            HStack {
                Button("丢弃", role: .cancel, action: onDiscard)
                Spacer()
                Button("确认语义并安装", action: onAccept)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430, height: 455)
    }
}

private struct CapturedFrameSequencePreview: View {
    let framesDirectory: String
    private let ticker: Publishers.Autoconnect<Timer.TimerPublisher>
    @StateObject private var preview = ActionReviewFrameCache()

    init(framesDirectory: String, fps: Int) {
        self.framesDirectory = framesDirectory
        ticker = Timer.publish(
            every: 1.0 / Double(max(1, fps)), on: .main, in: .common
        ).autoconnect()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.08))
            if let image = preview.currentImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(12)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(height: 285)
        .onAppear { preview.load(from: framesDirectory) }
        .onReceive(ticker) { _ in
            preview.advance()
        }
    }
}

@MainActor
private final class ActionReviewFrameCache: ObservableObject {
    @Published private(set) var currentImage: NSImage?
    private let cache = NSCache<NSString, NSImage>()
    private let decodeQueue = DispatchQueue(
        label: "com.realpet.action-review-decoder", qos: .userInitiated)
    private var frames: [URL] = []
    private var frameIndex = 0
    private var requestGeneration = 0

    init() {
        cache.countLimit = 12
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func load(from framesDirectory: String) {
        let directory = URL(fileURLWithPath: framesDirectory)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)) ?? []
        frames = urls.filter { url in
            let name = url.lastPathComponent.lowercased()
            return name.hasPrefix("frame_")
                && !name.hasSuffix("_a.jpg")
                && ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        frames = urls
        frameIndex = 0
        requestGeneration &+= 1
        displayCurrentFrame()
    }

    func advance() {
        guard !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
        displayCurrentFrame()
    }

    private func displayCurrentFrame() {
        guard frames.indices.contains(frameIndex) else {
            currentImage = nil
            return
        }
        let url = frames[frameIndex]
        let key = url.path
        if let image = cache.object(forKey: key as NSString) {
            currentImage = image
            return
        }
        let generation = requestGeneration
        decodeQueue.async { [weak self] in
            let image = Self.downsampledImage(at: url, maximumPixelDimension: 640)
            let cost = Self.cost(of: image)
            DispatchQueue.main.async {
                guard let self, self.requestGeneration == generation,
                      self.frames.indices.contains(self.frameIndex),
                      self.frames[self.frameIndex] == url else { return }
                if let image {
                    self.cache.setObject(image, forKey: key as NSString, cost: cost)
                }
                self.currentImage = image
            }
        }
    }

    nonisolated private static func downsampledImage(
        at url: URL,
        maximumPixelDimension: Int
    ) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: false,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
              ] as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(
            width: image.width, height: image.height))
    }

    nonisolated private static func cost(of image: NSImage?) -> Int {
        guard let representation = image?.representations.first else { return 1 }
        return max(1, representation.pixelsWide * representation.pixelsHigh * 4)
    }
}
