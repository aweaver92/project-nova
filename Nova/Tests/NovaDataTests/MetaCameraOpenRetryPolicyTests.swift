import XCTest
@testable import NovaCore
@testable import NovaData
@testable import NovaDomain

final class MetaCameraOpenRetryPolicyTests: XCTestCase {
    func testRetriesSessionStoppedBeforeStarted() {
        let error = NovaError.vision("Glasses session stopped before it started")
        XCTAssertTrue(MetaCameraOpenRetryPolicy.isRetryable(error))
        XCTAssertTrue(MetaCameraOpenRetryPolicy.isRetryableMessage("Glasses session stopped before it started"))
    }

    func testRetriesStreamStartTimeout() {
        XCTAssertTrue(MetaCameraOpenRetryPolicy.isRetryableMessage("Glasses stream did not start in time"))
        XCTAssertTrue(MetaCameraOpenRetryPolicy.isRetryable(NovaError.vision("Glasses stream did not start in time")))
    }

    func testRetriesNoEligibleDeviceMessage() {
        XCTAssertTrue(MetaCameraOpenRetryPolicy.isRetryableMessage("DeviceSessionError.noEligibleDevice"))
        XCTAssertTrue(MetaCameraOpenRetryPolicy.isRetryableMessage("no device"))
    }

    func testDoesNotRetryHardPermissionDenial() {
        let error = NovaError.vision(
            "Camera permission was not granted in Meta AI. Open Meta AI → Apps → Nova and allow camera, then retry."
        )
        XCTAssertFalse(MetaCameraOpenRetryPolicy.isRetryable(error))
    }

    func testPermissionUnavailableMessagesDoNotLookLikeUserDenial() {
        XCTAssertTrue(MetaCameraOpenRetryPolicy.isPermissionUnavailableMessage("PermissionError.noDevice"))
        XCTAssertTrue(MetaCameraOpenRetryPolicy.isPermissionUnavailableMessage("noDeviceWithConnection"))
        XCTAssertTrue(MetaCameraOpenRetryPolicy.isPermissionUnavailableMessage("permission unavailable"))
        XCTAssertFalse(MetaCameraOpenRetryPolicy.isPermissionUnavailableMessage("user tapped deny"))
    }

    func testDATAppUpdateRequiredIsNotSoftRetryable() {
        let message = "DeviceSessionError.datAppOnTheGlassesUpdateRequired"
        XCTAssertTrue(MetaCameraOpenRetryPolicy.isDATAppUpdateRequiredMessage(message))
        XCTAssertFalse(MetaCameraOpenRetryPolicy.isRetryableMessage(message))
        XCTAssertTrue(
            MetaCameraOpenRetryPolicy.isDATAppUpdateRequired(
                NovaError.vision("Glasses session failed: \(message).")
            )
        )
        XCTAssertFalse(
            MetaCameraOpenRetryPolicy.isRetryable(
                NovaError.vision("Glasses session failed: \(message).")
            )
        )
    }

    func testDATAppUpdateRequiredHumanCopy() {
        XCTAssertTrue(
            MetaCameraOpenRetryPolicy.isDATAppUpdateRequiredMessage(
                "The app on your glasses needs an update before this session can start. Go to the App Connections page in Meta AI to update it."
            )
        )
    }

    func testFirmwareUpdateLikelyForNoEligibleDevice() {
        XCTAssertTrue(
            MetaCameraOpenRetryPolicy.isFirmwareUpdateLikely(
                NovaError.vision("Glasses session failed: DeviceSessionError.noEligibleDevice.")
            )
        )
        XCTAssertFalse(
            MetaCameraOpenRetryPolicy.isFirmwareUpdateLikely(
                NovaError.vision("DeviceSessionError.datAppOnTheGlassesUpdateRequired")
            )
        )
    }
}
