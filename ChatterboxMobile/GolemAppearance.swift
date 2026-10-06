#if GOLEM_APP
import SwiftUI
import UIKit

enum GolemBubbleColor {
    static let key = "golemOutgoingBubbleRGB"
    static let standard = 0x007AFF
    static let presets: [(String, Int)] = [("Blue", 0x007AFF), ("Purple", 0xAF52DE), ("Green", 0x248A3D), ("Orange", 0xFF9500), ("Rose", 0xFF375F)]
    static func color(_ rgb: Int) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    static func text(_ rgb: Int) -> Color {
        func linear(_ channel: Int) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((rgb >> 16) & 255) + 0.7152 * linear((rgb >> 8) & 255) + 0.0722 * linear(rgb & 255)
        return luminance > 0.179 ? .black : .white
    }
    static func rgb(_ color: Color) -> Int {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return standard }
        return (Int((r * 255).rounded()) << 16) | (Int((g * 255).rounded()) << 8) | Int((b * 255).rounded())
    }
}

struct GolemAppearanceSettings: View {
    @AppStorage(GolemBubbleColor.key, store: AppPreferences.defaults) private var rgb = GolemBubbleColor.standard
    var body: some View {
        Section("Appearance") {
            Picker("Message bubble color", selection: $rgb) {
                ForEach(GolemBubbleColor.presets, id: \.1) { name, value in Text(name).tag(value) }
                if !GolemBubbleColor.presets.contains(where: { $0.1 == rgb }) { Text("Custom").tag(rgb) }
            }
            ColorPicker("Custom bubble color", selection: Binding(get: { GolemBubbleColor.color(rgb) }, set: { rgb = GolemBubbleColor.rgb($0) }), supportsOpacity: false)
            HStack {
                Spacer()
                Text("Your messages look like this")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(GolemBubbleColor.text(rgb))
                    .background(GolemBubbleColor.color(rgb), in: RoundedRectangle(cornerRadius: 20))
            }
            Text("Applies to your messages. Text adjusts for readability; Golem’s replies stay neutral.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
