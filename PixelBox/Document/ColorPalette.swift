import AppKit
import Observation

nonisolated struct PaletteColor: Equatable, Codable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    static let black = PaletteColor(red: 0, green: 0, blue: 0)
    static let white = PaletteColor(red: 1, green: 1, blue: 1)
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red; self.green = green; self.blue = blue
    }
    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: min(1, max(0, rgb.redComponent)), green: min(1, max(0, rgb.greenComponent)), blue: min(1, max(0, rgb.blueComponent)))
    }
}

extension EditorSession {
    var foregroundColor: PaletteColor {
        get { PaletteColor(red: brushSettings.red, green: brushSettings.green, blue: brushSettings.blue) }
        set { brushSettings.red = newValue.red; brushSettings.green = newValue.green; brushSettings.blue = newValue.blue }
    }
    var canEditPalette: Bool { _ = showsBusy; return !isProjectBusy && brushStroke == nil }
    func paletteColor(background: Bool) -> PaletteColor {
        if isMaskSelected { return (background ? !maskPaintWhite : maskPaintWhite) ? .white : .black }
        return background ? backgroundColor : foregroundColor
    }
    func setPaletteColor(_ color: PaletteColor, background: Bool) {
        guard canEditPalette else { return }
        if isMaskSelected {
            let white = color == .white
            maskPaintWhite = background ? !white : white
        } else if background { backgroundColor = color }
        else {
            foregroundColor = color
            // Type paints in the foreground color, so text being edited follows the swatch. A text layer merely
            // selected keeps its color: it changes only while its text is open for editing.
            if tool == .type, textDraft != nil { setDraftTextColor(color) }
        }
    }
    func swapPaletteColors() {
        guard canEditPalette else { return }
        if isMaskSelected { maskPaintWhite.toggle() }
        else {
            let old = foregroundColor
            setPaletteColor(backgroundColor, background: false)
            backgroundColor = old
        }
    }
    func resetPaletteColors() {
        guard canEditPalette else { return }
        if isMaskSelected { maskPaintWhite = false }
        else { setPaletteColor(.black, background: false); backgroundColor = .white }
    }

