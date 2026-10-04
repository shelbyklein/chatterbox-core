import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from sleeping while Chatterbox is open, so your phone can reach it and
/// agents, check-ins, and the email watch keep running. The display still sleeps; closing a
/// laptop's lid still sleeps it (unless it's on power with an external display).
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()
    static let key = "keepMacAwake"

    private var assertion: IOPMAssertionID = 0
    private var held = false

    var isOn: Bool { AppPreferences.defaults.object(forKey: Self.key) as? Bool ?? true }

    /// Holds or releases the assertion to match the setting.
    func apply() {
        if isOn, !held {
            held = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "Chatterbox keeps your Mac awake for your phone and agents" as CFString, &assertion) == kIOReturnSuccess
        } else if !isOn, held {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }
}
