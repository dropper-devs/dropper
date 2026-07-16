import XCTest
@testable import CaptureKit

final class MarkupCropGeometryTests: XCTestCase {
    func testCropMarqueeCanBeDrawnInEitherDirectionAndClamped() {
        let reverse = AreaSelectionGeometry.rect(
            from: CGPoint(x: 300, y: 220),
            to: CGPoint(x: 80, y: 40))
        XCTAssertEqual(
            AreaSelectionGeometry.clamped(reverse, in: CGSize(width: 400, height: 300)),
            CGRect(x: 80, y: 40, width: 220, height: 180))

        let beyondBounds = AreaSelectionGeometry.rect(
            from: CGPoint(x: 300, y: 220),
            to: CGPoint(x: -40, y: 340))
        XCTAssertEqual(
            AreaSelectionGeometry.clamped(
                beyondBounds, in: CGSize(width: 400, height: 300)),
            CGRect(x: 0, y: 220, width: 300, height: 80))
    }

    func testCropMarqueeMovementPreservesSizeAndStopsAtImageBounds() {
        let crop = CGRect(x: 50, y: 40, width: 120, height: 80)
        let imageSize = CGSize(width: 400, height: 300)

        XCTAssertEqual(
            AreaSelectionGeometry.moved(
                crop, by: CGSize(width: 500, height: 500), in: imageSize),
            CGRect(x: 280, y: 220, width: 120, height: 80))
        XCTAssertEqual(
            AreaSelectionGeometry.moved(
                crop, by: CGSize(width: -500, height: -500), in: imageSize),
            CGRect(x: 0, y: 0, width: 120, height: 80))
    }
}
