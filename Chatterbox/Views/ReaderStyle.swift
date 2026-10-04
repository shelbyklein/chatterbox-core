#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// How the transcript reads: font, sizes, and spacing, chosen in Settings → Appearance.
struct ReaderStyle: Equatable {
    var textSize: CGFloat = 13
    var lineSpacing: CGFloat = 3
    var paragraphSpacing: CGFloat = 10
    var codeSize: CGFloat = 12
    var contentWidth: CGFloat = 820
    var design: Font.Design = .default
    /// Each agent's color: your message bubbles, the message box, and the model line.
    var claudeColor: Color = ReaderStyle.bubbleColor(ReaderStyle.claudeDefault)
    var codexColor: Color = ReaderStyle.bubbleColor(ReaderStyle.codexDefault)
    var bubbleStrength: Double = 0.18
    /// Tighter spacing for step rows, notes, and thinking.
    var compactSteps = false
    var showThinking = true

    static let defaults = ReaderStyle()
    static let claudeDefault = "#D97757"
    static let codexDefault = "#10A37F"

    func color(for backend: Backend) -> Color { backend == .claude ? claudeColor : codexColor }

    var body: Font { .system(size: textSize, design: design) }
    /// Status rows, commentary, and table cells: a step below the body.
    var secondary: Font { .system(size: textSize - 1, design: design) }
    var code: Font { .system(size: codeSize, design: .monospaced) }

    func heading(_ level: Int) -> Font {
        let scale: CGFloat = level == 1 ? 1.45 : level == 2 ? 1.25 : 1.08
        return .system(size: (textSize * scale).rounded(), weight: .semibold, design: design)
    }

    static let designs: [(id: String, label: String, design: Font.Design)] = [
        ("default", "System", .default),
        ("rounded", "Rounded", .rounded),
        ("serif", "Serif", .serif),
        ("monospaced", "Monospaced", .monospaced),
    ]

    static func design(_ id: String) -> Font.Design {
        designs.first { $0.id == id }?.design ?? .default
    }

    static let bubbleColors: [(id: String, label: String, color: Color)] = [
        (claudeDefault, "Clay", bubbleColor(claudeDefault)), (codexDefault, "Green", bubbleColor(codexDefault)),
        ("accent", "Accent", .accentColor), ("blue", "Blue", .blue), ("purple", "Purple", .purple),
        ("pink", "Pink", .pink), ("orange", "Orange", .orange),
        ("teal", "Teal", .teal), ("gray", "Gray", .gray),
    ]

    /// A preset id, or "#RRGGBB" for a custom color.
    static func bubbleColor(_ id: String) -> Color {
        if id.hasPrefix("#"), let value = Int(id.dropFirst(), radix: 16) {
            return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                         blue: Double(value & 0xFF) / 255)
        }
        return bubbleColors.first { $0.id == id }?.color ?? .accentColor
    }

    static func hex(_ color: Color) -> String {
        #if canImport(AppKit)
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        #endif
    }
}

private struct ReaderStyleKey: EnvironmentKey {
    static let defaultValue = ReaderStyle.defaults
}

extension EnvironmentValues {
    var readerStyle: ReaderStyle {
        get { self[ReaderStyleKey.self] }
        set { self[ReaderStyleKey.self] = newValue }
    }
}

/// Reads the Appearance settings, so any view can build the current style.
struct ReaderStyleSettings: DynamicProperty {
    @AppStorage("readerTextSize") var textSize = Double(ReaderStyle.defaults.textSize)
    @AppStorage("readerLineSpacing") var lineSpacing = Double(ReaderStyle.defaults.lineSpacing)
    @AppStorage("readerParagraphSpacing") var paragraphSpacing = Double(ReaderStyle.defaults.paragraphSpacing)
    @AppStorage("readerCodeSize") var codeSize = Double(ReaderStyle.defaults.codeSize)
    @AppStorage("readerContentWidth") var contentWidth = Double(ReaderStyle.defaults.contentWidth)
    @AppStorage("readerFontDesign") var design = "default"
    @AppStorage("readerClaudeColor") var claudeColor = ReaderStyle.claudeDefault
    @AppStorage("readerCodexColor") var codexColor = ReaderStyle.codexDefault
    @AppStorage("readerBubbleStrength") var bubbleStrength = ReaderStyle.defaults.bubbleStrength
    @AppStorage("readerCompactSteps") var compactSteps = false
    @AppStorage("readerShowThinking") var showThinking = true