    func openColorPicker(background: Bool) {
        guard canEditPalette, !isMaskSelected else { return }
        let picker = ColorPickerState(background: background, original: paletteColor(background: background))
        // Text being edited follows the foreground color, so it previews the picker's working color as the Type
        // bar's own swatch does, and goes back to its own color on Cancel.
        if !background, tool == .type, let draft = textDraft {
            picker.editedText = (draft.id, draft.style)
        }
        colorPicker = picker
    }
    /// What the Type bar's swatch shows and edits: the text being edited, otherwise the foreground color the next
    /// text will use. A text layer that is only selected is not touched.
    /// With letters selected, it is the color of the first of them; with just a caret, the letter before it, the
    /// color typing there gives.
    var typeColor: PaletteColor {
        guard let draft = textDraft else { return foregroundColor }
        let selection = draft.selection
        return draft.style.color(at: selection.length > 0 ? selection.location : max(0, selection.location - 1))
    }
    func openTextColorPicker() {
        guard canEditPalette, colorPicker == nil, tool == .type else { return }
        let picker = ColorPickerState(target: .text(draftID: textDraft?.id), original: typeColor)
        if let draft = textDraft { picker.editedText = (draft.id, draft.style) }
        colorPicker = picker
    }
    /// Paints the selected letters of the text being edited, or all of it when nothing is selected.
    func setDraftTextColor(_ color: PaletteColor) {
        guard let selection = textDraft?.selection else { return }
        changeTextStyle { $0.setColor(color, in: selection) }
    }
    /// Puts back the colors the text being edited had when the picker opened.
    private func restoreDraftTextColors(_ original: LayerTextStyle) {
        changeTextStyle {
            $0.red = original.red; $0.green = original.green; $0.blue = original.blue
            $0.colorRuns = original.content == $0.content ? original.colorRuns : nil
        }
        refreshCanvasPreview?()
    }
    /// Opens the app's picker on a layer effect's color.
    func openEffectColorPicker(_ kind: LayerEffectKind) {
        guard canEditPalette, colorPicker == nil, effectsEditing != nil else { return }
        colorPicker = ColorPickerState(target: .effect(kind: kind), original: editingEffects.color(kind) ?? .black)
    }
    func closeColorPicker(commit: Bool) {
        if let colorPicker {
            // Every color chosen, whatever for, joins the picker's recent colors. A gradient's stops don't.
            if commit, colorPicker.gradient == nil, colorPicker.color != colorPicker.original {
                SwatchLibrary.shared.addRecent(colorPicker.color)
            }
            switch colorPicker.target {
            case .palette(let background):
                if commit, !isMaskSelected { setPaletteColor(colorPicker.color, background: background) }
                else if !commit {
                    // The swatch has been following the working color; Escape puts the one it had back.
                    if !isMaskSelected {
                        if background { backgroundColor = colorPicker.original } else { foregroundColor = colorPicker.original }
                    }
                    if let edited = colorPicker.editedText, tool == .type, textDraft?.id == edited.draftID {
                        restoreDraftTextColors(edited.style)
                    }
                }
            case .text(let draftID):
                if tool == .type, textDraft?.id == draftID {
                    let color = commit ? colorPicker.color : colorPicker.original
                    if draftID != nil {
                        if commit { setDraftTextColor(color); refreshCanvasPreview?() }
                        else if let edited = colorPicker.editedText { restoreDraftTextColors(edited.style) }
                    } else if commit {
                        textDefaults.red = color.red; textDefaults.green = color.green; textDefaults.blue = color.blue
                    }
                    // The text color is the foreground color: picking one in the Type bar moves the swatch too.
                    if commit, !isMaskSelected { foregroundColor = color }
                }
            case .effect(let kind):
                let color = commit ? colorPicker.color : colorPicker.original
                changeEffects { $0.setColor(color, for: kind) }
            case .gradient(let target):
                // The gradient has been previewing as it was edited; Escape puts the original back.
                if let gradient = commit ? colorPicker.gradient : colorPicker.originalGradient { setGradient(gradient, for: target) }
            case .vignette:
                setVignetteColor(commit ? colorPicker.color : colorPicker.original)
            case .shapeStroke:
                if !commit { revertShapePreview(colorPicker, name: "Stroke Color") }
                if commit {
                    let paint = colorPicker.paint
                    applyShapeStroke(paint)
                    // The tool's next shape is stroked the same way.
                    shapeStrokeEnabled = true
                    switch paint {
                    case .color(let color): shapeStrokeColor = color; shapeStrokeGradient = nil
                    case .gradient(let gradient): shapeStrokeGradient = gradient
                    }
                }
            case .shapeFill:
                if !commit { revertShapePreview(colorPicker, name: "Fill Color") }
                if commit {
                    let paint = colorPicker.paint
                    if shapeBarLayer != nil {
                        applyShapeFill(paint)
                    } else {
                        // No shape selected: what the tool's next shape fills with, the foreground color for a color.
                        shapeFilled = true
                        switch paint {
                        case .color(let color): if !isMaskSelected { foregroundColor = color }; shapeFillGradient = nil
                        case .gradient(let gradient): shapeFillGradient = gradient
                        }
                    }
                }
            case .dither(let light):
                setDitherColor(commit ? colorPicker.color : colorPicker.original, light: light)
            case .dialog:
                dialogColorChange?(commit ? colorPicker.color : colorPicker.original)
                dialogColorChange = nil
            case .dialogPaint:
                dialogPaintChange?(commit ? colorPicker.paint : colorPicker.originalPaint)
                dialogPaintChange = nil
            }
        }
        colorPicker = nil
        // Sampling clicked the canvas, which took the keys from the text: give them back.
        if textDraft != nil { canvasFocusRequest += 1 }
    }
    /// The selected shape has been following the working color, in one undo step of its own: Escape takes it back.
    private func revertShapePreview(_ picker: ColorPickerState, name: String) {
        if picker.restyled, history.canAmendLast(name) { undo() }
    }

