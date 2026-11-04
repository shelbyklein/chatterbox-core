import Foundation

/// Native fixtures use an explicit preference suite, never either installed app's domain.
/// Existing unit harnesses retain their volatile standard-defaults injection.
/// Chatterbox Dev's service keeps a suite of its own (the real one's is its standard domain,
/// "chatterboxd"); the Dev app's standard domain is already its own (its bundle id).
enum AppPreferences {
    static let defaults:UserDefaults={
        if let suite=ProcessInfo.processInfo.environment["CHATTERBOX_PREFERENCES_SUITE"] {return UserDefaults(suiteName:suite)!}
        #if CHATTERBOX_HEADLESS
        if let suite=Flavor.current.servicePreferencesSuite {return UserDefaults(suiteName:suite)!}
        #endif
        return .standard
    }()
}
