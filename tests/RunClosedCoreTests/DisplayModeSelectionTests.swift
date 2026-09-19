import XCTest
@testable import RunClosedCore

/// Pure-logic tests for the resolution dropdown (G2d). No device dependency —
/// the MacSystem layer feeds these from CoreGraphics; here we feed literals.
final class DisplayModeSelectionTests: XCTestCase {

    func testNormalizeDedupesByGeometryKeepingHighestRefresh() {
        let modes = [
            DisplayModeSelection.Mode(width: 1920, height: 1080, refresh: 60),
            DisplayModeSelection.Mode(width: 1920, height: 1080, refresh: 120),
            DisplayModeSelection.Mode(width: 1920, height: 1080, refresh: 30),
        ]
        let out = DisplayModeSelection.normalize(modes)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].refresh, 120)
    }

    func testNormalizeSortsLargestFirst() {
        let modes = [
            DisplayModeSelection.Mode(width: 1280, height: 720, refresh: 60),
            DisplayModeSelection.Mode(width: 3456, height: 2234, refresh: 120),
            DisplayModeSelection.Mode(width: 1920, height: 1080, refresh: 60),
        ]
        let out = DisplayModeSelection.normalize(modes)
        XCTAssertEqual(out.map { "\($0.width)x\($0.height)" },
                       ["3456x2234", "1920x1080", "1280x720"])
    }

    func testNormalizeDropsZeroSizedModes() {
        let modes = [
            DisplayModeSelection.Mode(width: 0, height: 0, refresh: 60),
            DisplayModeSelection.Mode(width: 1728, height: 1117, refresh: 0),
        ]
        let out = DisplayModeSelection.normalize(modes)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].width, 1728)
    }

    func testLabelOmitsZeroRefresh() {
        let native = DisplayModeSelection.Mode(width: 3456, height: 2234, refresh: 120)
        let virtual = DisplayModeSelection.Mode(width: 3456, height: 2234, refresh: 0)
        XCTAssertEqual(native.label, "3456x2234  @120Hz")
        XCTAssertEqual(virtual.label, "3456x2234")
    }

    func testBestPicksHighestRefreshForGeometry() {
        let modes = DisplayModeSelection.normalize([
            DisplayModeSelection.Mode(width: 1920, height: 1080, refresh: 60),
            DisplayModeSelection.Mode(width: 1920, height: 1080, refresh: 144),
        ])
        let best = DisplayModeSelection.best(in: modes, width: 1920, height: 1080)
        XCTAssertEqual(best?.refresh, 144)
    }

    func testBestReturnsNilWhenGeometryAbsent() {
        let modes = DisplayModeSelection.normalize([
            DisplayModeSelection.Mode(width: 1920, height: 1080, refresh: 60),
        ])
        XCTAssertNil(DisplayModeSelection.best(in: modes, width: 800, height: 600))
    }

    func testIndexFindsCurrentModeGeometry() {
        let modes = DisplayModeSelection.normalize([
            DisplayModeSelection.Mode(width: 3456, height: 2234, refresh: 120),
            DisplayModeSelection.Mode(width: 1728, height: 1117, refresh: 60),
        ])
        XCTAssertEqual(DisplayModeSelection.index(in: modes, width: 1728, height: 1117), 1)
        XCTAssertNil(DisplayModeSelection.index(in: modes, width: 640, height: 480))
    }

    func testNormalizeIsDeterministic() {
        let modes = [
            DisplayModeSelection.Mode(width: 1920, height: 1080, refresh: 60),
            DisplayModeSelection.Mode(width: 2560, height: 1440, refresh: 60),
            DisplayModeSelection.Mode(width: 1920, height: 1080, refresh: 120),
        ]
        XCTAssertEqual(DisplayModeSelection.normalize(modes),
                       DisplayModeSelection.normalize(modes.reversed()))
    }
}
