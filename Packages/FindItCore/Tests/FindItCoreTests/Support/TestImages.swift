import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds test images in code, so no test depends on real screenshots.
enum TestImages {
    /// A white image of the given size, with optional drawing on top.
    static func make(width: Int, height: Int, draw: (CGContext) -> Void = { _ in }) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return context.makeImage()!
    }

    struct FontNotLoaded: Error {
        let requested: String
        let got: String
    }

    /// Black text drawn large on a white background, in Menlo.
    /// Throws if Menlo didn't load, because a substitute font can bring back look-alike glyphs.
    static func text(_ string: String, width: Int = 1200, height: Int = 300) throws -> CGImage {
        // Menlo ships with every macOS and draws a capital I and a lowercase l differently, unlike Helvetica.
        let fontName = "Menlo-Regular"
        let font = CTFontCreateWithName(fontName as CFString, 96, nil)
        let loadedName = CTFontCopyPostScriptName(font) as String
        guard loadedName == fontName else {
            throw FontNotLoaded(requested: fontName, got: loadedName)
        }
        return make(width: width, height: height) { context in
            let attributed = NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 40, y: height / 2 - 30)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
    }

    /// Writes the image to `url` in the given format. `orientation` sets the EXIF orientation tag.
    static func write(_ image: CGImage, to url: URL, type: UTType = .png, orientation: CGImagePropertyOrientation? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation.rawValue
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Pixel size of encoded image data.
    static func size(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (image.width, image.height)
    }
}

// Cleanup runs in a defer rather than a deinit, because the optimizer may release
// a local object before the end of its scope and delete the folder too early.

/// Runs `body` with a fresh folder under the system temp directory, then removes it.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "FindItTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
