import AppKit
import SwiftUI

extension PaletteColor {
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

/// The app's color picker, in a popover pointing at the color well that opened it. What it edits follows its color
/// live. It stays open whatever else is clicked (its own menus, the canvas, the Colors panel) until Escape, which puts
/// the original back, or another click on its well, which keeps the color.
@MainActor
final class ColorPopoverController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private weak var session: EditorSession?
    private weak var anchor: NSView?
    /// The picker this popover shows, so closing it never closes one opened since.
    private weak var shown: ColorPickerState?
    private var cancelled = false
    /// The well the popover points at, or the tool rail's swatch for a picker opened from elsewhere.
    weak var fallbackAnchor: NSView?

    var isShown: Bool { popover?.isShown == true }

    func show(_ state: ColorPickerState, session: EditorSession) {
        guard let anchor = session.colorPickerAnchor ?? fallbackAnchor, anchor.window != nil else { return }
        popover?.close()
        self.session = session
        self.anchor = anchor
        shown = state
        session.colorPickerAnchor = anchor
        cancelled = false
        let container = EscapeCatchingView()
        let hosting = NSHostingView(rootView: ColorPickerPopover(session: session, state: state, recents: RecentColors.shared,
                                                                 colorPanel: { [weak self] in self?.showColorPanel(state) }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.cancel = { [weak self, weak session] in
            // Escape stops the eyedropper first; with nothing sampling, it puts the original color back.
            if session?.eyedropper != nil { session?.finishEyedropper(commit: false) } else { self?.cancel() }
        }
        let controller = NSViewController()
        controller.view = container
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = hosting.fittingSize
        // Not transient: a click outside, even on the menu that switches Color and Gradient, leaves it open.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        container.window?.makeFirstResponder(container)
    }

    /// Closes the popover, keeping the color.
    func close() {
        popover?.close()
    }

    /// Closes the popover and puts the original color back.
    func cancel() {
        cancelled = true
        popover?.close()
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // A click on the canvas while sampling is the sample, not a click away; nor is one in the Colors panel or in a
        // name prompt the popover put up.
        if session?.eyedropper != nil, !cancelled { return false }
        if let window = NSApp.currentEvent?.window, window === NSColorPanel.shared || window === NSApp.modalWindow { return false }
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        detachColorPanel()
        guard let session else { return }
        let closing = shown
        popover = nil
        shown = nil
        // Only the picker this popover showed: a well that opened another one replaced it already.
        guard let closing, session.colorPicker === closing else { return }
        if session.eyedropper?.intoPicker == true { session.finishEyedropper(commit: false) }
        session.closeColorPicker(commit: !cancelled)
        session.colorPickerAnchor = nil
    }

    // MARK: The macOS Colors panel

    private weak var colorPanelState: ColorPickerState?

    /// Opens the Colors panel on the picker's color; in the gradient editor, on the selected stop's color, its opacity
    /// slider on the stop's opacity.
    private func showColorPanel(_ state: ColorPickerState) {
        colorPanelState = state
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        let stop = state.gradient == nil ? nil : state.selectedStop
        panel.showsAlpha = stop != nil
        panel.color = state.color.nsColor.withAlphaComponent(stop?.opacity ?? 1)
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let state = colorPanelState, let color = PaletteColor(sender.color) else { return }
        state.hsb.setRGB(color)
        if let id = state.selectedStopID, let index = state.gradient?.stops.firstIndex(where: { $0.id == id }),
           state.gradient?.stops[index].opacity != sender.color.alphaComponent {
            state.gradient?.stops[index].opacity = min(1, max(0, sender.color.alphaComponent))
        }
    }

    private func detachColorPanel() {
        guard colorPanelState != nil else { return }
        colorPanelState = nil
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        NSColorPanel.shared.orderOut(nil)
    }
}

/// Hears Escape for the popover, from whatever inside it has the keys.
private final class EscapeCatchingView: NSView {
    var cancel: () -> Void = {}
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { cancel() }
}

/// The picker's content: the color, the swatch sets, and the recent colors.
struct ColorPickerPopover: View {
    let session: EditorSession
    @Bindable var state: ColorPickerState
    @Bindable var recents: RecentColors
    /// The project's swatch folder shown, the first when it's gone.
    @State private var swatchGroupID: UUID?
    let colorPanel: () -> Void
    @AppStorage("colorPicker.showsColor") private var showsColor = true
    @AppStorage("colorPicker.showsSwatches") private var showsSwatches = true
    @State private var hexDraft = ""
    @FocusState private var hexFocused: Bool
    private let width: CGFloat = 268

    private var hsb: PickerHSB {
        get { state.hsb }
        nonmutating set { state.hsb = newValue }
    }
    private var color: PaletteColor { state.color }
    /// A dialog covers the canvas, so its colors can't be sampled from it.
    private var samples: Bool { !session.pickingForDialog && session.document != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Only what can be painted either way offers the choice: a shape's fill and stroke, a selection's fill.
            if state.allowsGradient {
                Picker("Paint with", selection: Binding(get: { state.gradient != nil }, set: { state.switchTo(gradient: $0) })) {
                    Text("Color").tag(false)
                    Text("Gradient").tag(true)
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("Color or gradient")
            }
            if state.gradient != nil {
                // The gradient's own controls together: the gradient, how it's laid, and the saved ones to start from.
                // The color controls below color its selected stop; the Gradient tool's has none, and a click on a
                // stop opens the Colors panel on it instead.
                Text("Gradient").font(.headline)
                GradientStopsEditor(state: state, width: width) { _ in
                    if state.target == .gradient(.tool) { colorPanel() }
                }
                // Gradient Map uses only the stops; the Gradient tool has no angle but the line it's dragged along.
                if state.target != .gradient(.map) {
                    GradientOptionsBar(state: state, showsAngle: state.target != .gradient(.tool))
                }
                Divider()
                section("Gradients", expanded: $showsSwatches) {
                    EmptyView()
                } content: {
                    GradientSetsView(state: state, library: GradientLibrary.shared, askForName: askForName)
                }
                if state.target != .gradient(.tool) { Divider() }
            }
            if state.target != .gradient(.tool) { colorSections }
        }
        .padding(14)
        .frame(width: width + 28)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { hexDraft = color.hex }
        .onChange(of: color) { _, new in
            if !hexFocused { hexDraft = new.hex }
            // In the gradient editor, the color is the selected stop's.
            state.colorChanged()
            session.previewPickerColor()
        }
        .onChange(of: state.gradient) { _, _ in session.previewPickerColor() }
        .onChange(of: hexFocused) { _, focused in if !focused { commitHex() } }
    }

    /// The color controls, the swatches and the recent colors.
    @ViewBuilder private var colorSections: some View {
            section("Color Picker", expanded: $showsColor) {
                if samples {
                    Button { session.beginEyedropper(intoPicker: true) } label: { Image(systemName: "eyedropper") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(session.eyedropper?.intoPicker == true ? Color.accentColor : .primary)
                        .help("Pick a color from the canvas")
                        .accessibilityLabel("Pick a color from the canvas")
                }
                Button(action: colorPanel) { Image(systemName: "paintpalette") }
                    .buttonStyle(.borderless)
                    .help("Open the Colors panel")
                    .accessibilityLabel("Open the Colors panel")
            } content: {
                saturationBrightnessField
                hueBar
                fields
            }
            Divider()
            if state.gradient == nil {
                section("Swatches", expanded: $showsSwatches) {
                    EmptyView()
                } content: {
                    swatchSets
                }
                Divider()
            }
            colorGrid(recents.colors.map { (id: $0.hex, name: "#" + $0.hex, color: $0, swatch: Optional<Swatch>.none) }, adds: false)
                .accessibilityLabel("Recent colors")
    }

    private func section<Accessories: View, Content: View>(_ title: String, expanded: Binding<Bool>,
                                                           @ViewBuilder accessories: () -> Accessories,
                                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { expanded.wrappedValue.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                        Text(title).font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
                Spacer()
                accessories()
            }
            if expanded.wrappedValue { content() }
        }
    }

    private var saturationBrightnessField: some View {
        let height: CGFloat = 170
        return ZStack {
            LinearGradient(colors: [.white, PickerHSB(hue: hsb.hue, saturation: 1, brightness: 1).rgb.swiftUI],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(.white, lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 2).strokeBorder(.black.opacity(0.6), lineWidth: 0.75).padding(-0.75))
                .frame(width: 11, height: 11)
                .position(x: hsb.saturation * width, y: (1 - hsb.brightness) * height)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            hsb.saturation = min(1, max(0, value.location.x / width))
            hsb.brightness = 1 - min(1, max(0, value.location.y / height))
        })
        .accessibilityLabel("Saturation and brightness")
    }

    private var hueBar: some View {
        let height: CGFloat = 20
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: stride(from: 0.0, through: 360, by: 60).map {
                PickerHSB(hue: $0, saturation: 1, brightness: 1).rgb.swiftUI
            }, startPoint: .leading, endPoint: .trailing)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            HueMarker()
                .fill(PickerHSB(hue: hsb.hue, saturation: 1, brightness: 1).rgb.swiftUI)
                .overlay { HueMarker().stroke(.white, lineWidth: 1.5) }
                .frame(width: 12, height: 16)
                .offset(x: hsb.hue / 360 * width - 6, y: height - 10)
        }
        .frame(width: width, height: height + 6, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            hsb.hue = min(1, max(0, value.location.x / width)) * 360
        })
        .accessibilityLabel("Hue")
        .accessibilityValue("\(Int(hsb.hue.rounded())) degrees")
    }

    private var fields: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 4) {
                TextField("Hex", text: $hexDraft)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($hexFocused)
                    .onSubmit(commitHex)
                    .accessibilityLabel("Hex color")
                Text("#").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 80)
            channel("R", \.red)
            channel("G", \.green)
            channel("B", \.blue)
        }
        .textFieldStyle(.roundedBorder)
    }

    private func channel(_ label: String, _ channel: WritableKeyPath<PaletteColor, CGFloat>) -> some View {
        let value = Binding<Int>(
            get: { Int((color[keyPath: channel] * 255).rounded()) },
            set: { newValue in
                var rgb = color
                rgb[keyPath: channel] = CGFloat(min(255, max(0, newValue))) / 255
                hsb.setRGB(rgb)
            })
        return VStack(spacing: 4) {
            TextField(label, value: value, format: .number)
                .multilineTextAlignment(.center)
                .arrowSteps(value: { Double(value.wrappedValue) }, change: { value.wrappedValue = Int($0.rounded()) })
                .accessibilityLabel(label == "R" ? "Red" : label == "G" ? "Green" : "Blue")
            Text(label).font(.caption).foregroundStyle(.secondary)
                .scrubbable(sensitivity: 1, value: value, range: 0...255)
        }
    }

    private func commitHex() {
        if let parsed = PaletteColor(hex: hexDraft) { hsb.setRGB(parsed) }
        hexDraft = color.hex
    }

    // MARK: Swatches

    /// The project's swatches, the same folders as the Swatches palette: changes here are project edits, saved with it
    /// and undoable.
    private var shownSwatchGroup: SwatchGroup? {
        session.swatchGroups.first { $0.id == swatchGroupID } ?? session.swatchGroups.first
    }

    @ViewBuilder private var swatchSets: some View {
        let selected = shownSwatchGroup
        HStack(spacing: 8) {
            Picker("Swatch folder", selection: Binding(get: { selected?.id }, set: { swatchGroupID = $0 })) {
                ForEach(session.swatchGroups) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            Menu {
                Button("New Folder…") {
                    if let name = askForName(title: "New Swatch Folder", initial: "Swatches") {
                        swatchGroupID = session.addSwatchGroup(named: name) ?? swatchGroupID
                    }
                }
                Button("Rename Folder…") {
                    if let selected, let name = askForName(title: "Rename Swatch Folder", initial: selected.name) {
                        session.renameSwatchItem(selected.id, to: name)
                    }
                }
                .disabled(selected == nil)
                Button("Delete Folder") { if let selected { session.deleteSwatchItem(selected.id) } }
                    .disabled(selected == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Swatch folder options")
        }
        .disabled(!session.canEditSwatches)
        colorGrid((selected?.swatches ?? []).map { (id: $0.id.uuidString, name: $0.name, color: $0.color, swatch: Optional($0)) },
                  adds: session.canEditSwatches)
    }

    /// Colors in rows of six: clicking one picks it. Swatches can be renamed or deleted; `adds` ends with a "+" that adds
    /// the current color to the set shown.
    private func colorGrid(_ colors: [(id: String, name: String, color: PaletteColor, swatch: Swatch?)], adds: Bool) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 6)
        return LazyVGrid(columns: columns, spacing: 3) {
            ForEach(colors, id: \.id) { entry in
                Button { hsb.setRGB(entry.color) } label: {
                    RoundedRectangle(cornerRadius: 2).fill(entry.color.swiftUI)
                        .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.primary.opacity(0.25), lineWidth: 1) }
                        .frame(height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(entry.name)
                .accessibilityLabel(entry.name)
                .contextMenu {
                    if let swatch = entry.swatch {
                        Button("Rename Swatch…") {
                            if let name = askForName(title: "Rename Swatch", initial: swatch.name) { session.renameSwatchItem(swatch.id, to: name) }
                        }
                        Button("Delete Swatch") { session.deleteSwatchItem(swatch.id) }
                    }
                }
            }
            if adds {
                // Into the folder shown, or a new one when the project has none.
                Button { _ = session.addSwatch(color, named: "", near: shownSwatchGroup?.id) } label: {
                    Image(systemName: "plus").frame(maxWidth: .infinity).frame(height: 20)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add the current color to this folder")
                .accessibilityLabel("Add swatch")
            }
        }
    }

    /// A name typed into a small alert, or nil when it's cancelled.
    private func askForName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

/// The hue bar's marker: a little house shape pointing up into the bar.
private struct HueMarker: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.35))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.35))
            path.closeSubpath()
        }
    }
}

