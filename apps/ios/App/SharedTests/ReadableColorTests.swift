import XCTest
@testable import SukavinaShared

final class ReadableColorTests: XCTestCase {
    private let brandRed = SRGB(red: 0.91, green: 0.12, blue: 0.16)
    private let systemGreen = SRGB(red: 0.204, green: 0.78, blue: 0.349)
    private let systemOrange = SRGB(red: 1, green: 0.584, blue: 0)
    private let lightInk = SRGB(red: 0.906, green: 0.914, blue: 0.929)
    private let darkCard = SRGB(red: 0.12, green: 0.12, blue: 0.15)
    private let darkInk = SRGB(red: 0.07, green: 0.07, blue: 0.09)

    func testStatusHuesReachAAOnLightAndDarkBackgrounds() {
        for background in [SRGB.white, lightInk, darkCard, darkInk] {
            for hue in [brandRed, systemGreen, systemOrange] {
                let text = hue.readable(on: background)
                XCTAssertGreaterThanOrEqual(SRGB.contrast(text, background), 4.5, "\(hue) on \(background)")
            }
        }
    }

    func testAlreadyReadableColourIsUnchanged() {
        let dark = SRGB(red: 0.12, green: 0.15, blue: 0.2)
        XCTAssertEqual(dark.readable(on: .white), dark)
    }

    func testDarkensOnLightAndLightensOnDark() {
        XCTAssertLessThan(systemGreen.readable(on: .white).relativeLuminance, systemGreen.relativeLuminance)
        XCTAssertGreaterThan(brandRed.readable(on: darkCard).relativeLuminance, brandRed.relativeLuminance)
    }

    func testTintedPillIsTheBackgroundForChipText() {
        let pill = systemGreen.composited(over: .white, alpha: 0.14)
        XCTAssertGreaterThanOrEqual(SRGB.contrast(systemGreen.readable(on: pill), pill), 4.5)
    }
}