    /// Whatever the open picker edits follows its working color, live: the palette swatch, the text being typed, a
    /// layer effect, a filter's color, a dialog's, or the selected shape's fill or stroke.
    func previewPickerColor() {
        guard let colorPicker else { return }
        let color = colorPicker.color
        switch colorPicker.target {
        case .palette(let background):
            guard !isMaskSelected else { return }
            if background { backgroundColor = color } else { foregroundColor = color; previewTextColor() }
        case .text: previewTextColor()
        case .effect: previewEffectColor()
        case .gradient(let target):
            if let gradient = colorPicker.gradient { setGradient(gradient, for: target) }
        case .vignette: previewVignetteColor()
        case .dither: previewDitherColor()
        case .dialog: previewDialogColor()
        case .shapeFill:
            guard shapeBarLayer != nil else { return }
            applyShapeFill(colorPicker.paint)
            colorPicker.restyled = true
        case .shapeStroke:
            guard let style = shapeBarLayer?.liveShape?.style, style.kind != .line else { return }
            applyShapeStroke(colorPicker.paint)
            colorPicker.restyled = true
        case .dialogPaint:
            dialogPaintChange?(colorPicker.paint)
        }
    }

    /// The selected shape filled with a color or a gradient (a line drawn in it), and filled at all.
    private func applyShapeFill(_ paint: Paint) {
        restyleShape("Fill Color") { style in
            switch paint {
            case .color(let color):
                style.red = color.red; style.green = color.green; style.blue = color.blue
                style.fillGradient = nil
            case .gradient(let gradient):
                style.fillGradient = gradient
            }
            if style.kind != .line { style.filled = nil }
        }
    }

    /// The selected shape stroked with a color or a gradient, given a stroke if it had none.
    private func applyShapeStroke(_ paint: Paint) {
        let width = CGFloat(shapeStrokeWidth), options = shapeStrokeOptions, fallback = shapeStrokeColor
        restyleShape("Stroke Color") { style in
            guard style.kind != .line else { return }
            var stroke = style.stroke ?? ShapeStroke(color: fallback, width: width, options: options)
            switch paint {
            case .color(let color):
                stroke.red = color.red; stroke.green = color.green; stroke.blue = color.blue
                stroke.gradient = nil
            case .gradient(let gradient):
                stroke.gradient = gradient
            }
            style.stroke = stroke
        }
    }

    /// A click on a color well (`anchor` is the view its popover points at): opens the picker on what it edits. With a
    /// picker already open, it's put away, keeping its color; a click on its own well stops there, and one on another
    /// well opens that well's picker instead.
    func clickColorWell(_ anchor: NSView?, open: () -> Void) {
        if colorPicker != nil {
            let own = anchor != nil && colorPickerAnchor === anchor
            closeColorPicker(commit: true)
            if own { return }
        }
        colorPickerAnchor = anchor
        open()
    }

    /// A well that goes away (its tool put down, its bar redrawn) takes its open picker with it, keeping the color, so
    /// the popover isn't left pointing at nothing.
    func wellDisappeared(_ anchor: NSView?) {
        guard colorPicker != nil, let anchor, colorPickerAnchor === anchor else { return }
        closeColorPicker(commit: true)
    }

    /// Escape from anywhere while the picker is open, not only from inside it: puts it away with the original color.
    /// False when there's no picker to close, so Escape can do its usual job.
    @discardableResult
    func cancelColorPicker() -> Bool {
        guard colorPicker != nil else { return false }
        if eyedropper?.intoPicker == true { finishEyedropper(commit: false) }
        closeColorPicker(commit: false)
        return true
    }

    /// A color well's eyedropper, or the picker's, is waiting for a click on the canvas.
    func beginEyedropper(intoPicker: Bool, apply: @escaping (PaletteColor) -> Void = { _ in }) {
        guard document != nil else { return }
        eyedropperColor = nil
        eyedropper = EyedropperRequest(intoPicker: intoPicker, apply: apply)
        // A well's eyedropper hands the keys to the canvas, so Escape there puts it away.
        if !intoPicker { canvasFocusRequest += 1 }
    }

    /// The canvas color under the eyedropper as it's pressed or dragged. The picker follows it as it goes; a well
    /// takes it when the mouse is let go.
    func previewEyedropper(at point: CGPoint) {
        guard let request = eyedropper, let color = sampleCompositeColor(at: point) else { return }
        eyedropperColor = color
        if request.intoPicker, let colorPicker {
            colorPicker.hsb.setRGB(color)
            previewPickerColor()
        }
    }

    /// Ends the eyedropper: with `commit`, a well takes the color it last sampled. Escape doesn't.
    func finishEyedropper(commit: Bool) {
        guard let request = eyedropper else { return }
        let color = eyedropperColor
        eyedropper = nil
        eyedropperColor = nil
        if commit, !request.intoPicker, let color { request.apply(color) }
    }

