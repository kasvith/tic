import AppKit
import SwiftUI

/// The update window: the notes for every version since this one (newest first), then Update Later /
/// Update Now. Update Now installs in place (`UpdateChecker.install`); progress and any failure show in
/// the footer, so it never goes quiet before Tic restarts. Built like the MCP setup window (an NSPanel
/// hosting SwiftUI, owned by `AppModel`).
struct UpdateView: View {
    @State private var model = AppModel.shared
    private var updates: UpdateChecker { model.updates }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let release = updates.available, let current = updates.currentVersion {
                header(release, current: current)
                notes(release.notes(since: current))
                Divider().opacity(0.5)
                footer(release)
            }
        }
        .frame(width: 460, height: 440)
        .background(.regularMaterial)
        .ignoresSafeArea()               // else the hidden title bar leaves a blank strip on top
        .onExitCommand { model.dismissUpdate() }
    }

    private func header(_ release: UpdateChecker.Release, current: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Tic v\(release.version) is available").font(.system(size: 17, weight: .semibold))
                Text("You have v\(current)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.dismissUpdate() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain).help("Close (Esc)")
        }
        .padding(18)
    }

    private func notes(_ notes: [ReleaseNotes]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if notes.isEmpty {
                    Text("See the release page for what's new.").foregroundStyle(.secondary)
                }
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("v\(note.version)").font(.headline)
                            if let date = note.date {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(Array(note.sections.enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 4) {
                                if !section.title.isEmpty {
                                    Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text((try? AttributedString(markdown: item)) ?? AttributedString(item))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private func footer(_ release: UpdateChecker.Release) -> some View {
        HStack(spacing: 10) {
            switch updates.installState {
            case .idle:
                Text("Tic restarts to finish; your lists are kept.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Update Later") { model.dismissUpdate() }.keyboardShortcut(.cancelAction)
                Button("Update Now") { updates.install() }.keyboardShortcut(.defaultAction)
            case .installing:
                ProgressView().controlSize(.small)
                Text("Installing v\(release.version)…").font(.callout).foregroundStyle(.secondary)
                Spacer()
            case .failed(let reason):
                Text("Couldn't update: \(reason)").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Open Release Page") { updates.openReleasePage() }
                Button("Close") { model.dismissUpdate() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}
