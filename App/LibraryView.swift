import SwiftUI

/// The main window: search field, results grid and indexing status.
struct LibraryView: View {
    let library: Library
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if library.meaningUnavailable {
                meaningNotice
            }
            Divider()
            results
            Divider()
            StatusBar(library: library)
        }
        // Restarts on every keystroke; the short sleep means only a pause in typing searches.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await library.search(query)
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Describe a screenshot, in English or Spanish", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
        }
        .padding(12)
    }

    private var meaningNotice: some View {
        Label("Meaning search unavailable: Ollama isn't running, so only keyword matches are shown.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.yellow.opacity(0.2))
    }

    @ViewBuilder private var results: some View {
        if let error = library.searchError {
            ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView("Search your screenshots", systemImage: "photo.stack",
                                   description: Text("Type what you remember: words on screen, or what it showed."))
        } else if library.results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(library.results) { item in
                        ResultCell(item: item)
                    }
                }
                .padding(16)
            }
        }
    }
}