/// A color well: the color, which opens the picker pointing at it, and an eyedropper that picks the color straight
/// from the canvas. `open` opens the session's picker on whatever this well edits.
struct ColorWell: View {
    let title: String
    let color: PaletteColor
    /// Shown instead of the color, for a well that holds a gradient just now. One well either way, so the picker
    /// pointing at it stays put when it switches between them.
    var gradient: ColorGradient? = nil
    let session: EditorSession
    /// False where the canvas can't be clicked, as under a dialog.
    var samples = true
    var width: CGFloat = 64
    let open: () -> Void
    @State private var anchor = WellAnchor()
    @State private var eyedropperID: UUID?

    private var sampling: Bool { eyedropperID != nil && session.eyedropper?.id == eyedropperID }
    /// The open picker, when it's this well's. The well shows its working color or gradient as it moves, whether or not
    /// what it edits follows before the picker closes (the Shape tool's next shape, the Type tool's next text).
    private var picker: ColorPickerState? {
        guard let picker = session.colorPicker, let view = anchor.view, session.colorPickerAnchor === view else { return nil }
        return picker
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        let color = picker?.color ?? color
        let gradient = picker.map(\.gradient) ?? gradient
        HStack(spacing: 0) {
            Button {
                session.clickColorWell(anchor.view, open: open)
            } label: {
                Group {
                    if let gradient {
                        GradientStrip(gradient: gradient.isReversed ? gradient.reversed : gradient, cornerRadius: 0)
                    } else {
                        Rectangle().fill(color.swiftUI)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityValue("#" + color.hex)
            // A sampled color has no one place in a gradient, so a well showing one has no eyedropper.
            if samples, gradient == nil {
                Button {
                    if sampling { session.finishEyedropper(commit: false); return }
                    let open = open, session = session
                    session.beginEyedropper(intoPicker: false) { picked in session.pickColor(picked, opening: open) }
                    eyedropperID = session.eyedropper?.id
                } label: {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 11))
                        .frame(width: 22)
                        .frame(maxHeight: .infinity)
                        .foregroundStyle(sampling ? Color.white : .primary)
                        .background(sampling ? Color.accentColor : Color(nsColor: .controlColor))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.document == nil)
                .help("Pick \(title.lowercased()) from the canvas")
                .accessibilityLabel("Pick \(title.lowercased()) from the canvas")
            }
        }
        .frame(width: samples && gradient == nil ? width : width - 22, height: 20)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.black.opacity(0.45), lineWidth: 1) }
        .background(WellAnchorView(anchor: anchor))
        .disabled(!session.canEditPalette)
        .onDisappear { session.wellDisappeared(anchor.view) }
    }
}

/// Holds the view a well's popover points at.
final class WellAnchor {
    weak var view: NSView?
}

struct WellAnchorView: NSViewRepresentable {
    let anchor: WellAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// A dialog's color: a well whose picker follows the working color into the dialog and keeps the one chosen. A dialog
/// covers the canvas, so it has no eyedropper. `closePicker()` puts the picker away with the dialog.
struct DialogColorSwatch: View {
    let title: String
    @Binding var color: PaletteColor
    let session: EditorSession
    var body: some View {
        ColorWell(title: title, color: color, session: session, samples: false) {
            session.openDialogColorPicker(title: title, color: color) { color = $0 }
        }
        .onDisappear { Self.closePicker(session) }
    }
    static func closePicker(_ session: EditorSession) {
        if session.pickingForDialog { session.closeColorPicker(commit: true) }
    }
}
