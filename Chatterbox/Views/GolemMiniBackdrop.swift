#if GOLEM_APP
import SwiftUI
import AppKit

struct GolemMiniBackdrop: View {
    var cornerRadius: CGFloat = 1000
    var expanded = false
    @AppStorage("golemMiniCircleRGB") private var rgb = 0
    @AppStorage("golemMiniCircleOpacity") private var opacity = 0.3
    @AppStorage("golemMiniCircleEdgeBlur") private var circleBlur = 2.0
    @AppStorage("golemMiniExpandedEdgeBlur") private var expandedBlur = 2.0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    static func color(_ rgb: Int) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let strength = min(1, max(0, opacity))
        Group {
            if reduceTransparency {
                shape.fill(Self.color(rgb).opacity(strength))
            } else if #available(macOS 26.0, *) {
                DesktopGlassBlur()
                    .clipShape(shape)
                    .glassEffect(.clear, in: shape)
                    .opacity(strength)
                    .overlay(shape.fill(Self.color(rgb).opacity(strength)))
            } else {
                DesktopGlassBlur().clipShape(shape)
                    .opacity(strength)
                    .overlay(shape.fill(Self.color(rgb).opacity(strength)))
            }
        }
            // Feather only the backdrop silhouette; the avatar and controls stay crisp.
            .mask {
                GeometryReader { geometry in
                    let feather = min(CGFloat(max(0, min(16, expanded ? expandedBlur : circleBlur))), min(geometry.size.width, geometry.size.height) / 4)
                    shape
                        .fill(.white)
                        .padding(feather)
                        .blur(radius: feather)
                }
            }
            .opacity(strength == 0 ? 0 : 1)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A floating transparent panel must sample the desktop, rather than its empty content.
private struct DesktopGlassBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct GolemMiniBackdropSettings: View {
    @AppStorage("golemMiniCircleSize") private var circleSize = 0.64
    @AppStorage("golemMiniCircleRGB") private var rgb = 0
    @AppStorage("golemMiniCircleOpacity") private var opacity = 0.3
    @AppStorage("golemMiniCircleEdgeBlur") private var circleBlur = 2.0
    @AppStorage("golemMiniExpandedEdgeBlur") private var expandedBlur = 2.0
    var body: some View {
        HStack {
            Slider(value: $circleSize, in: 0.3...1, step: 0.01) { Text("Circle size") }
            Text(circleSize, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit().frame(width: 42, alignment: .trailing)
        }
        ColorPicker("Circle color", selection: Binding(get: { GolemMiniBackdrop.color(rgb) }, set: { value in
            guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
            rgb = Int((color.redComponent * 255).rounded()) << 16 | Int((color.greenComponent * 255).rounded()) << 8 | Int((color.blueComponent * 255).rounded())
        }), supportsOpacity: false)
        HStack {
            Slider(value: $opacity, in: 0...1, step: 0.05) { Text("Circle opacity") }
            Text(opacity, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit().frame(width: 42, alignment: .trailing)
        }
        Text("Set opacity to 0% to hide the circle.").font(.caption).foregroundStyle(.secondary)
        blurSlider("Circle edge blur", value: $circleBlur)
        blurSlider("Expanded mini edge blur", value: $expandedBlur)
        Text("0 gives a crisp edge. Higher values soften the backdrop only.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func blurSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Slider(value: value, in: 0...16, step: 1) { Text(label) }
            Text("\(Int(value.wrappedValue)) pt")
                .monospacedDigit().frame(width: 42, alignment: .trailing)
        }
    }
}
#endif
