import Foundation
import XCTest
@testable import HighliteMenuBar

final class DashboardThemeTests: XCTestCase {
    func testPaletteMirrorsRelayHighlighterTokens() {
        XCTAssertEqual(DashboardPalette.canvas.light, 0xFFFDF5)
        XCTAssertEqual(DashboardPalette.surface.light, 0xFFFFFF)
        XCTAssertEqual(DashboardPalette.surfaceMuted.light, 0xFFFBF0)
        XCTAssertEqual(DashboardPalette.ink.light, 0x30232D)
        XCTAssertEqual(DashboardPalette.muted.light, 0x75636C)
        XCTAssertEqual(DashboardPalette.line.light, 0xEADFDA)
        XCTAssertEqual(DashboardPalette.lineStrong.light, 0xC9B7BD)
        XCTAssertEqual(DashboardPalette.primary.light, 0xA92261)
        XCTAssertEqual(DashboardPalette.primarySoft.light, 0xFFF0F6)
        XCTAssertEqual(DashboardPalette.highlightYellow.light, 0xEFFF3D)
        XCTAssertEqual(DashboardPalette.highlightOrange.light, 0xFFAD60)
        XCTAssertEqual(DashboardPalette.highlightPink.light, 0xFF81BD)
        XCTAssertEqual(DashboardPalette.action.light, 0xEFFF3D)
        XCTAssertEqual(DashboardPalette.actionInk.light, 0x30232D)
        XCTAssertEqual(DashboardPalette.success.light, 0x087443)
        XCTAssertEqual(DashboardPalette.danger.light, 0xB4232D)
        XCTAssertEqual(DashboardPalette.warning.light, 0x9A5700)
    }

    func testDarkAppearanceKeepsBrandedAndSemanticColorsDistinct() {
        XCTAssertNotEqual(DashboardPalette.canvas.light, DashboardPalette.canvas.dark)
        XCTAssertNotEqual(DashboardPalette.surface.light, DashboardPalette.surface.dark)
        XCTAssertNotEqual(DashboardPalette.ink.light, DashboardPalette.ink.dark)
        XCTAssertNotEqual(DashboardPalette.primary.light, DashboardPalette.primary.dark)
        XCTAssertNotEqual(DashboardPalette.success.light, DashboardPalette.success.dark)
        XCTAssertNotEqual(DashboardPalette.danger.light, DashboardPalette.danger.dark)
        XCTAssertEqual(DashboardPalette.action.light, DashboardPalette.action.dark)
        XCTAssertEqual(DashboardPalette.actionInk.light, DashboardPalette.actionInk.dark)
    }

    func testVividMarkerColorsUseDarkInkAndStatusColorsStayReadable() {
        XCTAssertGreaterThan(contrast(0x30232D, 0xEFFF3D), 12)
        XCTAssertGreaterThan(contrast(0x30232D, 0xFFAD60), 7)
        XCTAssertGreaterThan(contrast(0x30232D, 0xFF81BD), 6)
        XCTAssertGreaterThan(contrast(0x30232D, 0xFFFDF5), 12)
        XCTAssertGreaterThan(contrast(0xFFFFFF, 0xB4232D), 6)
    }

    func testTitleMarkerStaysTransparentAndReadableInBothAppearances() {
        XCTAssertGreaterThan(DashboardStyle.titleMarkerOpacity, 0)
        XCTAssertLessThan(DashboardStyle.titleMarkerOpacity, 0.6)

        let markerLight = blend(
            DashboardPalette.highlightYellow.light,
            over: DashboardPalette.canvas.light,
            alpha: DashboardStyle.titleMarkerOpacity
        )
        let markerDark = blend(
            DashboardPalette.highlightYellow.dark,
            over: DashboardPalette.canvas.dark,
            alpha: DashboardStyle.titleMarkerOpacity
        )

        XCTAssertGreaterThan(contrast(DashboardPalette.ink.light, markerLight), 4.5)
        XCTAssertGreaterThan(contrast(DashboardPalette.ink.dark, markerDark), 4.5)
    }

    func testDarkSurfacesKeepTextAndPrimaryReadable() {
        XCTAssertGreaterThan(contrast(0xF7EFE8, 0x1B1519), 12)
        XCTAssertGreaterThan(contrast(0xF7EFE8, 0x241D22), 12)
        XCTAssertGreaterThan(contrast(0xFF81BD, 0x241D22), 6)
        XCTAssertGreaterThan(contrast(0xC4B2BC, 0x241D22), 6)
        XCTAssertGreaterThan(contrast(0x5BD39A, 0x241D22), 6)
        XCTAssertGreaterThan(contrast(0xFFC46B, 0x241D22), 6)
        XCTAssertGreaterThan(contrast(0xFF7B81, 0x241D22), 5)
    }

    private func contrast(_ foreground: UInt32, _ background: UInt32) -> Double {
        let bright = max(luminance(foreground), luminance(background))
        let dark = min(luminance(foreground), luminance(background))
        return (bright + 0.05) / (dark + 0.05)
    }

    /// Composites translucent marker paint onto an opaque canvas, matching how
    /// SwiftUI draws the title backplate over `DashboardTheme.canvas`.
    private func blend(_ foreground: UInt32, over background: UInt32, alpha: Double) -> UInt32 {
        let channels = [UInt32(16), UInt32(8), UInt32(0)].map { shift -> UInt32 in
            let front = Double((foreground >> shift) & 0xFF)
            let back = Double((background >> shift) & 0xFF)
            return UInt32((front * alpha + back * (1 - alpha)).rounded())
        }
        return (channels[0] << 16) | (channels[1] << 8) | channels[2]
    }

    private func luminance(_ hex: UInt32) -> Double {
        let channels = [UInt32(16), UInt32(8), UInt32(0)].map { shift in
            Double((hex >> shift) & 0xFF) / 255
        }
        let adjusted = channels.map { channel in
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * adjusted[0] + 0.7152 * adjusted[1] + 0.0722 * adjusted[2]
    }
}
