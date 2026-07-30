import AppKit
import Combine
import SwiftUI

struct ActionReviewView: View {
    let review: PetListViewModel.PendingActionReview
    let onAccept: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(review.origin == .generated ? "确认生成动作" : "确认实拍响应")
                    .font(.title3.weight(.semibold))
                Text(review.kind.displayName)
                    .font(.subheadline)
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
                Button("安装动作", action: onAccept)
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
    @State private var frames: [URL] = []
    @State private var frameIndex = 0

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
            if let image = currentImage {
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
        .onAppear(perform: loadFrames)
        .onReceive(ticker) { _ in
            guard !frames.isEmpty else { return }
            frameIndex = (frameIndex + 1) % frames.count
        }
    }

    private var currentImage: NSImage? {
        guard frames.indices.contains(frameIndex) else { return nil }
        return NSImage(contentsOf: frames[frameIndex])
    }

    private func loadFrames() {
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
        frameIndex = 0
    }
}