    /// A color picked straight into a well, without showing the picker: opened, set and kept, as one change.
    func pickColor(_ color: PaletteColor, opening open: () -> Void) {
        guard colorPicker == nil else { return }
        colorPickerHeadless = true
        defer { colorPickerHeadless = false }
        open()
        guard let colorPicker else { return }
        colorPicker.hsb.setRGB(color)
        previewPickerColor()
        closeColorPicker(commit: true)
    }

    /// Opens the picker's gradient editor on the Gradient tool's gradient, or on the Gradient Map being edited.
    func openGradientPicker(_ target: GradientTarget) {
        guard canEditPalette, colorPicker == nil else { return }
        let gradient: ColorGradient
        switch target {
        case .tool:
            // The tool keeps its shape, direction and opacity beside its stops; the editor sets them all.
            var tool = gradientSettings.gradient
            tool.shape = gradientSettings.shape
            tool.isReversed = gradientSettings.reversed
            tool.opacity = gradientSettings.opacity
            gradient = tool
        case .map:
            guard let edit = filterEdit, edit.kind == .gradientMap, !edit.committing else { return }
            gradient = edit.settings.gradientMap.gradient
        }
        colorPicker = ColorPickerState(target: .gradient(target), gradient: gradient,
                                       foreground: paletteColor(background: false), background: paletteColor(background: true))
    }

