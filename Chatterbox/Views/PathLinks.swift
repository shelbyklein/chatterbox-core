#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Paths an agent writes as code (`/Users/…/final/`, `svg/`, `logo.png`) become links that
/// show the file in Finder. A relative path is looked for in the folders the same reply
/// names, then in the chat's folder. Only paths that exist are linked, so ordinary code
/// like `record.items` stays plain.
private struct ChatFolderKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The folder the chat works in, for resolving paths in its replies.
    var chatFolder: String? {
        get { self[ChatFolderKey.self] }
        set { self[ChatFolderKey.self] = newValue }
    }
}
