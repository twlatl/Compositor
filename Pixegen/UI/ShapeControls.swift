import SwiftUI

struct ShapeControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(ShapeKind.allCases, id: \.self) { kind in
                    Button { session.cancelShape(); session.shapeKind = kind } label: { Label(kind.toolName, systemImage: kind.symbol) }
                }
            } label: {
                Image(systemName: session.shapeKind.symbol)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Shape: \(session.shapeKind.rawValue)")
            .help("Shift-U (or Tab) steps through the shapes")
            Picker("Mode", selection: Binding(get: { session.shapeMode }, set: { mode in
                session.cancelShape()
                session.shapeMode = mode
            })) {
                ForEach(ShapeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            .help("Shape makes a shape layer; Path, an outline to make a selection from; Pixels paints into the active layer")
            if session.shapeMode == .path {
                Button("Make Selection") { session.makeSelectionFromWorkPath() }
                    .disabled(session.workPath == nil)
                    .help("Select inside the path (Return)")
            }
            // A selected shape layer's own settings stay editable whatever the tool would draw next.
            if session.shapeMode != .path || session.shapeBarLayer != nil {
                ShapeStyleControls(session: session)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }
}

/// Fill, stroke and the settings of the kind of shape: the selected shape layer's own, which changing redraws, or
/// otherwise those the next shape will be drawn with. Changing a layer's sets the tool's too, as in Photoshop.
struct ShapeStyleControls: View {
    @Bindable var session: EditorSession
    @State private var showsStrokeOptions = false
    @State private var showsShapes = false

    /// The selected shape layer's style, when the bar is editing one.
    private var target: LayerShapeStyle? { session.shapeBarLayer?.liveShape?.style }
    /// What the bar's settings are for: the selected shape, or the next one drawn. A pen path is a custom shape.
    private var kind: ShapeKind { target?.kind ?? (session.tool == .pen ? .custom : session.shapeKind) }

    /// A setting read from the selected shape when there is one, or from the tool. Setting it sets the tool's and
    /// changes the selected shape, as one undo step named `name` however many times it changes in a row.
    private func setting<Value>(_ read: @escaping (LayerShapeStyle) -> Value?, _ tool: ReferenceWritableKeyPath<EditorSession, Value>,
                                _ name: String, _ write: @escaping (inout LayerShapeStyle, Value) -> Void) -> Binding<Value> {
        Binding(get: { (session.shapeBarLayer?.liveShape?.style).flatMap(read) ?? session[keyPath: tool] },
                set: { value in
                    session[keyPath: tool] = value
                    session.restyleShape(name) { write(&$0, value) }
                })
    }

    private var filled: Binding<Bool> {
        setting({ $0.kind == .line ? nil : $0.isFilled }, \.shapeFilled, "Fill") { $0.filled = $1 ? nil : false }
    }
    private var stroked: Binding<Bool> {
        let session = session
        return setting({ $0.kind == .line ? nil : $0.stroke != nil }, \.shapeStrokeEnabled, "Stroke") { style, on in
            style.stroke = on ? style.stroke ?? ShapeStroke(color: session.shapeStrokeColor, width: CGFloat(session.shapeStrokeWidth),
                                                            options: session.shapeStrokeOptions) : nil
        }
    }
    private var strokeWidth: Binding<Double> {
        setting({ $0.stroke.map { Double($0.width) } }, \.shapeStrokeWidth, "Stroke Width") { $0.stroke?.width = CGFloat($1) }
    }
    private var strokeOptions: Binding<ShapeStrokeOptions> {
        setting({ $0.kind == .line ? $0.lineOptions ?? ShapeStrokeOptions(cap: .round) : $0.stroke?.options },
                \.shapeStrokeOptions, "Stroke Options") { style, options in
            if style.kind == .line { style.lineOptions = options } else { style.stroke?.options = options }
        }
    }
    private var cornerRadius: Binding<Double> {
        setting({ $0.kind.takesCornerRadius ? Double($0.cornerRadius) : nil }, \.shapeCornerRadius, "Corner Radius") { $0.cornerRadius = CGFloat($1) }
    }
    private var smoothing: Binding<Bool> {
        setting({ $0.kind == .rectangle ? $0.smoothing == true : nil }, \.shapeSmoothing, "Smooth Corners") { $0.smoothing = $1 ? true : nil }
    }
    private var sides: Binding<Double> {
        let sides = setting({ $0.kind.takesSides ? $0.sides ?? 5 : nil }, \.shapeSides, "Sides") { $0.sides = $1 }
        return Binding(get: { Double(sides.wrappedValue) }, set: { sides.wrappedValue = Int($0.rounded()) })
    }
    private var lineWeight: Binding<Double> {
        setting({ $0.lineWidth.map(Double.init) }, \.shapeLineWidth, "Line Weight") { $0.lineWidth = CGFloat($1) }
    }

    var body: some View {
        HStack(spacing: 12) {
            paint
            if kind.takesSides {
                field("Sides", systemImage: kind == .star ? "star" : "number.circle", value: sides, range: 3...100, unit: nil,
                      help: kind == .star ? "How many points the star has" : "How many sides the polygon has")
            }
            if kind.takesCornerRadius {
                field("Radius", systemImage: "square.dashed", value: cornerRadius, range: 0...5000, unit: "px",
                      help: "Round the corners by this many pixels; 0 keeps them sharp")
                if kind == .rectangle {
                    Toggle("Smooth Corners", isOn: smoothing)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .disabled(cornerRadius.wrappedValue <= 0)
                        .help(cornerRadius.wrappedValue <= 0
                              ? "Set a radius above 0 to use smooth corners."
                              : "Use smooth squircle corners at 60% smoothing, matching Figma's iOS setting")
                }
            }
            // An edited path is drawn as a custom shape too, but has no library shape to swap.
            if kind == .custom, session.tool != .pen, target == nil || target?.customName != nil { customShapeButton }
        }
    }

    /// Fill and stroke, each switched on or off beside its well, or a line's color and weight.
    @ViewBuilder private var paint: some View {
        let fillColor = target?.color ?? session.foregroundColor
        HStack(spacing: 6) {
            if kind == .line {
                Text("Color:").fixedSize()
            } else {
                Toggle("Fill:", isOn: filled).toggleStyle(.checkbox).fixedSize()
                    .help(target != nil ? "Fill the selected shape" : "Fill new shapes")
            }
            // One well for a color or a gradient, so its picker stays open while it switches between them.
            ColorWell(title: kind == .line ? "Line color" : "Fill color", color: fillColor,
                      gradient: target.map(\.fillGradient) ?? session.shapeFillGradient, session: session) {
                if target == nil { session.shapeFilled = true }
                session.openFillColorPicker()
            }
            .opacity(kind == .line || filled.wrappedValue ? 1 : 0.45)
        }
        if kind == .line {
            field("Weight", systemImage: nil, value: lineWeight, range: 1...5000, unit: "px", help: "How thick the line is")
        } else {
            HStack(spacing: 6) {
                Toggle("Stroke:", isOn: stroked).toggleStyle(.checkbox).fixedSize()
                    .help("A stroke along the shape's outline")
                ColorWell(title: "Stroke color", color: target?.stroke?.color ?? session.shapeStrokeColor,
                          gradient: target != nil ? target?.stroke?.gradient : session.shapeStrokeGradient, session: session) {
                    session.openStrokeColorPicker()
                }
                .opacity(stroked.wrappedValue ? 1 : 0.45)
            }
            field(nil, systemImage: nil, value: strokeWidth, range: 0...1000, unit: "px", help: "The stroke's width")
                .disabled(!stroked.wrappedValue)
        }
        Button { showsStrokeOptions = true } label: {
            HStack(spacing: 4) {
                DashSample(dash: strokeOptions.wrappedValue.dash).frame(width: 40, height: 10)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(kind != .line && !stroked.wrappedValue)
        .accessibilityLabel("Stroke options")
        .help(kind == .line ? "The line's dashes and ends" : "The stroke's dashes, ends and corners")
        .popover(isPresented: $showsStrokeOptions, arrowEdge: .bottom) {
            StrokeOptionsPanel(options: strokeOptions, showsCorners: kind != .line)
        }
    }

    private var customShapeButton: some View {
        // The selected layer's shape, or the one the tool will draw.
        let outline = target?.outline ?? session.customShape?.outline
        let name = target?.customName ?? session.customShape?.name
        return HStack(spacing: 6) {
            Text("Shape:")
            Button { showsShapes = true } label: {
                HStack(spacing: 4) {
                    Group {
                        if let outline {
                            OutlineShape(outline: outline).fill(.white, style: FillStyle(eoFill: true)).padding(3)
                        } else {
                            Image(systemName: "questionmark").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 34, height: 24)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 3))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Custom shape: \(name ?? "none")")
            .help(name ?? "Choose a shape")
            .popover(isPresented: $showsShapes, arrowEdge: .bottom) {
                CustomShapePicker(session: session, library: ShapeLibrary.shared)
            }
        }
    }

    /// A number with a label (or an icon) to drag, a field to type in, and the arrow keys to step it.
    private func field(_ title: String?, systemImage: String?, value: Binding<Double>, range: ClosedRange<Double>,
                       unit: String?, help: String) -> some View {
        let clamped = Binding<Double>(get: { value.wrappedValue },
                                      set: { value.wrappedValue = $0.isFinite ? min(range.upperBound, max(range.lowerBound, $0)) : range.lowerBound })
        return HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).scrubbable(sensitivity: 1, value: clamped, range: range)
                    .accessibilityLabel(title ?? "")
            } else if let title {
                Text(title).scrubbable(sensitivity: 1, value: clamped, range: range)
            }
            let text = TextField(title ?? "Width", value: clamped, format: .number.precision(.fractionLength(0)))
                .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .arrowSteps(value: { clamped.wrappedValue }, change: { clamped.wrappedValue = $0 })
            if let unit { text.unitSuffix(unit) } else { text }
        }
        .help(help)
    }
}

/// A short sample of a dash pattern, for the stroke options.
private struct DashSample: View {
    var dash: ShapeDash
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 2, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
            let width: CGFloat = 2
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: width,
                lineCap: dash == .dots ? .round : .butt, dash: dash.lengths.map { $0 * width }))
        }
        .accessibilityLabel(dash.rawValue)
    }
}

