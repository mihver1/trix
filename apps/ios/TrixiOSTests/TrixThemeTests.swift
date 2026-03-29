import XCTest
import SwiftUI
import UIKit
@testable import Trix

final class TrixThemeTests: XCTestCase {
    func testPrimarySurfaceResolvesDifferentlyForLightAndDarkMode() {
        let light = resolvedRGBA(for: TrixTheme.primarySurface, style: .light)
        let dark = resolvedRGBA(for: TrixTheme.primarySurface, style: .dark)

        XCTAssertFalse(light.isApproximatelyEqual(to: dark))
    }

    func testIncomingBubbleResolvesDifferentlyForLightAndDarkMode() {
        let light = resolvedRGBA(for: TrixTheme.incomingBubbleSurface, style: .light)
        let dark = resolvedRGBA(for: TrixTheme.incomingBubbleSurface, style: .dark)

        XCTAssertFalse(light.isApproximatelyEqual(to: dark))
    }

    func testAccentRemainsOpaqueAcrossAppearances() {
        let light = resolvedRGBA(for: TrixTheme.accent, style: .light)
        let dark = resolvedRGBA(for: TrixTheme.accent, style: .dark)

        XCTAssertEqual(light.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(dark.alpha, 1, accuracy: 0.001)
    }

    private func resolvedRGBA(
        for color: Color,
        style: UIUserInterfaceStyle
    ) -> RGBAComponents {
        let traitCollection = UITraitCollection(userInterfaceStyle: style)
        let resolvedColor = UIColor(color).resolvedColor(with: traitCollection)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(
            resolvedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
            "Expected an RGB-convertible color for \(color)."
        )
        return RGBAComponents(red: red, green: green, blue: blue, alpha: alpha)
    }
}

private struct RGBAComponents {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    func isApproximatelyEqual(to other: RGBAComponents, tolerance: CGFloat = 0.001) -> Bool {
        abs(red - other.red) <= tolerance &&
            abs(green - other.green) <= tolerance &&
            abs(blue - other.blue) <= tolerance &&
            abs(alpha - other.alpha) <= tolerance
    }
}
