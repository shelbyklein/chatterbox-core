import Foundation

/// Native fixtures use an explicit preference suite, never either installed app's domain.
/// Existing unit harnesses retain their volatile standard-defaults injection.
enum AppPreferences {
    static let defaults:UserDefaults={
        if let suite=ProcessInfo.processInfo.environment["CHATTERBOX_PREFERENCES_SUITE"] {return UserDefaults(suiteName:suite)!}
        return .standard
    }()
}
