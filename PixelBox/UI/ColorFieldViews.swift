import SwiftUI

/// The picker's saturation (across) and brightness (down) square for the current hue. The Color palette shows one too.
struct SaturationBrightnessField: View {
    @Binding var hsb: PickerHSB
    let size: CGSize
    var body: some View {
        ZStack {
            LinearGradient(colors: [.white, PickerHSB(hue: hsb.hue, saturation: 1, brightness: 1).rgb.swiftUI],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            Circle()
                .strokeBorder(.white, lineWidth: 1.5)
                .background(Circle().strokeBorder(.black, lineWidth: 0.75).padding(-0.75))
                .frame(width: 12, height: 12)
                .position(x: hsb.saturation * size.width, y: (1 - hsb.brightness) * size.height)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(Rectangle())
        .overlay { Rectangle().strokeBorder(.black.opacity(0.6), lineWidth: 1) }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            hsb.saturation = min(1, max(0, value.location.x / size.width))
            hsb.brightness = 1 - min(1, max(0, value.location.y / size.height))
        })
        .accessibilityLabel("Saturation and brightness")
    }
}

/// The picker's vertical hue strip, red at both ends, with an arrow either side at the hue.
struct HueStrip: View {
    @Binding var hue: CGFloat
    let height: CGFloat
    var stripWidth: CGFloat = 20
    var body: some View {
        let markerY = (1 - hue / 360) * height
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: stride(from: 360.0, through: 0, by: -60).map {
                PickerHSB(hue: $0, saturation: 1, brightness: 1).rgb.swiftUI
            }, startPoint: .top, endPoint: .bottom)
                .frame(width: stripWidth, height: height)
                .overlay { Rectangle().strokeBorder(.black.opacity(0.6), lineWidth: 1) }
                .padding(.horizontal, 7)
            HStack(spacing: stripWidth) {
                HueArrow().fill(.primary).frame(width: 7, height: 10)
                HueArrow().fill(.primary).frame(width: 7, height: 10).scaleEffect(x: -1)
            }
            .offset(y: markerY - 5)
        }
        .frame(width: stripWidth + 14, height: height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            hue = (1 - min(1, max(0, value.location.y / height))) * 360
        })
        .accessibilityLabel("Hue")
        .accessibilityValue("\(Int(hue.rounded())) degrees")
    }
}

private struct HueArrow: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
