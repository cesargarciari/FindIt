import FindItCore
import SwiftUI
import UniformTypeIdentifiers

/// The first-launch steps: find Ollama, download missing models, choose a folder.
struct SetupView: View {
    let model: AppModel
    @State private var choosingFolder = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            content
        }
        .padding(40)
        .frame(maxWidth: 480)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result {
                model.choose(folder)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .checking:
            ProgressView("Looking for Ollama…")
        case .ollamaNotRunning:
            step(
                "Ollama isn't running",
                detail: "FindIt describes and searches screenshots with Ollama on this Mac. Start the Ollama app, then try again.",
                button: "Try Again"
            ) { Task { await model.checkOllama() } }
        case .modelsMissing(let models):
            step(
                "FindIt needs \(models.count == 1 ? "a model" : "\(models.count) models")",
                detail: "Ollama will download \(models.joined(separator: " and ")). This can take a while and several GB of disk.",
                button: "Download"
            ) { Task { await model.download(models) } }
        case .downloading(let name, let progress):
            downloading(name, progress: progress)
        case .downloadFailed(let message):
            step("Download failed", detail: message, button: "Try Again") { Task { await model.checkOllama() } }
        case .needsFolder:
            step(
                "Choose a folder to watch",
                detail: "FindIt indexes the screenshots in this folder and checks it for new ones while it runs.",
                button: "Choose Folder…"
            ) { choosingFolder = true }
        case .ready:
            EmptyView()
        case .failed(let message):
            step("Something went wrong", detail: message, button: "Choose Folder…") { choosingFolder = true }
        }
    }

    private func step(_ title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.title2.bold())
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func downloading(_ name: String, progress: PullProgress?) -> some View {
        VStack(spacing: 12) {
            Text("Downloading \(name)").font(.title2.bold())
            // Ollama reports bytes only while a part downloads; other steps show a spinner bar.
            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(progress?.status ?? "Starting…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
