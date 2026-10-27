import SwiftUI

/// The Move and Path Selection bars' Arrange button: a popover of Align and Distribute for the selected layers.
struct ArrangeButton: View {
    @Bindable var session: EditorSession
    @State private var showsPanel = false

    var body: some View {
        Button { showsPanel = true } label: {
            Image(systemName: "align.horizontal.left").frame(width: 16, height: 16).padding(3).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Arrange: align and distribute the selected layers")
        .accessibilityLabel("Arrange")
        .disabled(session.showsBusy || session.alignmentItems.isEmpty)
        .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
            ArrangePanel(session: session)
        }
    }
}

struct ArrangePanel: View {
    @Bindable var session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Align:").font(.headline)
            row(LayerAlignment.aligns)
            Divider()
            Text("Distribute:").font(.headline)
            row(LayerAlignment.distributes)
            Divider()
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Distribute Spacing:").font(.headline)
                    HStack(spacing: 8) { ForEach(LayerAlignment.spacings, id: \.self, content: button) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Align To:").font(.headline)
                    Picker("Align To", selection: $session.alignmentTarget) {
                        ForEach(AlignmentTarget.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .help("Line layers up against the box around them all, or against the canvas. One layer always lines up with the canvas.")
                }
            }
        }
        .padding(14)
    }

    /// Six buttons, the across three apart from the up-and-down three.
    private func row(_ alignments: [LayerAlignment]) -> some View {
        HStack(spacing: 8) {
            ForEach(alignments.prefix(3), id: \.self, content: button)
            Spacer().frame(width: 16)
            ForEach(alignments.suffix(3), id: \.self, content: button)
        }
    }

    private func button(_ alignment: LayerAlignment) -> some View {
        let enabled = session.canAlign(alignment)
        // The tip sits on a wrapper: a disabled button shows none of its own, and that's when it has most to say.
        return HStack {
            Button { session.align(alignment) } label: {
                Image(systemName: alignment.systemImage).font(.system(size: 15)).frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .accessibilityLabel(alignment.rawValue)
        }
        .help(alignment.isDistribution && !enabled ? "\(alignment.rawValue) (select three or more layers)" : alignment.rawValue)
    }
}
