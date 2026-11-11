import Foundation
import IOKit.pwr_mgt

/// Thin wrapper around an IOKit power assertion (what `caffeinate` uses).
/// Prevents idle sleep while held, but NOT sleep on lid close — see `LidSleepControl`.
final class PowerAssertion {
    enum Kind: String {
        case preventIdleSystemSleep = "PreventUserIdleSystemSleep"
        case preventIdleDisplaySleep = "PreventUserIdleDisplaySleep"
    }

    private let kind: Kind
    private let reason: String
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)

    init(_ kind: Kind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    deinit { release() }

    var isHeld: Bool { assertionID != 0 }

    func set(_ held: Bool) {
        held ? acquire() : release()
    }

    private func acquire() {
        guard !isHeld else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kind.rawValue as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if result == kIOReturnSuccess { assertionID = id }
    }

    private func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }
}
