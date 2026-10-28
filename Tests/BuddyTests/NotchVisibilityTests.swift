import XCTest
@testable import Buddy

final class NotchVisibilityTests: XCTestCase {
    func testHiddenCannotBeClickedUntilActivation() {
        var notch = NotchVisibility()
        XCTAssertFalse(notch.visible)
        XCTAssertFalse(notch.clickable)
        notch.clickedCapsule()
        XCTAssertFalse(notch.expanded)
        notch.activate()
        XCTAssertTrue(notch.visible)
        XCTAssertTrue(notch.clickable)
        XCTAssertTrue(notch.expanded)
    }

    func testOutsideClickOnlyCollapsesAndCompactClickReopens() {
        var notch = NotchVisibility()
        notch.activate()
        notch.clickedOutside()
        XCTAssertTrue(notch.visible)
        XCTAssertTrue(notch.clickable)
        XCTAssertFalse(notch.expanded)
        notch.clickedCapsule()
        XCTAssertTrue(notch.expanded)
    }

    func testCompletionGraceAndStaleDismissal() {
        var notch = NotchVisibility()
        notch.activate()
        let first = notch.complete()
        XCTAssertEqual(notch.phase, .grace)
        XCTAssertTrue(notch.clickable)
        notch.clickedOutside()
        XCTAssertFalse(notch.beginDismissal(ifGeneration: first))
        let second = notch.generation
        XCTAssertTrue(notch.beginDismissal(ifGeneration: second))
        XCTAssertFalse(notch.clickable)
        notch.clickedCapsule()
        XCTAssertFalse(notch.expanded)
        XCTAssertTrue(notch.finishDismissal(ifGeneration: second))
        XCTAssertFalse(notch.visible)
        notch.clickedCapsule()
        XCTAssertFalse(notch.visible)
    }

    func testNewActivationCancelsOldHideAndShutdownDisablesClicks() {
        var notch = NotchVisibility()
        notch.activate()
        let old = notch.complete()
        notch.activate()
        XCTAssertFalse(notch.beginDismissal(ifGeneration: old))
        XCTAssertEqual(notch.phase, .active)
        notch.shutdown()
        XCTAssertFalse(notch.visible)
        XCTAssertFalse(notch.clickable)
    }
}
