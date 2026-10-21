import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FindItCore

struct ImageResizerTests {
    /// Writes `image` to a temporary file, resizes it, and returns the output's pixel size.
    private func resizedSize(
        of image: CGImage,
        type: UTType = .png,
        orientation: CGImagePropertyOrientation? = nil,
        maxDimension: Int? = 1024
    ) throws -> (width: Int, height: Int)? {
        try withTemporaryDirectory { folder in
            let url = folder.appending(path: "image.\(type.preferredFilenameExtension!)")
            try TestImages.write(image, to: url, type: type, orientation: orientation)
            let data = try ImageResizer().jpegData(forImageAt: url, maxDimension: maxDimension)
            return TestImages.size(of: data)
        }
    }

    @Test(arguments: [UTType.png, .jpeg, .heic])
    func scalesLongestSideTo1024(type: UTType) throws {
        let size = try #require(try resizedSize(of: TestImages.make(width: 3000, height: 2000), type: type))

        #expect(max(size.width, size.height) == 1024)
        #expect(size.width > size.height)
    }

    @Test func nilMaxDimensionKeepsFullResolution() throws {
        let size = try #require(try resizedSize(of: TestImages.make(width: 3000, height: 2000), maxDimension: nil))

        #expect(size.width == 3000)
        #expect(size.height == 2000)
    }

    @Test func doesNotScaleUpSmallImages() throws {
        let size = try #require(try resizedSize(of: TestImages.make(width: 300, height: 200)))

        #expect(size.width == 300)
        #expect(size.height == 200)
    }

    @Test func appliesExifOrientation() throws {
        // Orientation .right means "rotate 90° to display", so a wide image shows tall.
        let size = try #require(try resizedSize(
            of: TestImages.make(width: 300, height: 200),
            type: .jpeg,
            orientation: .right,
            maxDimension: nil
        ))

        #expect(size.width == 200)
        #expect(size.height == 300)
    }

    @Test func unreadableFileThrows() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appending(path: "not-an-image.png")
            try Data("hello".utf8).write(to: url)

            #expect(throws: ImageResizerError.self) {
                try ImageResizer().jpegData(forImageAt: url)
            }
        }
    }
}
