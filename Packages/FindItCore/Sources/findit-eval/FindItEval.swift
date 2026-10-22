import ArgumentParser
import FindItCore
import Foundation

@main
struct FindItEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "findit-eval",
        subcommands: [Index.self, Derive.self, Describe.self]
    )
}

struct Describe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Describe images with a vision model and print each result and how long it took.",
        discussion: "The first image's time includes loading the model into memory."
    )

    @Argument(help: "One or more image files.")
    var images: [String]

    @Option(help: "Ollama vision model.")
    var model = "qwen3-vl:8b"

    @Option(help: "Longest side in pixels before sending; 0 sends full size.")
    var maxDimension = 1024

    @Option(help: "Sampling temperature. Omit to use the model's default.")
    var temperature: Double?

    func validate() throws {
        guard maxDimension >= 0 else { throw ValidationError("--max-dimension must be 0 or more.") }
    }

    func run() async throws {
        let client = OllamaClient()
        let resizer = ImageResizer()
        let clock = ContinuousClock()
        var failures = 0

        for path in images {
            let url = URL(fileURLWithPath: path)
            print("== \(url.lastPathComponent)")
            let start = clock.now
            let raw: String
            // One bad image or a timeout shouldn't stop the remaining images.
            do {
                let jpeg = try resizer.jpegData(forImageAt: url, maxDimension: maxDimension == 0 ? nil : maxDimension)
                raw = try await client.describe(
                    imageJPEG: jpeg,
                    prompt: describePrompt,
                    schemaJSON: describeSchemaJSON,
                    model: model,
                    temperature: temperature
                )
            } catch {
                failures += 1
                print("failed: \(error)")
                print()
                continue
            }
            let elapsed = start.duration(to: clock.now)

            do {
                let result = try decodeDescription(raw)
                print("description: \(result.description)")
                print("category:    \(result.category)")
                print("language:    \(result.language)")
                print("entities:    \(result.entities.joined(separator: ", "))")
            } catch {
                print("could not decode (\(error)); raw response:")
                print(raw)
            }
            // Resize plus the describe call, so it reflects what indexing one screenshot costs.
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print(String(format: "seconds:     %.2f", seconds))
            print()
        }

        if failures > 0 {
            throw ExitCode.failure
        }
    }
}
