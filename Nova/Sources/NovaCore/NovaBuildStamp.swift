import Foundation

/// Build identity baked into the binary at IPA compile time.
/// AltStore/SideStore often rewrite `CFBundleVersion` to `1.0 (1)`, so the
/// Listen banner and Settings must prefer this constant over the Info.plist.
public enum NovaBuildStamp {
    /// Overwritten by CI before `xcodegen` / `xcodebuild`. Format: `<sha>-<UTC mmdd-HHMM>`.
    public static let id = "local-dev"
}
