import Foundation

enum TrackMatteCommand {
    static func arguments(
        scriptPath: String,
        videoPath: String,
        outputDir: String,
        clickX: Int,
        clickY: Int,
        bbox: [Double]? = nil,
        startTime: Double = -1,
        duration: Double = -1,
        skipsQualityCheck: Bool = false,
        assetProfile: PetAssetProfile = .standard
    ) -> [String] {
        var arguments = [
            scriptPath,
            "--video", videoPath,
            "--output-dir", outputDir,
            "--preview-seconds", "5",
            "--max-seconds", "15",
            "--fps", "\(assetProfile.frameRate)",
            "--max-output-dimension", "\(assetProfile.maximumOutputDimension)",
            "--click", "\(clickX),\(clickY)",
        ]
        if skipsQualityCheck {
            // White studio backgrounds are valid for model-generated motion.
            arguments.append("--skip-qa")
        }
        if let bbox, bbox.count == 4 {
            arguments += ["--bbox", bbox.map { String($0) }.joined(separator: ",")]
        }
        if startTime >= 0 {
            arguments += ["--start", "\(startTime)"]
            if duration > 0 {
                arguments += ["--duration", "\(duration)"]
            }
        }
        return arguments
    }
}
