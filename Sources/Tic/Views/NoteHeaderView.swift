import SwiftUI

/// The hover-reveal control strip + editable title for a sticky note. Controls fade in/out via
/// `isRevealed` (driven by `NoteView`'s hover over the whole note), so the affordances stay
/// hidden until the pointer is on the note — keeping the small note uncluttered.
struct NoteHeaderView: View {
    @Bindable var controller: NoteController
    let theme: NoteTheme
    let isRevealed: Bool

    @Binding var titleText: String
    @FocusState.Binding var titleFocused: Bool

    @State private var showColorPopover = false
    @State private var hoverClose = false

    private var note: Note { controller.note }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controlStrip
                .opacity(isRevealed ? 1 : 0)
                .allowsHitTesting(isRevealed)

            TextField("Title", text: $titleText)
                .textFieldStyle(.plain)
                .font(.headline.weight(.semibold))
                .foregroundStyle(theme.title)
                .focused($titleFocused)
                .onSubmit { controller.commitTitle(titleText) }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { controller.commitTitle(titleText) }
                }

            Rectangle()
                .fill(theme.accent.opacity(0.35))
                .frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // The header is the window's drag handle; double-clicking its chrome rolls the note up.
        .background(WindowMoveArea { controller.toggleCollapsed() })
    }

    // MARK: - Control strip

    private var controlStrip: some View {
        HStack(spacing: 10) {
            colorButton
            materialButton
            Spacer(minLength: 0)
            collapseButton
            floatButton
            closeButton
        }
        .frame(height: 22)
        .animation(.easeInOut(duration: 0.15), value: isRevealed)
    }

    private var colorButton: some View {
        Button {
            showColorPopover.toggle()
        } label: {
            Circle()
                .fill(theme.accent)
                .frame(width: 13, height: 13)
                .overlay(Circle().strokeBorder(theme.secondary.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help("Note color")
        .popover(isPresented: $showColorPopover, arrowEdge: .bottom) { colorPicker }
    }

    private var colorPicker: some View {
        let columns = Array(repeating: GridItem(.fixed(26), spacing: 8), count: 3)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(NoteColor.allCases) { swatch in
                Button {
                    controller.setColor(swatch)
                    showColorPopover = false
                } label: {
                    Circle()
                        .fill(swatch.fill)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().strokeBorder(
                                swatch == note.color ? swatch.accent : Color.black.opacity(0.12),
                                lineWidth: swatch == note.color ? 2.5 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .help(swatch.displayName)
            }
        }
        .padding(12)
    }

    private var materialButton: some View {
        let isGlass = note.material == .glass
        return iconButton(
            systemName: isGlass ? "sparkles" : "circle.hexagongrid",
            isActive: isGlass,
            help: isGlass ? "Switch to solid" : "Switch to glass"
        ) {
            controller.toggleMaterial()
        }
    }

    private var collapseButton: some View {
        iconButton(systemName: "chevron.up", isActive: false, help: "Roll up") {
            controller.toggleCollapsed()
        }
    }

    private var floatButton: some View {
        let isFloating = note.floatOnTop
        return iconButton(
            systemName: isFloating ? "pin.fill" : "pin",
            isActive: isFloating,
            help: isFloating ? "Unpin from top" : "Keep on top"
        ) {
            controller.toggleFloatOnTop()
        }
    }

    private var closeButton: some View {
        Button {
            controller.requestClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hoverClose ? Color.red : theme.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverClose = $0 }
        .help("Close note")
    }

    private func iconButton(
        systemName: String,
        isActive: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? theme.accent : theme.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
