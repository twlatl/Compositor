import SwiftUI

/// Combine, Subtract, Intersect and Exclude, for the selected shapes. The tool bar shows them while they apply.
struct ShapeOperationButtons: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ShapeOperation.allCases, id: \.self) { operation in
                Button { session.applyShapeOperation(operation) } label: {
                    ShapeOperationIcon(operation: operation).frame(width: 16, height: 16).padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(operation.help)
                .accessibilityLabel(operation.rawValue)
            }
        }
        .disabled(session.showsBusy || !session.canApplyShapeOperation)
    }
}

/// Two overlapping squares, the back one up and to the left, filled where the operation keeps them.
struct ShapeOperationIcon: View {
    var operation: ShapeOperation

    var body: some View {
        Canvas { context, size in
            let side = size.width * 0.66
            let back = CGPath(rect: CGRect(x: 0.5, y: 0.5, width: side, height: side), transform: nil)
            let front = CGPath(rect: CGRect(x: size.width - side - 0.5, y: size.height - side - 0.5, width: side, height: side), transform: nil)
            let outline = StrokeStyle(lineWidth: 1)
            switch operation {
            case .combine:
                context.fill(Path(back.union(front)), with: .foreground)
            case .subtract:
                context.fill(Path(back.subtracting(front)), with: .foreground)
                context.stroke(Path(front), with: .foreground, style: outline)
            case .intersect:
                context.stroke(Path(back), with: .foreground, style: outline)
                context.stroke(Path(front), with: .foreground, style: outline)
                context.fill(Path(back.intersection(front)), with: .foreground)
            case .exclude:
                context.fill(Path(back.symmetricDifference(front)), with: .foreground)
            }
        }
        .accessibilityHidden(true)
    }
}
