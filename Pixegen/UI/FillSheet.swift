import AppKit
import SwiftUI

/// A dialog's well for a color or a gradient: it shows whichever it holds, and opens the picker with the list at its top
/// to switch between them. A dialog covers the canvas, so it has no eyedropper.
struct PaintWell: View {
    let title: String
    @Binding var paint: Paint
    let session: EditorSession
    var width: CGFloat = 120
    @State private var anchor = WellAnchor()

    var body: some View {
        Button {
            session.clickColorWell(anchor.view) {
                session.openDialogPaintPicker(title: title, paint: paint) { paint = $0 }
            }
        } label: {
            Group {
                switch paint {
                case .color(let color):
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.swiftUI)
                        .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(0.45), lineWidth: 1) }
                case .gradient(let gradient):
                    GradientStrip(gradient: gradient.isReversed ? gradient.reversed : gradient, cornerRadius: 5)
                }
            }
            .frame(width: width, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(WellAnchorView(anchor: anchor))
        .help(title)
        .accessibilityLabel(title)
        .onDisappear { DialogColorSwatch.closePicker(session) }
    }
}

/// Edit › Fill…: the selection, or the whole layer when there is none, filled with a color or a gradient.
struct FillSheet: View {
    let session: EditorSession
    let finish: (Paint?) -> Void
    @State private var paint: Paint

    init(session: EditorSession, finish: @escaping (Paint?) -> Void) {
        self.session = session
        self.finish = finish
        _paint = State(initialValue: .color(session.paletteColor(background: false)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session.selection == nil ? "Fill the layer" : "Fill the selection").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text("Contents")
                    PaintWell(title: "Fill contents", paint: $paint, session: session, width: 160)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { DialogColorSwatch.closePicker(session); finish(nil) }.configuredNativeShortcut(.escape)
                Button("OK") {
                    DialogColorSwatch.closePicker(session)
                    finish(paint)
                }
                .configuredNativeShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

extension ProjectController {
    /// Edit › Fill…: asks what to fill with in a sheet, then fills.
    func fill() async {
        guard let window, window.attachedSheet == nil, session.canEditPixels else { return }
        let choice: Paint? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Fill"
            sheet.contentViewController = NSHostingController(rootView: FillSheet(session: session) { choice in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: choice)
            })
            window.beginSheet(sheet)
        }
        guard let choice else { return }
        await session.fillSelection(with: choice)
    }
}