    /// The gradient the picker is editing, put where it belongs: the tool's, or the Gradient Map's (whose preview follows).
    private func setGradient(_ gradient: ColorGradient, for target: GradientTarget) {
        switch target {
        case .tool:
            var settings = gradientSettings
            settings.gradient = gradient.stopsOnly
            settings.shape = gradient.shape
            settings.reversed = gradient.isReversed
            settings.opacity = max(0.01, gradient.opacity)
            if settings != gradientSettings { gradientSettings = settings }
        case .map:
            guard let edit = filterEdit, edit.kind == .gradientMap, !edit.committing else { return }
            var settings = edit.settings
            settings.gradientMap.gradient = gradient.stopsOnly
            guard settings != edit.settings else { return }
            updateFilter(settings, preview: edit.preview)
        }
    }
    func openVignetteColorPicker() {
        guard canEditPalette, colorPicker == nil, let edit = filterEdit, edit.kind == .vignette, !edit.committing else { return }
        let value = edit.settings.vignetteColor
        colorPicker = ColorPickerState(target: .vignette,
                                       original: PaletteColor(red: value.red, green: value.green, blue: value.blue))
    }
    /// While the picker is open on an effect's color, the canvas follows its working color.
    func previewEffectColor() {
        guard let colorPicker, case .effect(let kind) = colorPicker.target else { return }
        changeEffects { $0.setColor(colorPicker.color, for: kind) }
    }
    /// Preview the picker's working color in the active on-canvas text draft.
    func previewTextColor() {
        guard let colorPicker else { return }
        let draftID: UUID?
        switch colorPicker.target {
        case .text(let id): draftID = id
        case .palette(background: false): draftID = colorPicker.editedText?.draftID
        default: return
        }
        guard let draftID, tool == .type, textDraft?.id == draftID else { return }
        setDraftTextColor(colorPicker.color)
        refreshCanvasPreview?()
    }
    /// Opens the app's picker on a dialog's color. `change` hears the working color as it moves, the chosen one on OK,
    /// and the original again on Cancel.
    func openDialogColorPicker(title: String, color: PaletteColor, change: @escaping (PaletteColor) -> Void) {
        guard colorPicker == nil else { return }
        dialogColorChange = change
        colorPicker = ColorPickerState(target: .dialog(title: title), original: color)
    }
    /// Opens the picker on a dialog's color or gradient, with the list at its top to switch between them. `change`
    /// hears the working paint as it changes, the chosen one at the end, and the original again on Escape.
    func openDialogPaintPicker(title: String, paint: Paint, change: @escaping (Paint) -> Void) {
        guard colorPicker == nil else { return }
        dialogPaintChange = change
        let color: PaletteColor, gradient: ColorGradient?
        switch paint {
        case .color(let value): color = value; gradient = nil
        case .gradient(let value): color = value.sorted.first?.color ?? .black; gradient = value
        }
        colorPicker = ColorPickerState(target: .dialogPaint(title: title), color: color, gradient: gradient, allowsGradient: true,
                                       foreground: paletteColor(background: false), background: paletteColor(background: true))
    }
    /// The picker is open for a dialog, which covers the canvas: there's nothing to sample.
    var pickingForDialog: Bool {
        switch colorPicker?.target {
        case .dialog, .dialogPaint: true
        default: false
        }
    }
    /// While the picker is open on a dialog's color, the dialog follows its working color.
    func previewDialogColor() {
        guard let colorPicker, case .dialog = colorPicker.target else { return }
        dialogColorChange?(colorPicker.color)
    }
    /// Dither's, or Scanlines', dark or light color.
    func openDitherColorPicker(light: Bool) {
        guard canEditPalette, colorPicker == nil, let edit = filterEdit, edit.kind == .dither || edit.kind == .scanlines,
              !edit.committing else { return }
        let colors = edit.kind == .scanlines ? (edit.settings.scanlines.dark, edit.settings.scanlines.light)
                                             : (edit.settings.dither.dark, edit.settings.dither.light)
        let value = light ? colors.1 : colors.0
        colorPicker = ColorPickerState(target: .dither(light: light),
                                       original: PaletteColor(red: value.red, green: value.green, blue: value.blue))
    }
    func previewDitherColor() {
        guard let colorPicker, case .dither(let light) = colorPicker.target else { return }
        setDitherColor(colorPicker.color, light: light)
    }
    private func setDitherColor(_ color: PaletteColor, light: Bool) {
        guard let edit = filterEdit, edit.kind == .dither || edit.kind == .scanlines, !edit.committing else { return }
        var settings = edit.settings
        if edit.kind == .scanlines {
            if light { settings.scanlines.light = AdjustmentColor(color) } else { settings.scanlines.dark = AdjustmentColor(color) }
        } else if light { settings.dither.light = AdjustmentColor(color) } else { settings.dither.dark = AdjustmentColor(color) }
        guard settings != edit.settings else { return }
        updateFilter(settings, preview: edit.preview)
    }
    func previewVignetteColor() {
        guard let colorPicker, case .vignette = colorPicker.target else { return }
        setVignetteColor(colorPicker.color)
    }
    private func setVignetteColor(_ color: PaletteColor) {
        guard let edit = filterEdit, edit.kind == .vignette, !edit.committing else { return }
        var settings = edit.settings
        settings.vignetteColor = AdjustmentColor(color)
        guard settings != edit.settings else { return }
        updateFilter(settings, preview: edit.preview)
    }
    /// Loads the canvas color under a document point into the open picker.
    func sampleIntoColorPicker(at point: CGPoint) {
        guard let colorPicker, let color = sampleCompositeColor(at: point) else { return }
        colorPicker.hsb.setRGB(color)
    }

    /// Composited sRGB color of the visible layers at one document pixel, as shown on
    /// the canvas. Nil outside the canvas or over fully transparent pixels.
    func sampleCompositeColor(at point: CGPoint) -> PaletteColor? {
        guard let document, point.x >= 0, point.y >= 0,
              point.x < document.size.width, point.y < document.size.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Map the target pixel onto the 1×1 context in the renderer's top-left space.
            context.translateBy(x: 0, y: 1)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -point.x.rounded(.down), y: -point.y.rounded(.down))
        drawLiveComposite(document, in: context)

            return true
        }
        guard drawn, pixel[3] > 0 else { return nil }
        let alpha = CGFloat(pixel[3])
        func channel(_ value: UInt8) -> CGFloat { (min(alpha, CGFloat(value)) / alpha * 255).rounded() / 255 }
        return PaletteColor(red: channel(pixel[0]), green: channel(pixel[1]), blue: channel(pixel[2]))
    }
}

