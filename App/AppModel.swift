import FindItCore
import Foundation

/// First-launch setup: Ollama, its models and the watched folder. Once all are ready it opens the Library.
@Observable final class AppModel {
    enum Phase: Equatable {
        case checking
        case ollamaNotRunning
        case modelsMissing([String])
        case downloading(model: String, progress: PullProgress?)
        case downloadFailed(String)
        case needsFolder
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .checking
    private(set) var library: Library?

    private let client = OllamaClient()
    private let config = IndexConfig()
    private var launched = false

    func launch() async {
        guard !launched else { return }
        launched = true
        // A folder chosen on an earlier launch means setup is done; search works without Ollama.
        if let folder = FolderAccess.restore() {
            open(folder)
        } else {
            await checkOllama()
        }
    }

    func checkOllama() async {
        phase = .checking
        guard let installed = try? await client.installedModels() else {
            phase = .ollamaNotRunning
            return
        }
        let missing = [config.describerModel, config.embedderModel]
            .filter { !OllamaClient.isInstalled($0, in: installed) }
        phase = missing.isEmpty ? .needsFolder : .modelsMissing(missing)
    }

    func download(_ models: [String]) async {
        for model in models {
            phase = .downloading(model: model, progress: nil)
            do {
                for try await progress in client.pull(model) {
                    phase = .downloading(model: model, progress: progress)
                }
            } catch {
                phase = .downloadFailed("Couldn't download \(model): \(error)")
                return
            }
        }
        phase = .needsFolder
    }

    /// `folder` comes from the folder picker, which grants sandbox access to it.
    func choose(_ folder: URL) {
        guard folder.startAccessingSecurityScopedResource() else {
            phase = .failed("FindIt wasn't given access to \(folder.path).")
            return
        }
        do {
            try FolderAccess.save(folder)
        } catch {
            phase = .failed("Couldn't remember the folder: \(error.localizedDescription)")
            return
        }
        open(folder)
    }

    private func open(_ folder: URL) {
        do {
            let library = try Library(databaseURL: try Self.databaseURL(), folder: folder)
            library.start()
            self.library = library
            phase = .ready
        } catch {
            phase = .failed("Couldn't open the database: \(error.localizedDescription)")
        }
    }

    /// Inside the sandbox this is the app container's Application Support folder.
    private static func databaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = support.appending(path: "FindIt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "FindIt.sqlite")
    }
}
