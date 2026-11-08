#if os(iOS)
import AppIntents
import WidgetKit

/// Shared by app and widget targets; selecting a provider never opens or starts a chat.
struct SelectWidgetProviderIntent: AppIntent {
    static let title: LocalizedStringResource = "Select New Chat Provider"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Provider") var provider: String

    init() {}
    init(provider: WidgetChatShortcut) { self.provider = provider.rawValue }

    @MainActor func perform() async throws -> some IntentResult {
        guard let selection = WidgetChatShortcut(rawValue: provider) else { throw SelectionError.unknownProvider }
        WidgetChatShortcut.select(selection)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetChatShortcut.widgetKind)
        return .result()
    }

    private enum SelectionError: Error { case unknownProvider }
}
#endif