/// Dashes, ends and corners for a stroke or a line.
private struct StrokeOptionsPanel: View {
    @Binding var options: ShapeStrokeOptions
    var showsCorners: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stroke Options").font(.headline)
            VStack(spacing: 2) {
                ForEach(ShapeDash.allCases, id: \.self) { dash in
                    Button { options.dash = dash } label: {
                        HStack {
                            DashSample(dash: dash).frame(width: 120, height: 12)
                            Spacer(minLength: 8)
                            Text(dash.rawValue).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(options.dash == dash ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(options.dash == dash ? .isSelected : [])
                }
            }
            Picker("Caps", selection: $options.cap) {
                ForEach(ShapeCap.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(options.dash == .dots)
            .help(options.dash == .dots ? "Dots always have round ends" : "How the ends of the stroke are drawn")
            if showsCorners {
                Picker("Corners", selection: $options.join) {
                    ForEach(ShapeJoin.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("How the stroke turns its corners")
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

/// A custom shape's outline, for thumbnails.
struct OutlineShape: Shape {
    var outline: ShapeOutline
    func path(in rect: CGRect) -> Path {
        // The shape's own proportions, centered in the space it's given.
        let aspect = outline.aspect
        var box = rect
        if rect.width / max(rect.height, 1) > aspect { box.size.width = rect.height * aspect }
        else { box.size.height = rect.width / aspect }
        box.origin = CGPoint(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2)
        return Path(outline.path(in: box))
    }
}
