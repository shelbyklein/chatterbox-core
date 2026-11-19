import UIKit

/// Whether the app is in front, straight from iOS (UIApplication's own state and its
/// notifications), for work that must not depend on SwiftUI's scenePhase reaching a view: that
/// value is handed down through the view tree and was suspected of going stale on the Duo, which
/// left chat images waiting and Download taps ignored.
@MainActor @Observable
final class MobileAppState {
    static let shared = MobileAppState()
    /// In front and taking touches.
    private(set) var isActive: Bool
    /// Off screen: nothing new starts.
    private(set) var isBackground: Bool

    private init() {
        let state = UIApplication.shared.applicationState
        isActive = state == .active
        isBackground = state == .background
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ change: @escaping @MainActor (MobileAppState) -> Void) {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { change(self) } }
            }
        }
        on(UIApplication.didBecomeActiveNotification) { $0.isActive = true; $0.isBackground = false }
        on(UIApplication.willResignActiveNotification) { $0.isActive = false }
        on(UIApplication.didEnterBackgroundNotification) { $0.isActive = false; $0.isBackground = true }
        on(UIApplication.willEnterForegroundNotification) { $0.isBackground = false }
    }
}
