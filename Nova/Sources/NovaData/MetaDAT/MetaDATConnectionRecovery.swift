import Foundation
import NovaCore

#if canImport(MWDATCore) && os(iOS)
import MWDATCore
#endif

/// Opens Meta AI recovery destinations for glasses DAT/firmware issues, then
/// waits for URL-gate settle so the next `createSession` sees an updated device.
public enum MetaDATConnectionRecovery {
    /// Opens Meta AI’s DAT-on-glasses update flow. Returns `true` if the SDK
    /// accepted the navigation (caller should wait longer for the user to finish).
    @discardableResult
    public static func openDATGlassesAppUpdate() async -> Bool {
        #if canImport(MWDATCore) && os(iOS)
        do {
            try await Wearables.shared.openDATGlassesAppUpdate()
            NovaLog.session.info("Opened Meta AI DAT glasses app update")
            return true
        } catch {
            NovaLog.session.error(
                "openDATGlassesAppUpdate failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
        #else
        return false
        #endif
    }

    /// Opens Meta AI’s firmware update screen. Incompatible firmware often
    /// surfaces as `noEligibleDevice` rather than a dedicated error.
    @discardableResult
    public static func openFirmwareUpdate() async -> Bool {
        #if canImport(MWDATCore) && os(iOS)
        do {
            try await Wearables.shared.openFirmwareUpdate()
            NovaLog.session.info("Opened Meta AI glasses firmware update")
            return true
        } catch {
            NovaLog.session.error(
                "openFirmwareUpdate failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
        #else
        return false
        #endif
    }

    /// Wait for Meta AI deep-link settle after a recovery navigation.
    public static func waitAfterRecovery(openedMetaAI: Bool) async {
        let extra = openedMetaAI ? 2_500 : 800
        await MetaWearablesURLGate.shared.waitUntilSettled(extraMilliseconds: extra)
    }
}
