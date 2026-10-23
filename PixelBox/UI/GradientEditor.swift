import AppKit
import SwiftUI

/// A gradient drawn over a checkerboard, so its transparency reads as transparency.
struct GradientStrip: View {
    let gradient: ColorGradient
    var cornerRadius: CGFloat = 3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let stops = gradient.samples.map {
            Gradient.Stop(color: $0.color.swiftUI.opacity($0.opacity), location: $0.location)
        }
        Canvas { context, size in
            let cell: CGFloat = 5
            for row in 0..<Int((size.height / cell).rounded(.up)) {
                for column in 0..<Int((size.width / cell).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(.gray.opacity(0.35)))
                }
            }
        }
        .background(Color.white)
        .overlay { LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing) }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.black.opacity(0.45), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

/// A gradient well: the gradient, which opens the picker's gradient editor pointing at it.
struct GradientWell: View {
    let title: String
    /// The gradient as shown, stops that follow the palette in its colors.
    let gradient: ColorGradient
    let session: EditorSession
    var width: CGFloat = 120
    let open: () -> Void
    @State private var anchor = WellAnchor()

    var body: some View {
        Button { session.clickColorWell(anchor.view, open: open) } label: {
            // As it's laid: the other way round when reversed.
            GradientStrip(gradient: gradient.isReversed ? gradient.reversed : gradient, cornerRadius: 5)
                .frame(width: width, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(WellAnchorView(anchor: anchor))
        .disabled(!session.canEditPalette)
        .help(title)
        .accessibilityLabel(title)
        .onDisappear { session.wellDisappeared(anchor.view) }
    }
}

/// The picker's gradient editor: the gradient with its stops below it and, either side of the selected stop, the
/// midpoints above it. Click below the bar to add a stop, drag a stop to move it or off the bar to delete it, drag a
/// midpoint to move it. The picker's color controls edit the selected stop's color.
struct GradientStopsEditor: View {
    @Bindable var state: ColorPickerState
    let width: CGFloat
    /// A click (not a drag) on a stop, after selecting it.
    var stopClicked: (UUID) -> Void = { _ in }
    /// A stop being dragged far enough off the bar to be deleted when it's let go.
    @State private var leaving: UUID?

    private let barHeight: CGFloat = 24
    private let markerSize = CGSize(width: 12, height: 14)
    /// How far below the bar a stop must be dragged to come off it.
    private let removeDistance: CGFloat = 28

    private var gradient: ColorGradient { state.gradient ?? ColorGradient(.black, .white) }
    private var shown: ColorGradient { gradient.resolved(foreground: state.palette.foreground, background: state.palette.background) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: width, height: 12)
                ForEach(midpoints, id: \.stop.id) { midpoint(after: $0.stop, before: $0.next) }
            }
            .frame(width: width, height: 12)
            GradientStrip(gradient: shown, cornerRadius: 3)
                .frame(width: width, height: barHeight)
            ZStack(alignment: .topLeading) {
                // Clicking between the stops adds one there.
                Color.primary.opacity(0.001)
                    .frame(width: width, height: markerSize.height + 4)
                    .gesture(SpatialTapGesture().onEnded { add(at: $0.location.x) })
                ForEach(gradient.stops) { stop in marker(stop) }
            }
            .frame(width: width, height: markerSize.height + 4, alignment: .topLeading)
            fields
        }
        // Drags are measured from the bar's left end.
        .coordinateSpace(.named("gradientBar"))
    }

    /// The midpoints shown: those either side of the selected stop, as in Photoshop.
    private var midpoints: [(stop: GradientStop, next: GradientStop)] {
        let order = gradient.sorted
        guard let selected = order.firstIndex(where: { $0.id == state.selectedStopID ?? state.selectedMidpointID }) else { return [] }
        return [selected - 1, selected].compactMap { index in
            guard index >= 0, index + 1 < order.count else { return nil }
            return (order[index], order[index + 1])
        }
    }

    private func midpoint(after stop: GradientStop, before next: GradientStop) -> some View {
        let x = (stop.location + (next.location - stop.location) * stop.midpoint) * width
        let selected = state.selectedMidpointID == stop.id
        return Rectangle()
            .fill(selected ? Color.accentColor : Color.secondary)
            .frame(width: 7, height: 7)
            .rotationEffect(.degrees(45))
            .frame(width: 14, height: 12)
            .contentShape(Rectangle())
            .offset(x: x - 7)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("gradientBar")).onChanged { value in
                state.selectedMidpointID = stop.id
                state.selectedStopID = nil
                let span = next.location - stop.location
                guard span > 0, let index = state.gradient?.stops.firstIndex(where: { $0.id == stop.id }) else { return }
                let fraction = (value.location.x / width - stop.location) / span
                state.gradient?.stops[index].midpoint = min(ColorGradient.midpointRange.upperBound,
                                                            max(ColorGradient.midpointRange.lowerBound, fraction))
            })
            .accessibilityLabel("Midpoint")
            .accessibilityValue("\(Int((stop.midpoint * 100).rounded()))%")
    }

    private func marker(_ stop: GradientStop) -> some View {
        let selected = state.selectedStopID == stop.id
        let fill = ColorPickerState.shownColor(stop, palette: state.palette).swiftUI
        return StopMarker()
            .fill(fill)
            .overlay { StopMarker().stroke(selected ? Color.accentColor : Color.primary.opacity(0.6), lineWidth: selected ? 2 : 1) }
            .frame(width: markerSize.width, height: markerSize.height)
            .opacity(leaving == stop.id ? 0.3 : 1)
            .contentShape(Rectangle())
            .offset(x: stop.location * width - markerSize.width / 2, y: 2)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("gradientBar")).onChanged { value in
                if state.selectedStopID != stop.id { state.selectStop(stop.id) }
                guard let index = state.gradient?.stops.firstIndex(where: { $0.id == stop.id }) else { return }
                state.gradient?.stops[index].location = min(1, max(0, value.location.x / width))
                leaving = gradient.stops.count > 2 && value.translation.height > removeDistance ? stop.id : nil
            }.onEnded { drag in
                if leaving == stop.id { remove(stop.id) }
                else if hypot(drag.translation.width, drag.translation.height) < 3 { stopClicked(stop.id) }
                leaving = nil
            })
            .accessibilityLabel("Color stop")
            .accessibilityValue("\(Int((stop.location * 100).rounded()))%")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fields: some View {
        HStack(spacing: 10) {
            if let stop = state.selectedStop {
                percent("Location", stop.location) { value in update(stop.id) { $0.location = value } }
                Spacer(minLength: 0)
                // An icon, so the two fields keep room for their units.
                Button { remove(stop.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(gradient.stops.count <= 2)
                    .help("Remove this stop (or drag it off the bar)")
                    .accessibilityLabel("Delete stop")
            } else if let id = state.selectedMidpointID, let stop = gradient.stops.first(where: { $0.id == id }) {
                percent("Location", stop.midpoint, range: ColorGradient.midpointRange) { value in update(id) { $0.midpoint = value } }
                    .help("Where between the two stops their colors blend half and half")
                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
    }

    private func percent(_ title: String, _ value: CGFloat, range: ClosedRange<CGFloat> = 0...1,
                         set: @escaping (CGFloat) -> Void) -> some View {
        let binding = Binding<Double>(get: { Double((value * 100).rounded()) },
                                      set: { set(min(range.upperBound, max(range.lowerBound, CGFloat($0) / 100))) })
        return HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
                .scrubbable(sensitivity: 1, value: binding, range: Double(range.lowerBound * 100)...Double(range.upperBound * 100))
            TextField(title, value: binding, format: .number.precision(.fractionLength(0)))
                .frame(width: 40).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .arrowSteps(value: { binding.wrappedValue }, change: { binding.wrappedValue = $0 })
                .unitSuffix("%")
        }
        // Never squeezed, so the unit always shows.
        .fixedSize()
    }

    private func update(_ id: UUID, _ change: (inout GradientStop) -> Void) {
        guard let index = state.gradient?.stops.firstIndex(where: { $0.id == id }) else { return }
        change(&state.gradient!.stops[index])
    }

    private func add(at x: CGFloat) {
        guard let id = state.gradient?.addStop(at: x / width) else { return }
        state.selectStop(id)
    }

    private func remove(_ id: UUID) {
        guard var gradient = state.gradient, gradient.stops.count > 2 else { return }
        gradient.stops.removeAll { $0.id == id }
        state.gradient = gradient
        if let first = gradient.sorted.first { state.selectStop(first.id) }
    }
}

/// A gradient stop's marker: a little house pointing up at the bar.
private struct StopMarker: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.4))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.4))
            path.closeSubpath()
        }
    }
}

