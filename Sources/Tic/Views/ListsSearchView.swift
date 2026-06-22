import SwiftUI

/// The floating "Lists" command palette (Raycast-style): a wide, centered, always-on-top panel
/// with a big search header, keyboard-navigable rows (↑↓ to move, ↩ to open), per-row delete,
/// and a footer action bar. Lives outside `MenuBarExtra`, so `@State`/observation re-render
/// reliably here.
struct ListsSearchView: View {
    @State private var model = AppModel.shared
    @State private var search = ""
    @State private var selectedID: Note.ID?
    @FocusState private var searchFocused: Bool

    private var results: [Note] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let byRecency = model.notes.sorted { $0.updatedAt > $1.updatedAt }
        guard !query.isEmpty else { return byRecency }
        return byRecency.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.5)
            resultsList
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 700, height: 440)
        .background(.regularMaterial)
        .task {
            searchFocused = true
            selectedID = results.first?.id
        }
        .onChange(of: search) { _, _ in selectedID = results.first?.id }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onExitCommand { model.dismissSearch() }
    }

    // MARK: - Search header

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            TextField("Search lists…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($searchFocused)
                .onSubmit { openSelected() }
            Button { model.dismissSearch() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if results.isEmpty {
                        Text(model.notes.isEmpty ? "No lists yet" : "No matches")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    } else {
                        Text(search.isEmpty ? "Recent Lists" : "Results")
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                            .padding(.bottom, 2)

                        ForEach(results) { note in
                            ListRow(
                                note: note,
                                selected: note.id == selectedID,
                                onDelete: { model.delete(note) }
                            )
                            .id(note.id)
                            .onHover { if $0 { selectedID = note.id } }
                            .onTapGesture { selectedID = note.id; openSelected() }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Footer action bar

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Tic Lists").font(.caption).foregroundStyle(.secondary)
            Spacer()
            hint("Navigate", "↑↓")
            hint("Open", "↩")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.04))
    }

    private func hint(_ label: String, _ key: String) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(key)
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Selection / actions

    private func move(_ delta: Int) {
        let ids = results.map(\.id)
        guard !ids.isEmpty else { return }
        let current = selectedID.flatMap { ids.firstIndex(of: $0) } ?? -1
        let next = min(max(current + delta, 0), ids.count - 1)
        selectedID = ids[next]
    }

    private func openSelected() {
        guard let id = selectedID, let note = results.first(where: { $0.id == id }) else { return }
        model.open(note)
        model.dismissSearch()
    }
}

/// A palette row: colour dot + title, a trailing "List" label (Raycast-style), a delete button
/// on hover/selection, and an accent highlight when selected.
private struct ListRow: View {
    let note: Note
    let selected: Bool
    let onDelete: () -> Void

    @State private var hover = false
    @State private var confirming = false

    private var title: String { note.title.isEmpty ? "Untitled List" : note.title }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(note.color.fill)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.black.opacity(0.15)))

            Text(title).lineLimit(1)

            Spacer(minLength: 8)

            if hover || selected {
                Button { confirming = true } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete list")
            }

            Text("List").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .confirmationDialog("Delete “\(title)”?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete List", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the list and its tasks.")
        }
    }
}
