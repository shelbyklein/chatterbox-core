import SwiftUI

/// Agent identity on mobile. Bubble fills are dark enough for white message text in either theme.
enum MobileConversationStyle {
    static func bubble(for backend: String) -> Color {
        if let chosen = MobileAppearance.chosen(for: backend) { return chosen }
        return backend == "codex" ? Color(red: 0.14, green: 0.42, blue: 0.27)
            : Color(red: 0.62, green: 0.28, blue: 0.11)
    }

    static func accent(for backend: String) -> Color {
        if let chosen = MobileAppearance.chosen(for: backend) { return chosen }
        return Color(uiColor: UIColor { traits in
            if backend == "codex" {
                return traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.36, green: 0.78, blue: 0.55, alpha: 1)
                    : UIColor(red: 0.14, green: 0.42, blue: 0.27, alpha: 1)
            }
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.96, green: 0.61, blue: 0.36, alpha: 1)
                : UIColor(red: 0.62, green: 0.28, blue: 0.11, alpha: 1)
        })
    }
}

