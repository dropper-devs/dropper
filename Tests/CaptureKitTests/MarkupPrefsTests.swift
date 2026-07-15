import XCTest
@testable import CaptureKit

final class MarkupPrefsTests: XCTestCase {
    func testMarkupDefaultsRememberLastState() {
        let defaults = UserDefaults.standard
        let keys = [
            "DropperMarkupToolIndex",
            "DropperMarkupEditsFill",
            "DropperMarkupStrokeColorIndex",
            "DropperMarkupFillColorIndex",
            "DropperMarkupStrokePoints",
            "DropperMarkupFontPoints",
            "DropperMarkupOutputScaleIndex",
        ]
        let previousValues = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        defer {
            for key in keys { defaults.removeObject(forKey: key) }
            for (key, value) in previousValues { defaults.set(value, forKey: key) }
        }
        for key in keys { defaults.removeObject(forKey: key) }

        XCTAssertEqual(MarkupPrefs.toolIndex, 0)
        XCTAssertFalse(MarkupPrefs.editsFill)
        XCTAssertEqual(MarkupPrefs.strokeColorIndex, 0)
        XCTAssertNil(MarkupPrefs.fillColorIndex)
        XCTAssertEqual(MarkupPrefs.strokePoints, 3)
        XCTAssertEqual(MarkupPrefs.fontPoints, 24)
        XCTAssertEqual(MarkupPrefs.outputScaleIndex, 0)

        MarkupPrefs.toolIndex = 7
        MarkupPrefs.editsFill = true
        MarkupPrefs.strokeColorIndex = 4
        MarkupPrefs.fillColorIndex = 6
        MarkupPrefs.strokePoints = 8.5
        MarkupPrefs.fontPoints = 42.5
        MarkupPrefs.outputScaleIndex = 2

        XCTAssertEqual(MarkupPrefs.toolIndex, 7)
        XCTAssertTrue(MarkupPrefs.editsFill)
        XCTAssertEqual(MarkupPrefs.strokeColorIndex, 4)
        XCTAssertEqual(MarkupPrefs.fillColorIndex, 6)
        XCTAssertEqual(MarkupPrefs.strokePoints, 8.5)
        XCTAssertEqual(MarkupPrefs.fontPoints, 42.5)
        XCTAssertEqual(MarkupPrefs.outputScaleIndex, 2)

        MarkupPrefs.fillColorIndex = nil
        XCTAssertNil(MarkupPrefs.fillColorIndex)
    }
}
