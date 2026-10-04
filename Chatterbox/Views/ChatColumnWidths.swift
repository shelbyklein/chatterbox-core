import Foundation

/// One allocation for the entire window. Child fitting sizes never determine these widths.
struct ChatColumnWidths {
    let sidebar: CGFloat
    let chat: CGFloat
    let inspector: CGFloat
    let inspectorOverlay: Bool
    static let divider: CGFloat = 6

    init(window: CGFloat, sidebarOpen: Bool, sidebarDesired: CGFloat,
         inspectorOpen: Bool, inspectorDesired: CGFloat, inspectorMinimum: CGFloat) {
        let width = max(0, window)
        let rightMin = inspectorOpen ? inspectorMinimum : 0
        let leftMin: CGFloat = sidebarOpen ? 230 : 0
        let needed = leftMin + 400 + rightMin + (leftMin > 0 ? 6 : 0) + (rightMin > 0 ? 6 : 0)
        // Below the three-column minimum, the right panel becomes an overlay. Below the
        // two-column minimum, the sidebar is available through its toolbar button instead.
        inspectorOverlay = inspectorOpen && width < 400 + rightMin + 6
        let rightInline = inspectorOpen && !inspectorOverlay
        let leftInline = sidebarOpen && width >= needed
        let gaps: CGFloat = (leftInline ? 6 : 0) + (rightInline ? 6 : 0)
        let available = max(0, width - gaps)
        let left = leftInline ? min(max(230, sidebarDesired), max(230, available - 400 - (rightInline ? rightMin : 0))) : 0
        let right = rightInline ? min(max(rightMin, inspectorDesired), max(rightMin, available - left - 400)) : 0
        sidebar = left
        inspector = right
        chat = max(0, available - left - right)
    }
    var chatX: CGFloat { sidebar > 0 ? sidebar + Self.divider : 0 }
    var inspectorX: CGFloat { chatX + chat + (inspector > 0 ? Self.divider : 0) }
}

