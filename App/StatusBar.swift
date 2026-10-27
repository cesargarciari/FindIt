import FindItCore
import SwiftUI

struct StatusBar: View {
    let library: Library

    var body: some View {
        HStack(spacing: 12) {
            if let counts = library.counts {
                Text("Indexed \(counts.indexed)")
                Text("Pending \(counts.pending)")
                Text("Failed \(counts.failed)")
            }
            if let note = library.indexingNote {
                Text(note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(note)
            }
            Spacer()
            Button("Retry failed") {
                Task { await library.retryFailed() }
            }
            .disabled((library.counts?.failed ?? 0) == 0)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