    var style: ReaderStyle {
        ReaderStyle(textSize: textSize, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing,
                    codeSize: codeSize, contentWidth: contentWidth, design: ReaderStyle.design(design),
                    claudeColor: ReaderStyle.bubbleColor(claudeColor), codexColor: ReaderStyle.bubbleColor(codexColor),
                    bubbleStrength: bubbleStrength,
                    compactSteps: compactSteps, showThinking: showThinking)
    }

    func reset() {
        let d = ReaderStyle.defaults
        textSize = d.textSize
        lineSpacing = d.lineSpacing
        paragraphSpacing = d.paragraphSpacing
        codeSize = d.codeSize
        contentWidth = d.contentWidth
        design = "default"
        claudeColor = ReaderStyle.claudeDefault
        codexColor = ReaderStyle.codexDefault
        bubbleStrength = d.bubbleStrength
        compactSteps = false
        showThinking = true
    }
}

/// The window's look, chosen in Settings → Appearance: light or dark, the background
/// (standard, dim, black, or any color), and the highlight color.
enum Theme {
    static let schemeKey = "themeScheme"         // system | light | dark
    static let backgroundKey = "themeBackground" // standard | dim | black | #RRGGBB
    static let highlightKey = "themeHighlight"   // default | a preset id | #RRGGBB

    static let backgrounds: [(id: String, label: String)] = [("standard", "Standard"), ("dim", "Dim"), ("black", "Black")]

    /// The background to paint, or nil for the system's own.
    static func background(_ id: String) -> Color? {
        switch id {
        case "standard", "": nil
        case "dim": Color(red: 0.085, green: 0.085, blue: 0.095)
        case "black": .black
        default: ReaderStyle.bubbleColor(id)
        }
    }

    /// Light or dark to match the background (dark text on black would vanish), else the
    /// chosen theme; nil follows the system.
    static func colorScheme(background id: String, scheme: String) -> ColorScheme? {
        switch id {
        case "standard", "": return scheme == "light" ? .light : scheme == "dark" ? .dark : nil
        case "dim", "black": return .dark
        default: return luminance(id) < 0.5 ? .dark : .light
        }
    }

    /// The sidebar: a shade off the background (lighter on dark ones, darker on light),
    /// so it reads as its own column.
    static func sidebar(_ id: String) -> Color? {
        let hex: String
        switch id {
        case "standard", "": return nil
        case "dim": hex = "#161618"
        case "black": hex = "#000000"
        default: hex = id
        }
        guard let value = Int(hex.dropFirst(), radix: 16) else { return background(id) }
        let dark = luminance(hex) < 0.5
        let shift = dark ? 0.055 : -0.04
        func channel(_ shiftBits: Int) -> Double { min(max(Double((value >> shiftBits) & 0xFF) / 255 + shift, 0), 1) }
        return Color(red: channel(16), green: channel(8), blue: channel(0))
    }

    static var currentBackground: Color? { background(AppPreferences.defaults.string(forKey: backgroundKey) ?? "standard") }

    /// 0 (black) to 1 (white) for a "#RRGGBB" color.
    static func luminance(_ hex: String) -> Double {
        guard hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return 0.5 }
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

extension Color {
    /// Chatterbox's own highlight: selection, progress, and emphasis. White in dark mode and
    /// black in light mode unless you pick a color in Settings → Appearance.
    static var highlight: Color {
        let id = AppPreferences.defaults.string(forKey: Theme.highlightKey) ?? "default"
        return id == "default" ? .primary : ReaderStyle.bubbleColor(id)
    }

    /// Text on a highlight-filled shape: the window color on the plain highlight, else white
    /// or black, whichever reads.
    static var onHighlight: Color {
        let id = AppPreferences.defaults.string(forKey: Theme.highlightKey) ?? "default"
        if id == "default" { return .windowBackground }
        let hex = id.hasPrefix("#") ? id : ReaderStyle.hex(ReaderStyle.bubbleColor(id))
        return Theme.luminance(hex) > 0.6 ? .black : .white
    }
}

/// The main button in a card (Submit, Next): filled with the highlight, text in the
/// background color, so it reads as primary without the system's blue.
struct HighlightButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .foregroundStyle(Color.onHighlight)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.highlight.opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.3)))
    }
}

extension Color {
    /// The window's own background, on either platform.
    static var windowBackground: Color {
        #if canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
