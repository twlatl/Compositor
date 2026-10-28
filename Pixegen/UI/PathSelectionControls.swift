import AppKit
import SwiftUI

struct PathSelectionControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 12) {
            Text("Path Selection").font(ToolHeaderStyle.titleFont)
            Picker("Mode", selection: Binding(get: { session.pathSelectionMode }, set: { mode in
                session.pathSelectionMode = mode
                if mode == .path { session.selectedPathKnots = [] }
            })) {
                Text("Path").tag(PathSelectionMode.path)
                Text("Direct").tag(PathSelectionMode.direct)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Shift-A (or Tab) switches between Path Selection and Direct Selection")
            if session.pathTextLayer != nil, session.pathLayer == nil {
                if session.pathSelectionMode == .direct {
                    Button("Delete Points") { session.deleteSelectedPathKnots() }
                        .disabled(session.selectedPathKnots.isEmpty)
                        .help("Remove the selected anchor points (Delete)")
                }
                Text(session.pathSelectionMode == .direct
                     ? "Drag points to reshape the path, or the text to slide it along"
                     : "Drag the text along its path to slide it, or across to flip it")
                    .foregroundStyle(.secondary)
            } else if session.pathLayer == nil {
                Text("Click a shape to select its path").foregroundStyle(.secondary)
            } else {
                if session.pathSelectionMode == .direct {
                    Button("Delete Points") { session.deleteSelectedPathKnots() }
                        .disabled(session.selectedPathKnots.isEmpty || session.pathLayer?.liveShape?.style.kind == .line)
                        .help("Remove the selected anchor points (Delete)")
                }
                // The selected shape's fill, stroke and the rest, to change in place.
                ShapeStyleControls(session: session)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }
}

/// Photoshop's selection arrows: solid for Path Selection, hollow for Direct Selection.
struct PathSelectionToolIcon: View {
    var direct: Bool
    var body: some View {
        let arrow = ArrowShape()
        Group {
            if direct { arrow.stroke(.primary, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round)) }
            else { arrow.fill(.primary) }
        }
        .accessibilityHidden(true)
    }

    private struct ArrowShape: Shape {
        /// The canvas pointer's own arrow, so the icon and the pointer are the same shape.
        func path(in rect: CGRect) -> Path {
            let points = CanvasView.arrowOutline
            let height = points.map(\.y).max() ?? 1, width = points.map(\.x).max() ?? 1
            let scale = rect.height / height
            let left = rect.midX - width * scale / 2
            var path = Path()
            path.addLines(points.map { CGPoint(x: left + $0.x * scale, y: rect.minY + $0.y * scale) })
            path.closeSubpath()
            return path
        }
    }
}

/// The Path Selection tool's flyout: its two modes, the current one checked.
@MainActor
enum PathSelectionToolMenu {
    static func show(for session: EditorSession) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let menu = NSMenu()
        for mode in PathSelectionMode.allCases {
            let item = ActionMenuItem(title: mode.toolName) {
                session.pathSelectionMode = mode
                if mode == .path { session.selectedPathKnots = [] }
                session.selectTool(.pathSelection)
            }
            item.image = NSImage(systemSymbolName: mode == .path ? "cursorarrow" : "cursorarrow.rays", accessibilityDescription: nil)
            item.state = session.tool == .pathSelection && mode == session.pathSelectionMode ? .on : .off
            // Shown, not bound: A picks the tool, Shift-A the other mode.
            item.keyEquivalent = "a"
            item.keyEquivalentModifierMask = []
            menu.addItem(item)
        }
        let location = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: location, in: view)
    }
}