/// The gradient sets, where the swatch sets would be: click one to use it, "+" saves the gradient being edited.
struct GradientSetsView: View {
    @Bindable var state: ColorPickerState
    @Bindable var library: GradientLibrary
    let askForName: (String, String) -> String?

    var body: some View {
        let selected = library.selectedSet
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Gradient set", selection: Binding(get: { selected?.id }, set: { library.selectedSetID = $0 })) {
                    ForEach(library.sets) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                Menu {
                    Button("New Set…") { if let name = askForName("New Gradient Set", "Gradients") { library.newSet(named: name) } }
                    Button("Rename Set…") {
                        if let selected, let name = askForName("Rename Gradient Set", selected.name) { library.renameSet(selected.id, to: name) }
                    }
                    .disabled(selected == nil)
                    Button("Delete Set") { if let selected { library.deleteSet(selected.id) } }
                        .disabled(selected == nil || library.sets.count < 2)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Gradient set options")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(selected?.gradients ?? []) { saved in
                    Button { state.load(saved.gradient) } label: {
                        GradientStrip(gradient: saved.gradient.resolved(foreground: state.palette.foreground, background: state.palette.background))
                            .frame(height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(saved.name)
                    .accessibilityLabel(saved.name)
                    .contextMenu {
                        Button("Rename Gradient…") {
                            if let name = askForName("Rename Gradient", saved.name) { library.renameGradient(saved.id, to: name) }
                        }
                        Button("Delete Gradient") { library.deleteGradient(saved.id) }
                    }
                }
                if let selected, let gradient = state.gradient {
                    Button { library.addGradient(gradient, to: selected.id) } label: {
                        Image(systemName: "plus").frame(maxWidth: .infinity).frame(height: 20)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Save this gradient in the set")
                    .accessibilityLabel("Save gradient")
                }
            }
        }
    }
}

/// A small square showing what a gradient shape looks like, for the buttons that choose one.
struct GradientShapeIcon: View {
    let shape: GradientShape
    var body: some View {
        let colors: [Color] = [.white, .gray.opacity(0.35)]
        RoundedRectangle(cornerRadius: 2)
            .fill(shape == .linear ? AnyShapeStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                  : shape == .radial ? AnyShapeStyle(RadialGradient(colors: colors, center: .center, startRadius: 0, endRadius: 9))
                  : AnyShapeStyle(AngularGradient(colors: colors + [.white], center: .center)))
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.primary.opacity(0.7), lineWidth: 1) }
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}

