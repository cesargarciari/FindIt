import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageResizerError: Error, Sendable {
    case cannotRead(URL)
    case cannotEncode(URL)
}

/// Turns any image ImageIO can read (PNG, JPEG, HEIC) into upright JPEG data.
public struct ImageResizer: Sendable {
    public init() {}

    /// Scales the image so its longest side is at most `maxDimension`, or keeps full size when nil.
    /// Never scales up.
    public func jpegData(forImageAt url: URL, maxDimension: Int? = 1024, quality: Double = 0.8) throws -> Data {
        // ImageIO treats 0 or less as "no limit", which would silently send full-size images.
        if let maxDimension {
            precondition(maxDimension > 0, "maxDimension must be positive; pass nil for full size")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw ImageResizerError.cannotRead(url)
        }

        let longestSide = max(width, height)
        let targetSide = min(maxDimension ?? longestSide, longestSide)

        // The thumbnail API both scales and applies the EXIF orientation in one step.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageResizerError.cannotRead(url)
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageResizerError.cannotEncode(url)
        }
        let encodeOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageResizerError.cannotEncode(url)
        }
        return output as Data
    }
}
