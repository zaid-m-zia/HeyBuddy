import XCTest
@testable import Buddy

final class NotchVisibilityTests: XCTestCase {
    func testNotchedGeometryStaysTopAnchoredAndExpandsSideways() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 500, y: 100, width: 1440, height: 900),
                                     centerX: 1220, notchWidth: 180, safeAreaTop: 38)
        let compact = geometry.frame(expanded: false)
        let expanded = geometry.frame(expanded: true)
        XCTAssertEqual(compact.maxY, 1000)
        XCTAssertEqual(expanded.maxY, 1000)
        XCTAssertEqual(compact.midX, expanded.midX)
        XCTAssertEqual(compact.width, 208)
        XCTAssertEqual(expanded.width, 509.6, accuracy: 0.01)
        XCTAssertEqual(compact.height, 62)
        XCTAssertEqual(expanded.height, 70)
        XCTAssertGreaterThan(expanded.width / compact.width, 2)
        XCTAssertLessThan(expanded.height - compact.height, 12)
    }

    func testFallbackUsesBuiltInScreenFrameWithoutInventingNotch() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: -1280, y: 0, width: 1280, height: 800),
                                     centerX: -640, notchWidth: nil, safeAreaTop: 0)
        XCTAssertEqual(geometry.notchDepth, 0)
        XCTAssertEqual(geometry.frame(expanded: false).maxY, 800)
        XCTAssertEqual(geometry.frame(expanded: true).midX, -640)
    }

    func testExpandedGeometryKeepsMarginsOnSmallerBuiltInDisplays() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                     centerX: 400, notchWidth: 180, safeAreaTop: 38)
        XCTAssertEqual(geometry.expandedSize.width, 480)
        XCTAssertLessThanOrEqual(geometry.expandedSize.width, geometry.screenFrame.width * 0.60)
    }

    func testActivationStartsCompactAndHoverAloneExpands() {
        var notch = NotchVisibility()
        XCTAssertFalse(notch.visible)
        XCTAssertFalse(notch.clickable)
        XCTAssertFalse(notch.setHovered(true))
        XCTAssertFalse(notch.expanded)
        notch.activate()
        XCTAssertTrue(notch.visible)
        XCTAssertTrue(notch.clickable)
        XCTAssertFalse(notch.expanded)
        XCTAssertTrue(notch.setHovered(true))
        XCTAssertTrue(notch.expanded)
    }

    func testHoverExitCollapsesAndReentryExpandsWithoutLeavingActiveState() {
        var notch = NotchVisibility()
        notch.activate()
        XCTAssertTrue(notch.setHovered(true))
        XCTAssertTrue(notch.setHovered(false))
        XCTAssertTrue(notch.visible)
        XCTAssertTrue(notch.clickable)
        XCTAssertFalse(notch.expanded)
        XCTAssertTrue(notch.setHovered(true))
        XCTAssertTrue(notch.expanded)
    }

    func testHoverDoesNotResetCompletionDismissalTimer() {
        var notch = NotchVisibility()
        notch.activate()
        let hideToken = notch.complete()
        XCTAssertTrue(notch.setHovered(true))
        XCTAssertEqual(notch.generation, hideToken)
        XCTAssertTrue(notch.beginDismissal(ifGeneration: hideToken))
    }

    func testCompletionGraceAndStaleDismissal() {
        var notch = NotchVisibility()
        notch.activate()
        let first = notch.complete()
        XCTAssertEqual(notch.phase, .grace)
        XCTAssertTrue(notch.clickable)
        XCTAssertFalse(notch.expanded)
        XCTAssertFalse(notch.setHovered(false))
        XCTAssertTrue(notch.beginDismissal(ifGeneration: first))
        XCTAssertFalse(notch.clickable)
        XCTAssertFalse(notch.setHovered(true))
        XCTAssertFalse(notch.expanded)
        XCTAssertTrue(notch.finishDismissal(ifGeneration: first))
        XCTAssertFalse(notch.visible)
        XCTAssertFalse(notch.setHovered(true))
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
