import SwiftUI

/// How the tool rail lays out its tools: one column as it always has, or two for a rail about half as tall when one
/// doesn't fit.
enum ToolRailLayout {
    static let buttonSize: CGFloat = 36
    static let columnSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 10

    /// 56 pt in one column; 92 in two (two buttons, the gap between them and 6 pt margins each side).
    static func width(columns: Int) -> CGFloat {
        columns >= 2 ? buttonSize * 2 + columnSpacing + 12 : 56
    }

    /// The tools in rows of `columns`, in the rail's order read left to right.
    static func rows(_ tools: [NavigationTool], columns: Int) -> [[NavigationTool]] {
        let count = min(2, max(1, columns))
        return stride(from: 0, to: tools.count, by: count).map { Array(tools[$0..<min($0 + count, tools.count)]) }
    }
}

/// The tools down the left of the window, with the color swatches under them: in one column while it fits the
/// window's height, otherwise in two, which scroll if the window is shorter still.
struct ToolRail: View {
    @Bindable var session: EditorSession

    var body: some View {
        ViewThatFits(in: .vertical) {
            ToolRailStack(session: session, columns: 1)
            // Scrolls when the window is too short for every tool, rather than pushing the bars above and below away.
            IndicatorlessScrollView { ToolRailStack(session: session, columns: 2) }
                .frame(width: ToolRailLayout.width(columns: 2))
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The rail's contents: the tools in rows, and the color swatches.
struct ToolRailStack: View {
    @Bindable var session: EditorSession
    let columns: Int

    private var tools: [NavigationTool] { NavigationTool.allCases.filter { $0 != .idle } }

    var body: some View {
        let width = ToolRailLayout.width(columns: columns)
        let twoColumns = columns >= 2
        VStack(spacing: ToolRailLayout.rowSpacing) {
            ForEach(Array(ToolRailLayout.rows(tools, columns: columns).enumerated()), id: \.offset) { _, row in
                HStack(spacing: ToolRailLayout.columnSpacing) {
                    ForEach(row, id: \.self) { toolButton($0) }
                }
                // A lone last tool stays in the left column.
                .frame(width: twoColumns ? ToolRailLayout.buttonSize * 2 + ToolRailLayout.columnSpacing : ToolRailLayout.buttonSize,
                       alignment: .leading)
            }
            ColorPaletteControls(session: session).padding(.top, 8)
        }
        .padding(.top, 16).padding(.bottom, 12)
        .frame(width: width)
    }

    // The rail's button in pieces: as one expression the type checker times out (Xcode 26.6).
    @ViewBuilder private func toolIcon(_ tool: NavigationTool) -> some View {
        if tool == .gradient { GradientToolIcon().frame(width: 18, height: 18) }
        else if tool == .cloneStamp { CloneStampToolIcon().frame(width: 18, height: 18) }
        else if tool == .slice { SliceToolIcon().frame(width: 18, height: 18) }
        else if tool == .lasso, session.lassoKind == .polygonal { PolygonalLassoToolIcon().frame(width: 18, height: 18) }
        else if tool == .wand, session.wandMode == .object { ObjectSelectionToolIcon().frame(width: 18, height: 18) }
        // The Shape tool's icon is the shape it draws.
        else if tool == .shape { Image(systemName: session.shapeKind.symbol).font(.system(size: 17)) }
        else if tool == .pathSelection { PathSelectionToolIcon(direct: session.pathSelectionMode == .direct).frame(width: 18, height: 18) }
        else if tool == .pen { PenToolIcon(mode: session.penMode).frame(width: 18, height: 18) }
        // The Marquee's icon follows its shape: a dashed circle in Ellipse mode.
        else { Image(systemName: tool == .marquee && session.marqueeKind == .ellipse ? "circle.dashed" : session.symbol(for: tool)).font(.system(size: 17)) }
    }

    private func toolButton(_ tool: NavigationTool) -> some View {
        let selected = session.tool == tool
        let flyout = tool == .shape || tool == .pathSelection || tool == .pen
        return Button { session.selectTool(tool) } label: {
            toolIcon(tool)
                .frame(width: ToolRailLayout.buttonSize, height: ToolRailLayout.buttonSize)
                .overlay(alignment: .bottomTrailing) { if flyout { ToolFlyoutCorner().padding(4) } }
                .background(selected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.white.opacity(0.14) : .clear) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(tool.label).accessibilityLabel(tool.label)
        .foregroundStyle(.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay { toolFlyout(tool) }
    }

    /// Holding the Shape tool, or right-clicking it, shows every shape it draws; the Path Selection tool, its two modes;
    /// the Pen tool, its five.
    @ViewBuilder private func toolFlyout(_ tool: NavigationTool) -> some View {
        if tool == .shape {
            PressAndHold(click: { session.selectTool(.shape) }, hold: { ShapeToolMenu.show(for: session) })
                .accessibilityHidden(true)
        } else if tool == .pathSelection {
            PressAndHold(click: { session.selectTool(.pathSelection) }, hold: { PathSelectionToolMenu.show(for: session) })
                .accessibilityHidden(true)
        } else if tool == .pen {
            PressAndHold(click: { session.selectTool(.pen) }, hold: { PenToolMenu.show(for: session) })
                .accessibilityHidden(true)
        }
    }
}
