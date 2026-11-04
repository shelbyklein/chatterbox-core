import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension Color {
    /// "Needs you", on the phone and the Mac alike: yellow in dark mode, a darker amber in light
    /// mode, where yellow on white can't be read (#8C5A00 is 5.9:1 on white). Always beside an
    /// icon or a word, never the only sign.
    static let attention: Color = {
        let amber = (red: 140.0 / 255, green: 90.0 / 255, blue: 0.0)
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemYellow : UIColor(red: amber.red, green: amber.green, blue: amber.blue, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemYellow : NSColor(srgbRed: amber.red, green: amber.green, blue: amber.blue, alpha: 1)
        })
        #endif
    }()

    /// Secondary text that stays readable (at least 4.5:1) on cards in both modes: the system's
    /// secondary label is lighter than that on a light card's grey.
    static let metadata: Color = {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.66) : UIColor(white: 0, alpha: 0.64)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.66) : NSColor(white: 0, alpha: 0.64)
        })
        #endif
    }()
}