/// What the open color picker edits: a palette swatch, or one end of the Gradient Map being edited.
enum ColorPickerTarget: Equatable {
    case palette(background: Bool)
    /// A layer effect's own color.
    case effect(kind: LayerEffectKind)
    /// A gradient, in the picker's gradient editor.
    case gradient(GradientTarget)
    /// A dialog's color or gradient, such as Edit › Fill's. The dialog is told as it changes.
    case dialogPaint(title: String)
    case vignette
    /// The Shape tool's stroke color.
    case shapeStroke
    /// A selected shape layer's own fill color.
    case shapeFill
    /// Dither's Two Colors: the dark one or the light one.
    case dither(light: Bool)
    case text(draftID: UUID?)
    /// A dialog's own color, such as Export JPEG's background for transparency. The dialog is told as it changes.
    case dialog(title: String)
    var title: String {
        switch self {
        case .text: return "Color Picker (Text Color)"
        case .effect(let kind): return "Color Picker (\(kind.rawValue) Color)"
        case .palette(let background): return background ? "Color Picker (Background Color)" : "Color Picker (Foreground Color)"
        case .gradient(let target): return target == .tool ? "Gradient Editor (Gradient Tool)" : "Gradient Editor (Gradient Map)"
        case .vignette: return "Color Picker (Vignette Color)"
        case .shapeStroke: return "Color Picker (Stroke Color)"
        case .shapeFill: return "Color Picker (Fill Color)"
        case .dialogPaint(let title): return "Color Picker (\(title))"
        case .dither(let light): return light ? "Color Picker (Light Color)" : "Color Picker (Dark Color)"
        case .dialog(let title): return "Color Picker (\(title))"
        }
    }
}

/// What paints an area: one color, or a gradient. A gradient's stops hold their own colors, none following the palette.
enum Paint: Equatable {
    case color(PaletteColor)
    case gradient(ColorGradient)
}

/// Where a gradient being edited goes.
enum GradientTarget: Equatable {
    case tool, map
}

/// The eyedropper on a color well, or in the picker: the next press on the canvas samples a color for it.
struct EyedropperRequest {
    let id = UUID()
    /// Into the open picker, which stays open, rather than straight into a well.
    let intoPicker: Bool
    let apply: (PaletteColor) -> Void
}

/// The open color picker's working color, which what it edits follows live; Escape puts the original back.
@Observable
final class ColorPickerState {
    let target: ColorPickerTarget
    var background: Bool { target == .palette(background: true) }
    let original: PaletteColor
    /// The foreground picker opened while text was being edited: that text and the color it had.
    var editedText: (draftID: UUID, style: LayerTextStyle)?
    /// The selected shape has been redrawn in the working color, as an undo step Escape takes back.
    @ObservationIgnored var restyled = false
    var hsb: PickerHSB
    var color: PaletteColor { hsb.rgb.quantized }
    /// In the gradient editor: the gradient being edited and the one it started as, the selected stop, whose color
    /// the picker's color controls edit, and the midpoint selected instead, named by the stop it follows.
    var gradient: ColorGradient?
    let originalGradient: ColorGradient?
    var selectedStopID: UUID?
    var selectedMidpointID: UUID?
    /// The palette when the editor opened, for the colors of stops that follow it.
    let palette: (foreground: PaletteColor, background: PaletteColor)
    /// Whether it edits a color or a gradient is the user's choice, from the list at the top of the picker.
    let allowsGradient: Bool
    /// The gradient put aside while the picker edits a color, or the color while it edits a gradient, so switching
    /// back finds them again.
    private var parkedGradient: ColorGradient?
    private var parkedColor: PaletteColor?
    init(target: ColorPickerTarget, original: PaletteColor) {
        self.target = target
        self.original = original
        hsb = PickerHSB(original)
        originalGradient = nil
        palette = (.black, .white)
        allowsGradient = false
    }
    /// A picker on a gradient; with `allowsGradient`, on a color or a gradient, starting with `gradient` if there is one.
    init(target: ColorPickerTarget, color: PaletteColor? = nil, gradient: ColorGradient?, allowsGradient: Bool = false,
         foreground: PaletteColor, background: PaletteColor) {
        self.target = target
        palette = (foreground, background)
        self.allowsGradient = allowsGradient
        let first = gradient?.sorted.first
        original = color ?? first.map { Self.shownColor($0, palette: (foreground, background)) } ?? .black
        hsb = PickerHSB(first.map { Self.shownColor($0, palette: (foreground, background)) } ?? original)
        self.gradient = gradient
        originalGradient = gradient
        selectedStopID = first?.id
        parkedColor = color
    }

