import Foundation

enum MainWindowLayout {
    static func contentSize(hasClipSelection: Bool,
                            hasDetection: Bool,
                            isProcessing: Bool,
                            visibleHeight: CGFloat) -> CGSize {
        let target: CGSize
        if hasClipSelection {
            target = CGSize(width: 640, height: 650)
        } else if hasDetection {
            target = CGSize(width: 320, height: 560)
        } else if isProcessing {
            target = CGSize(width: 320, height: 380)
        } else {
            target = CGSize(width: 320, height: 300)
        }
        let availableHeight = max(260, visibleHeight - 80)
        return CGSize(width: target.width,
                      height: min(target.height, availableHeight))
    }
}