/// Linear, Radial and Angle, as a row of icons, the chosen one lit.
struct GradientShapePicker: View {
    @Binding var shape: GradientShape
    var body: some View {
        HStack(spacing: 0) {
            ForEach(GradientShape.allCases, id: \.self) { option in
                Button { shape = option } label: {
                    GradientShapeIcon(shape: option)
                        .frame(width: 30, height: 24)
                        .background(shape == option ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.rawValue)
                .accessibilityLabel(option.rawValue)
                .accessibilityAddTraits(shape == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// The swap button: turns the gradient's stops round, left to right.
struct GradientReverseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .frame(width: 32, height: 24)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Swap the gradient's colors, left to right")
        .accessibilityLabel("Swap colors")
    }
}

/// A small, flat slider: a thin track and a little knob, without the standard slider's glass.
struct CompactSlider: View {
    @Binding var value: CGFloat
    var range: ClosedRange<CGFloat> = 0...1
    private let knob: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - knob)
            let fraction = (min(range.upperBound, max(range.lowerBound, value)) - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.18)).frame(height: 4).padding(.horizontal, knob / 2)
                Circle().fill(Color(white: 0.6))
                    .overlay { Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5) }
                    .frame(width: knob, height: knob)
                    .offset(x: fraction * travel)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let picked = min(1, max(0, (drag.location.x - knob / 2) / travel))
                value = range.lowerBound + picked * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: knob + 4)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 100
            value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? step : -step)))
        }
    }
}

