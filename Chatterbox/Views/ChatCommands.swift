import Observation

/// Menu commands that open a control inside the current chat. The menu bumps a counter and
/// the chat's view toggles the matching popover, so the popovers keep their own state.
@MainActor
@Observable
final class ChatCommands {
    static let shared = ChatCommands()

    private(set) var modelPopoverRequests = 0
    private(set) var modePopoverRequests = 0
    var showingQuickSwitcher = false

    func toggleModelPopover() { modelPopoverRequests += 1 }
    func toggleModePopover() { modePopoverRequests += 1 }
}
