import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Prevents the phone screen from sleeping while a long Coding bridge run needs
/// the process awake. Screen timeout was dropping the PC SSE/poll connection.
public enum ScreenPresence {
    @MainActor
    public static func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}
