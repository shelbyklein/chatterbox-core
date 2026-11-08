import SwiftUI

/// Global archive browser. Searching uses loaded list metadata, never loads transcripts.
struct ArchivedThreadsView: View {
    @Environment(AppModel.self) private var model
    @Binding var search: String
    let menu: (ChatSession) -> AnyView

    var body: some View {
        let all = model.archivedSessions
        let matches = model.archivedSessions(matching: search)
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Archived").font(.largeTitle.weight(.semibold))
                Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "\(all.count) threads" : "\(matches.count) of \(all.count) threads")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search archived threads", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("archive-search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear archive search")
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            if matches.isEmpty {
                ContentUnavailableView {
                    Label(all.isEmpty ? "No archived threads" : "No matching threads", systemImage: all.isEmpty ? "archivebox" : "magnifyingglass")
                } description: {
                    Text(all.isEmpty ? "Threads you archive will appear here." : "Try another title, project, Studio or tag.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(matches) { session in
                            ThreadCard(session: session) { model.selectedID = session.id }
                                .contextMenu { menu(session) }
                                .accessibilityIdentifier("archived-thread-\(session.id)")
                        }
                    }
                    .padding(.bottom, 16)
                }
                .accessibilityIdentifier("archived-thread-results")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("archived-threads-view")
    }
}
