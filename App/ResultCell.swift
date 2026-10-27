import AppKit
import FindItCore
import SwiftUI

struct ResultCell: View {
    let item: ResultItem
    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: openInPreview) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(item.description.isEmpty ? fileName : item.description)
                    .font(.callout)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                FoundByTag(foundBy: item.foundBy)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(fileName)
        .task(id: item.path) {
            thumbnail = await Thumbnail.load(path: item.path, maxPixels: 400)
        }
    }

    private var fileName: String {
        URL(fileURLWithPath: item.path).lastPathComponent
    }

    private func openInPreview() {
        let file = URL(fileURLWithPath: item.path)
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(file)
            return
        }
        NSWorkspace.shared.open([file], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Shows which search found a result.
struct FoundByTag: View {
    let foundBy: FoundBy

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var label: String {
        switch foundBy {
        case .keyword: "Keyword"
        case .meaning: "Meaning"
        case .both: "Both"
        }
    }

    private var color: Color {
        switch foundBy {
        case .keyword: .blue
        case .meaning: .purple
        case .both: .green
        }
    }
}