/// A round dial for an angle: its knob points the way the angle does, counterclockwise from pointing right. Drag
/// anywhere on it to turn it; Shift snaps to 15° steps.
struct AngleDial: View {
    @Binding var degrees: CGFloat
    var size: CGFloat = 28

    var body: some View {
        let radians = degrees * .pi / 180
        let reach = size / 2 - 5
        ZStack {
            Circle().fill(Color.primary.opacity(0.35))
            Circle().fill(Color.white)
                .frame(width: 6, height: 6)
                .offset(x: cos(radians) * reach, y: -sin(radians) * reach)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let dx = value.location.x - size / 2, dy = size / 2 - value.location.y
            guard dx != 0 || dy != 0 else { return }
            var angle = atan2(dy, dx) * 180 / .pi
            if angle < 0 { angle += 360 }
            if NSEvent.modifierFlags.contains(.shift) { angle = (angle / 15).rounded() * 15 }
            degrees = angle.rounded().truncatingRemainder(dividingBy: 360)
        })
        .help("Drag to set the angle; Shift snaps to 15°")
        .accessibilityLabel("Angle")
        .accessibilityValue("\(Int(degrees.rounded())) degrees")
        .accessibilityAdjustableAction { direction in
            degrees = ((degrees + (direction == .increment ? 1 : -1)) + 360).truncatingRemainder(dividingBy: 360)
        }
    }
}

/// How the gradient being edited is laid over what it paints: its shape, direction, angle and opacity.
struct GradientOptionsBar: View {
    @Bindable var state: ColorPickerState
    /// The Gradient tool takes its angle from the line dragged, so it has no dial.
    let showsAngle: Bool

    private func binding<Value>(_ key: WritableKeyPath<ColorGradient, Value>, _ fallback: Value) -> Binding<Value> {
        Binding(get: { state.gradient?[keyPath: key] ?? fallback }, set: { state.gradient?[keyPath: key] = $0 })
    }

    /// The selected stop's opacity; the gradient's own, overall, is the Gradient tool bar's.
    private var stopOpacity: Binding<CGFloat> {
        Binding(get: { state.selectedStop?.opacity ?? 1 }, set: { value in
            guard let id = state.selectedStopID, let index = state.gradient?.stops.firstIndex(where: { $0.id == id }) else { return }
            state.gradient?.stops[index].opacity = min(1, max(0, value))
        })
    }

    var body: some View {
        let angle = binding(\.angle, 0)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                GradientShapePicker(shape: binding(\.shape, .linear))
                // The stops turned round, left to right; each keeps its color and opacity, and stays selected.
                GradientReverseButton { state.gradient = state.gradient?.reversed }
                if showsAngle {
                    Spacer(minLength: 0)
                    AngleDial(degrees: angle)
                        .disabled(state.gradient?.shape == .radial)
                    HStack(spacing: 2) {
                        TextField("Angle", value: Binding(get: { Double(angle.wrappedValue) },
                                                          set: { angle.wrappedValue = CGFloat($0.isFinite ? ($0.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) : 0) }),
                                  format: .number.precision(.fractionLength(0)))
                            .frame(width: 44).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                            .accessibilityLabel("Angle in degrees")
                        Text("°")
                        Stepper("Angle", onIncrement: { angle.wrappedValue = (angle.wrappedValue + 1).truncatingRemainder(dividingBy: 360) },
                                onDecrement: { angle.wrappedValue = (angle.wrappedValue + 359).truncatingRemainder(dividingBy: 360) })
                            .labelsHidden()
                    }
                    .disabled(state.gradient?.shape == .radial)
                    .help(state.gradient?.shape == .radial ? "A radial gradient has no angle" : "The gradient's angle")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Opacity")
                    Spacer()
                    Text("\(Int((stopOpacity.wrappedValue * 100).rounded()))%").monospacedDigit()
                }
                CompactSlider(value: stopOpacity)
                    .accessibilityLabel("Selected stop's opacity")
            }
            .disabled(state.selectedStop == nil)
            .help(state.selectedStop == nil ? "Select a stop to set its opacity" : "The selected stop's opacity")
        }
    }
}
