import AppKit
import SwiftUI

struct PenControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 12) {
            Text("Pen").font(ToolHeaderStyle.titleFont)
            Picker("Mode", selection: Binding(get: { session.penMode }, set: { mode in
                session.cancelPen()
                session.penMode = mode
            })) {
                ForEach(PenMode.allCases, id: \.self) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Shift-P (or Tab) steps through the Pen tools")
            if session.penMode.draws {
                Picker("Make", selection: Binding(get: { session.penOutput }, set: { output in
                    session.cancelPen()
                    session.penOutput = output
                })) {
                    Text(ShapeMode.shape.rawValue).tag(ShapeMode.shape)
                    Text(ShapeMode.path.rawValue).tag(ShapeMode.path)
                }
                .labelsHidden().fixedSize()
                .help("Shape makes a shape layer; Path, an outline to make a selection from")
                if session.penOutput == .path {
                    Button("Make Selection") { session.makeSelectionFromWorkPath() }
                        .disabled(session.workPath == nil)
                        .help("Select inside the path (Return)")
                }
            } else if session.pathLayer == nil {
                Text(session.penMode == .addAnchor ? "Click a shape's outline to add a point" : "Click a shape's point to remove it")
                    .foregroundStyle(.secondary)
            }
            // Fill and stroke: the selected shape's own, or what the next pen path is drawn with.
            if session.penOutput == .shape || !session.penMode.draws || session.shapeBarLayer != nil {
                ShapeStyleControls(session: session)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }
}

/// The canvas pointer's nib, with a small badge for each mode but the plain Pen.
struct PenToolIcon: View {
    var mode: PenMode
    var body: some View {
        NibShape()
            .fill(.primary, style: FillStyle(eoFill: true))
            .overlay(alignment: .topTrailing) {
                if let badge = mode.badgeSymbol {
                    Image(systemName: badge).font(.system(size: 7, weight: .bold)).offset(x: 3, y: -2)
                }
            }
            .accessibilityHidden(true)
    }

    private struct NibShape: Shape {
        func path(in rect: CGRect) -> Path {
            let nib = CanvasView.penNibPath
            let box = nib.boundingBoxOfPath
            let scale = min(rect.width / box.width, rect.height / box.height)
            var place = CGAffineTransform(translationX: rect.midX - box.midX * scale, y: rect.midY - box.midY * scale).scaledBy(x: scale, y: scale)
            return Path(nib.copy(using: &place) ?? nib)
        }
    }
}

extension PenMode {
    /// The badge on the tool's icon and in its flyout.
    var badgeSymbol: String? {
        switch self {
        case .pen: nil
        case .freeform: "scribble"
        case .curvature: "point.topleft.down.to.point.bottomright.curvepath"
        case .addAnchor: "plus"
        case .deleteAnchor: "minus"
        }
    }
}

/// The Pen tool's flyout: its five modes, the current one checked.
@MainActor
enum PenToolMenu {
    static func show(for session: EditorSession) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let menu = NSMenu()
        for mode in PenMode.allCases {
            let item = ActionMenuItem(title: mode.toolName) {
                session.cancelPen()
                session.penMode = mode
                session.selectTool(.pen)
            }
            item.image = NSImage(systemSymbolName: mode.badgeSymbol ?? "pencil.tip", accessibilityDescription: nil)
            item.state = session.tool == .pen && mode == session.penMode ? .on : .off
            // Shown, not bound: P picks the tool, Shift-P the next mode.
            item.keyEquivalent = "p"
            item.keyEquivalentModifierMask = []
            menu.addItem(item)
        }
        let location = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: location, in: view)
    }
}
