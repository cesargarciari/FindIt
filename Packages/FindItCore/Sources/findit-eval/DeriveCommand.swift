import ArgumentParser
import FindItCore
import Foundation

extension DeriveResetTarget: ExpressibleByArgument {}

struct Derive: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy an eval database and roll it back to an earlier step, to compare another model.",
        discussion: """
            described keeps OCR and descriptions, so only embedding is redone (compare embedders).
            Screenshots that failed after describing get another try.
            ocr_done keeps only OCR, so describing and embedding are redone (compare describers).
            Described screenshots, and ones that failed after OCR, are described again.
            Every retried screenshot starts with a failure count of 0.
            Then run `index --db <to>` with the model to compare.
            """
    )

    @Option(help: "Indexed eval database to copy. It isn't changed.")
    var from: String

    @Option(help: "New database file. Must not exist yet.")
    var to: String

    @Option(help: "described or ocr_done.")
    var resetTo: DeriveResetTarget

    func run() throws {
        let result: DeriveResult
        do {
            result = try deriveDatabase(from: URL(fileURLWithPath: from), to: URL(fileURLWithPath: to), resetTo: resetTo)
        } catch DeriveError.targetExists(let path) {
            throw exitWithMessage("\(path) already exists. Pick a new --to file; it is never overwritten.")
        } catch DeriveError.sourceMissing(let path) {
            throw exitWithMessage("\(path) doesn't exist.")
        }
        print("Wrote \(to): \(result.resetIndexed) indexed screenshots set back to \(resetTo.rawValue).")
        switch resetTo {
        case .described:
            print("\(result.resetFailed) failed screenshots with a description set back to described.")
        case .ocrDone:
            print("\(result.resetDescribed) described screenshots set back to ocr_done.")
            print("\(result.resetFailed) failed screenshots with OCR text set back to ocr_done.")
        }
    }
}
