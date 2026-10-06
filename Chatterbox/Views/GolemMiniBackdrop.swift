#if GOLEM_APP
import SwiftUI
import AppKit

struct GolemMiniBackdrop: View {
    @AppStorage("golemMiniCircleRGB") private var rgb = 0
    @AppStorage("golemMiniCircleOpacity") private var opacity = 0.3
    static func color(_ rgb: Int) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    var body: some View {
        Circle().fill(Self.color(rgb).opacity(min(1, max(0, opacity))))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct GolemMiniBackdropSettings: View {
    @AppStorage("golemMiniCircleRGB") private var rgb = 0
    @AppStorage("golemMiniCircleOpacity") private var opacity = 0.3
    var body: some View {
        ColorPicker("Circle color", selection: Binding(get: { GolemMiniBackdrop.color(rgb) }, set: { value in
            guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
            rgb = Int((color.redComponent * 255).rounded()) << 16 | Int((color.greenComponent * 255).rounded()) << 8 | Int((color.blueComponent * 255).rounded())
        }), supportsOpacity: false)
        HStack {
            Slider("Circle opacity", value: $opacity, in: 0...1, step: 0.05)
            Text(opacity, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit().frame(width: 42, alignment: .trailing)
        }
        Text("Set opacity to 0% to hide the circle.").font(.caption).foregroundStyle(.secondary)
    }
}
#endif
