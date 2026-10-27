import CoreGraphics
import Foundation
import ImageIO

nonisolated enum Thumbnail {
    /// A small copy of the image, decoded off the main actor so scrolling stays smooth.
    /// ImageIO reads only what it needs, which is much cheaper than loading the full screenshot.
    @concurrent static func load(path: String, maxPixels: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
