import Observation
import SwiftUI
import UIKit
import UserNotifications

@MainActor @Observable final class MobilePushNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MobilePushNotifications()
    private(set) var status = "Notifications are off."
    var pendingChat: UUID?
    var readingChat: UUID?
    var enabled: Bool { AppPreferences.defaults.bool(forKey: "pushEnabled") }
    var registration: Companion.PushRegistration? {
        guard let token = AppPreferences.defaults.string(forKey: "apnsToken") else { return nil }
        let environment = Bundle.main.object(forInfoDictionaryKey: "ChatterboxAPNsEnvironment") as? String
        return Companion.PushRegistration(token: token, environment: environment == "production" ? "production" : "sandbox", enabled: enabled)
    }
    func start() {
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshPermission() }
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["CHATTERBOX_TEST_HOST"] == "127.0.0.1", let port = env["CHATTERBOX_TEST_PORT"], port != String(Companion.port),
           let id = env["CHATTERBOX_TEST_PUSH_CHAT"].flatMap(UUID.init(uuidString:)) {
            pendingChat = id
        }
        #endif
    }
    func enable() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            AppPreferences.defaults.set(granted, forKey: "pushEnabled")
            if granted { status = "Connecting to Apple…"; UIApplication.shared.registerForRemoteNotifications() }
            else { status = "Allow notifications in iOS Settings → Chatterbox." }
        } catch { status = error.localizedDescription }
    }
    func disable() {
        AppPreferences.defaults.set(false, forKey: "pushEnabled")
        status = "Notifications are off."
    }
    func refreshPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .denied {
            disable(); status = "Notifications are disabled in iOS Settings."
        } else if enabled {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
    func receivedToken(_ data: Data) {
        AppPreferences.defaults.set(data.map { String(format: "%02x", $0) }.joined(), forKey: "apnsToken")
        status = "Ready to connect notifications to your Mac."
    }
    func failed(_ error: Error) { status = "Apple registration failed: " + error.localizedDescription }
    func synced() { status = enabled ? "Notifications connected to your Mac." : "Notifications are off." }
    func syncFailed(_ error: Error) { status = "Couldn’t update notification settings on your Mac: " + error.localizedDescription }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["chat"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in if let id { self.pendingChat = id }; completionHandler() }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let chat = (notification.request.content.userInfo["chat"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            // Only suppress the chat currently visible; other chats still get a banner.
            completionHandler(chat != nil && chat == self.readingChat ? [] : [.banner, .sound])
        }
    }
}

final class MobilePushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MobilePushNotifications.shared.start()
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MobilePushNotifications.shared.receivedToken(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MobilePushNotifications.shared.failed(error)
    }
}

struct MobileNotificationSettings: View {
    var body:some View {Form {MobileNotificationControls()}.navigationTitle("Notifications")}
}

struct MobileNotificationControls: View {
    @Environment(MobileStore.self) private var store
    private var push: MobilePushNotifications { .shared }
    var body: some View {
        Section {
                Toggle("Notifications", isOn: Binding(get: { push.enabled }, set: { on in
                    Task {
                        if on { await push.enable() } else { push.disable() }
                        await store.syncPushRegistration(force: true)
                    }
                }))
                Text(push.status).font(.callout).foregroundStyle(.secondary)
                Button("Open iOS Settings") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
                Button("Reconnect Notifications") {
                    Task { await push.refreshPermission(); await store.syncPushRegistration(force: true) }
                }
            } header: {Text("Notifications")} footer: {
                Text("Your Mac’s background services send notifications while it is awake. Configure notification delivery on your Mac. Tap an alert to open its chat.")
        }
    }
}
