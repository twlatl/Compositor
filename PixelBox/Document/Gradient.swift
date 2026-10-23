import AppKit

/// The Gradient tool's two built-in gradients, which follow the palette's colors.
nonisolated enum GradientStyle: String, CaseIterable, Sendable {
    case foregroundToBackground = "Foreground to Background"
    case foregroundToTransparent = "Foreground to Transparent"
    var gradient: ColorGradient { self == .foregroundToBackground ? .foregroundToBackground : .foregroundToTransparent }
}

/// Linear runs from start to end; radial is centered on the start with the end on its rim; angle sweeps around the
/// start, beginning toward the end.
nonisolated enum GradientShape: String, CaseIterable, Codable, Sendable {
    case linear = "Linear"
    case radial = "Radial"
    case angle = "Angle"
}

nonisolated struct GradientSettings: Equatable, Sendable {
    var shape = GradientShape.linear
    var gradient = ColorGradient.foregroundToTransparent
    var reversed = false
    var opacity: CGFloat = 1
    /// The built-in gradient the tool draws, if it's one of them; setting one draws it.
    var style: GradientStyle? {
        get { GradientStyle.allCases.first { $0.gradient == gradient } }
        set { if let newValue { gradient = newValue.gradient } }
    }
}

/// An uncommitted gradient on one layer or mask. Endpoints are document pixels;
/// the raster preview lives in `raster` and never touches the document until commit.
final class GradientEdit {
    let raster: BrushStroke
    var start: CGPoint
    var end: CGPoint
    init(raster: BrushStroke, start: CGPoint) {
        self.raster = raster
        self.start = start
        end = start
    }
    var hasLine: Bool { hypot(end.x - start.x, end.y - start.y) >= 0.5 }

    /// What the gradient is filled with, as it's dragged and set.
    struct Fill: Equatable {
        let shape: GradientShape
        let start: CGPoint
        let end: CGPoint
        let colors: [CGColor]
        /// Where each color falls along the line, 0 to 1.
        let locations: [CGFloat]
        let opacity: CGFloat
        /// The gradient itself, for an angle gradient, which can't be drawn from the colors alone.
        var sweep: ColorGradient? = nil
    }
    var fill: Fill?
    /// The fill the raster's tiles hold. They're filled only when something reads them — the Core Graphics canvas, or
    /// the commit — as the GPU canvas draws the gradient itself.
    private var filled: Fill?
    func applyFill() throws {
        guard let fill, fill != filled else { return }
        try raster.fillGradient(fill.shape, from: fill.start, to: fill.end, colors: fill.colors, locations: fill.locations,
                                opacity: fill.opacity, sweep: fill.sweep)
        filled = fill
    }
}

extension EditorSession {
    func beginGradient(at point: CGPoint) {
        guard tool == .gradient, canPaint || gradientEdit != nil, let layer = activeLayer else { return }
        // Dragging a new line replaces the pending one on the same target.
        if let edit = gradientEdit, edit.raster.layer.id == layer.id, edit.raster.isMask == isMaskSelected {
            edit.start = point
            edit.end = point
            refreshGradient()
            return
        }
        guard canPaint else { brushError = paintRefusal; return }
        finishOpacityEdit()
        do {
            gradientEdit = GradientEdit(raster: try makeRasterEdit(for: layer, growsMask: true), start: point)
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }

    func moveGradient(start: CGPoint? = nil, end: CGPoint? = nil) {
        guard let edit = gradientEdit else { return }
        if let start { edit.start = start }
        if let end { edit.end = end }
        refreshGradient()
    }

    /// Re-renders the pending gradient from the current endpoints, settings, and palette.
    func refreshGradient() {
        guard let edit = gradientEdit else { return }
        if edit.hasLine {
            let stops = gradientStops(mask: edit.raster.isMask)
            var sweep = gradientSettings.gradient.resolved(foreground: paletteColor(background: false), background: paletteColor(background: true))
            if gradientSettings.reversed { sweep = sweep.reversed }
            edit.fill = GradientEdit.Fill(shape: gradientSettings.shape, start: edit.start, end: edit.end,
                                          colors: stops.colors, locations: stops.locations, opacity: gradientSettings.opacity,
                                          sweep: gradientSettings.shape == .angle ? sweep.stopsOnly : nil)
        }
        brushRevision += 1
    }

    /// The tool's gradient as Core Graphics draws it: stops following the palette in its colors (black or white on a
    /// mask), reversed if asked, with extra stops where a midpoint has moved. On a mask a color is its brightness.
    func gradientStops(mask: Bool) -> (colors: [CGColor], locations: [CGFloat]) {
        var gradient = gradientSettings.gradient.resolved(foreground: paletteColor(background: false), background: paletteColor(background: true))
        if gradientSettings.reversed { gradient = gradient.reversed }
        return gradient.cgStops(mask: mask)
    }

    func gradientColors(mask: Bool) -> [CGColor] { gradientStops(mask: mask).colors }

    /// Ends a drag; a click without a line leaves nothing pending.
    func endGradientDrag() {
        if gradientEdit?.hasLine == false { cancelGradient() }
    }

    func cancelGradient() {
        guard gradientEdit != nil else { return }
        gradientEdit = nil
        brushRevision += 1
    }

    func commitGradient() async {
        guard let edit = gradientEdit, !isProjectBusy else { return }
        guard edit.hasLine else { cancelGradient(); return }
        do {
            try edit.applyFill()
            try await commitRasterEdit(edit.raster, name: edit.raster.isMask ? "Gradient Mask" : "Gradient")
        } catch { brushError = error.localizedDescription }
        if gradientEdit === edit { cancelGradient() }
    }

    /// Switching tools, layers, or targets applies the pending gradient, as in Photoshop.
    func resolveGradient() {
        guard gradientEdit != nil else { return }
        Task { await commitGradient() }
    }
}
