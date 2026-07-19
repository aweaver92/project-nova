import Foundation
import NovaCore

#if canImport(MWDATCore) && os(iOS)
import MWDATCore
#endif

/// Classifies glasses-camera open failures that should be retried after Always Allow
/// (BLE/link lag, missed session state, stream settle).
public enum MetaCameraOpenRetryPolicy {
    public static func isRetryable(_ error: Error) -> Bool {
        if let nova = error as? NovaError, case .vision(let message) = nova {
            return isRetryableMessage(message)
        }
        #if canImport(MWDATCore) && os(iOS)
        if let sessionError = error as? DeviceSessionError {
            switch sessionError {
            case .noEligibleDevice:
                return true
            default:
                break
            }
        }
        #endif
        return isRetryableMessage(String(describing: error))
    }

    public static func isRetryableMessage(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("noeligibledevice")
            || lower.contains("nodevicewithconnection")
            || lower.contains("no device")
            || lower.contains("stopped before it started")
            || lower.contains("did not start in time")
            || lower.contains("stream did not start")
    }

    /// True when a permission *check* failed because glasses are disconnected —
    /// must not be treated as `.denied` (which would reopen Meta AI).
    public static func isPermissionUnavailableMessage(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("nodevice")
            || lower.contains("no device")
            || lower.contains("nodevicewithconnection")
            || lower.contains("unavailable")
            || lower.contains("not connected")
            || lower.contains("connectionerror")
            || lower.contains("connection error")
    }
}
