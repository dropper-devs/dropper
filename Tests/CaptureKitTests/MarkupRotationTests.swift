import CoreText
import XCTest
@testable import CaptureKit

final class MarkupRotationTests: XCTestCase {
    private func textShape(start: CGPoint = CGPoint(x: 40, y: 40),
                           end: CGPoint = CGPoint(x: 140, y: 60),
                           rotation: CGFloat = 0) -> MarkupShape {
        MarkupShape(tool: .text, colorIndex: 0,
                    start: start, end: end,
                    text: "Rotate me", fontSize: 24,
                    rotationRadians: rotation)
    }

    func testRotatedTextCornersAndBoundsFollowAngle() {
        let shape = textShape(rotation: .pi / 2)
        let expected = [
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 80, y: 100),
            CGPoint(x: 80, y: 0),
        ]

        for (actual, wanted) in zip(shape.rotatedTextCorners, expected) {
            XCTAssertEqual(actual.x, wanted.x, accuracy: 0.001)
            XCTAssertEqual(actual.y, wanted.y, accuracy: 0.001)
        }
        XCTAssertEqual(shape.boundingRect.minX, 80, accuracy: 0.001)
        XCTAssertEqual(shape.boundingRect.maxX, 100, accuracy: 0.001)
        XCTAssertEqual(shape.boundingRect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(shape.boundingRect.maxY, 100, accuracy: 0.001)
    }

    func testTextHitTestingUsesOrientedBox() {
        let shape = textShape(rotation: .pi / 2)
        XCTAssertTrue(MarkupGeometry.strokeHit(shape,
                                                at: CGPoint(x: 90, y: 50),
                                                tolerance: 0))
        XCTAssertFalse(MarkupGeometry.strokeHit(shape,
                                                 at: CGPoint(x: 130, y: 50),
                                                 tolerance: 0))
    }

    func testRotationHandleFlipsInsideCanvasNearTopEdge() {
        let shape = textShape(start: CGPoint(x: 10, y: 0),
                              end: CGPoint(x: 110, y: 20))
        let handle = MarkupGeometry.rotationHandle(
            for: shape, offset: 24, within: CGSize(width: 200, height: 200))

        XCTAssertEqual(handle.anchor.y, 20, accuracy: 0.001)
        XCTAssertEqual(handle.position.y, 44, accuracy: 0.001)
    }

    func testZeroTranslationPullsRotatedTextBackInsideCanvas() {
        let shape = textShape(start: CGPoint(x: 0, y: 0),
                              end: CGPoint(x: 100, y: 20),
                              rotation: .pi / 4)
        let moved = MarkupGeometry.moved(shape, by: .zero,
                                         within: CGSize(width: 200, height: 200))

        XCTAssertGreaterThanOrEqual(moved.boundingRect.minX, -0.001)
        XCTAssertGreaterThanOrEqual(moved.boundingRect.minY, -0.001)
        XCTAssertLessThanOrEqual(moved.boundingRect.maxX, 200.001)
        XCTAssertLessThanOrEqual(moved.boundingRect.maxY, 200.001)
    }

    func testAnnotationFontResolvesAtRequestedSize() {
        let font = MarkupRender.annotationFont(size: 32)
        XCTAssertEqual(CTFontGetSize(font), 32, accuracy: 0.001)
        if let name = MarkupRender.resolvedTextFontName {
            XCTAssertEqual(CTFontCopyPostScriptName(font) as String, name)
        }
    }
}
