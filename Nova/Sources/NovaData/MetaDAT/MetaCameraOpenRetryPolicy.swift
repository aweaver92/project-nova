import Foundation
import NovaCore

#if canImport(MWDATCore) && os(iOS)
import MWDATCore
#endif

/// Classifies glasses-camera open failures that should be retried after Always Allow
/// (BLE/link lag, missed session state, stream settle), or recovered via Meta AI
/// DAT/firmware update deep-links (one-shot, not soft sleep-retry).
public enum MetaCameraOpenRetryPolicy {
    public static func isRetryable(_ error: Error) -> Bool {
        if isDATAppUpdateRequired(error) { return false }
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
        if isDATAppUpdateRequiredMessage(text) { return false }
        let lower = text.lowercased()
        return lower.contains("noeligibledevice")
            || lower.contains("nodevicewithconnection")
            || lower.contains("no device")
            || lower.contains("stopped before it started")
            || lower.contains("did not start in time")
            || lower.contains("stream did not start")
    }

    /// True when the on-glasses DAT/DWA bundle must be installed or updated via Meta AI.
    public static func isDATAppUpdateRequired(_ error: Error) -> Bool {
        #if canImport(MWDATCore) && os(iOS)
        if let sessionError = error as? DeviceSessionError {
            switch sessionError {
            case .datAppOnTheGlassesUpdateRequired:
                return true
            default:
                break
            }
        }
        #endif
        if let nova = error as? NovaError, case .vision(let message) = nova {
            return isDATAppUpdateRequiredMessage(message)
        }
        return isDATAppUpdateRequiredMessage(String(describing: error))
    }

    public static func isDATAppUpdateRequiredMessage(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("datappontheglassesupdaterequired")
            || lower.contains("dat_app_on_the_glasses_update_required")
            || (lower.contains("app on your glasses") && lower.contains("update"))
            || (lower.contains("app connections") && lower.contains("update"))
    }

    /// True when soft retries for “no eligible device” should escalate to firmware update.
    public static func isFirmwareUpdateLikely(_ error: Error) -> Bool {
        if isDATAppUpdateRequired(error) { return false }
        if let nova = error as? NovaError, case .vision(let message) = nova {
            return isFirmwareUpdateLikelyMessage(message)
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
        return isFirmwareUpdateLikelyMessage(String(describing: error))
    }

    public static func isFirmwareUpdateLikelyMessage(_ text: String) -> Bool {
        if isDATAppUpdateRequiredMessage(text) { return false }
        let lower = text.lowercased()
        return lower.contains("noeligibledevice")
            || lower.contains("deviceupdaterequired")
            || lower.contains("device update required")
            || lower.contains("firmware")
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