    /// What the picker holds now: its color, or its gradient with every stop in its own color.
    var paint: Paint {
        guard let gradient else { return .color(color) }
        return .gradient(gradient.resolved(foreground: palette.foreground, background: palette.background).withoutRoles)
    }
    /// What it held when it opened.
    var originalPaint: Paint {
        guard let originalGradient else { return .color(original) }
        return .gradient(originalGradient.resolved(foreground: palette.foreground, background: palette.background).withoutRoles)
    }

    /// Switches between editing a color and a gradient. A new gradient runs from the color to the background color.
    func switchTo(gradient wantsGradient: Bool) {
        guard allowsGradient, wantsGradient != (gradient != nil) else { return }
        if wantsGradient {
            parkedColor = color
            load(parkedGradient ?? ColorGradient(color, palette.background))
        } else {
            parkedGradient = gradient
            let stopColor = selectedStop.map { Self.shownColor($0, palette: palette) }
            gradient = nil
            selectedStopID = nil
            selectedMidpointID = nil
            hsb.setRGB(parkedColor ?? stopColor ?? color)
        }
    }

    /// A stop's color as shown: the palette's, for one that follows it.
    static func shownColor(_ stop: GradientStop, palette: (foreground: PaletteColor, background: PaletteColor)) -> PaletteColor {
        switch stop.role {
        case .foreground: palette.foreground
        case .background: palette.background
        case nil: stop.color
        }
    }

    var selectedStop: GradientStop? { gradient?.stops.first { $0.id == selectedStopID } }

    /// Selects a stop: the color controls take its color.
    func selectStop(_ id: UUID) {
        selectedStopID = id
        selectedMidpointID = nil
        if let stop = selectedStop { hsb.setRGB(Self.shownColor(stop, palette: palette)) }
    }

    /// The color controls' color, given to the selected stop. A stop that followed the palette keeps its own color
    /// from then on, once it's changed.
    func colorChanged() {
        guard let stop = selectedStop, let index = gradient?.stops.firstIndex(where: { $0.id == stop.id }),
              color != Self.shownColor(stop, palette: palette) else { return }
        gradient?.stops[index].color = color
        gradient?.stops[index].role = nil
    }

    /// Puts in a saved gradient, selecting its first stop.
    func load(_ gradient: ColorGradient) {
        // Fresh identities, so a saved gradient used twice doesn't share them.
        var copy = gradient
        for index in copy.stops.indices { copy.stops[index].id = UUID() }
        self.gradient = copy
        if let first = copy.sorted.first { selectStop(first.id) }
    }
    convenience init(background: Bool, original: PaletteColor) {
        self.init(target: .palette(background: background), original: original)
    }
}

/// Hue in degrees, saturation and brightness 0...1. Kept as the picker's source of
/// truth so hue survives dragging through grays and black.
struct PickerHSB: Equatable {
    var hue: CGFloat
    var saturation: CGFloat
    var brightness: CGFloat

    init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        self.hue = hue; self.saturation = saturation; self.brightness = brightness
    }
    init(_ color: PaletteColor) {
        self.init(hue: 0, saturation: 0, brightness: 0)
        setRGB(color)
    }

    var rgb: PaletteColor {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return PaletteColor(red: r + m, green: g + m, blue: b + m)
    }

    /// Updates from RGB while keeping the previous hue for grays and the previous
    /// saturation for black, matching how Photoshop's field behaves.
    mutating func setRGB(_ color: PaletteColor) {
        let high = max(color.red, color.green, color.blue)
        let low = min(color.red, color.green, color.blue)
        let delta = high - low
        brightness = high
        if high > 0 { saturation = delta / high }
        guard delta > 0 else { return }
        var h: CGFloat
        if high == color.red { h = (color.green - color.blue) / delta }
        else if high == color.green { h = (color.blue - color.red) / delta + 2 }
        else { h = (color.red - color.green) / delta + 4 }
        h *= 60
        hue = h < 0 ? h + 360 : h
    }
}

extension PaletteColor {
    /// Snaps to the 8-bit values that painting and export actually store.
    var quantized: PaletteColor {
        PaletteColor(red: (red * 255).rounded() / 255, green: (green * 255).rounded() / 255, blue: (blue * 255).rounded() / 255)
    }
    var hex: String {
        String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    /// Accepts `RRGGBB` or shorthand `RGB`, with or without a leading `#`.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255)
    }
}
