import Foundation
import IOKit.pwr_mgt

/// A public idle-sleep assertion (ADR 007). This is `PreventUserIdleSystemSleep`
/// — it keeps the machine awake while work runs, but does NOT by itself keep it
/// running with the lid closed (S01). The CLI never claims otherwise.
public final class IdleAssertion {
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    public init() {}

    @discardableResult
    public func acquire(reason: String) -> Bool {
        guard !held else { return true }
        let rc = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        held = (rc == kIOReturnSuccess)
        return held
    }

    public func release() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
    }

    public var isHeld: Bool { held }
    deinit { release() }
}
