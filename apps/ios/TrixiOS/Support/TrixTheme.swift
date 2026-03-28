import SwiftUI
import UIKit

enum TrixTheme {
    static let accent = Color(red: 0.14, green: 0.55, blue: 0.98)

    static let screenBackground = Color(uiColor: .systemBackground)
    static let primarySurface = dynamicColor(
        light: UIColor.white.withAlphaComponent(0.88),
        dark: UIColor.secondarySystemBackground.withAlphaComponent(0.96)
    )
    static let secondarySurface = dynamicColor(
        light: UIColor.white.withAlphaComponent(0.82),
        dark: UIColor.tertiarySystemBackground.withAlphaComponent(0.94)
    )
    static let tertiarySurface = dynamicColor(
        light: UIColor.white.withAlphaComponent(0.76),
        dark: UIColor.tertiarySystemBackground.withAlphaComponent(0.88)
    )
    static let elevatedFieldSurface = dynamicColor(
        light: UIColor.white.withAlphaComponent(0.92),
        dark: UIColor.secondarySystemBackground.withAlphaComponent(0.92)
    )
    static let incomingBubbleSurface = dynamicColor(
        light: UIColor.white.withAlphaComponent(0.94),
        dark: UIColor.secondarySystemBackground.withAlphaComponent(0.96)
    )
    static let chipSurface = dynamicColor(
        light: UIColor.white.withAlphaComponent(0.80),
        dark: UIColor.tertiarySystemBackground.withAlphaComponent(0.94)
    )
    static let systemEventSurface = dynamicColor(
        light: UIColor.white.withAlphaComponent(0.70),
        dark: UIColor.secondarySystemBackground.withAlphaComponent(0.90)
    )
    static let surfaceStroke = dynamicColor(
        light: UIColor.black.withAlphaComponent(0.05),
        dark: UIColor.white.withAlphaComponent(0.08)
    )
    static let softShadow = dynamicColor(
        light: UIColor.black.withAlphaComponent(0.08),
        dark: UIColor.black.withAlphaComponent(0.28)
    )

    static let screenGradientTop = dynamicColor(
        light: UIColor(red: 0.95, green: 0.98, blue: 1.0, alpha: 1),
        dark: UIColor(red: 0.08, green: 0.11, blue: 0.16, alpha: 1)
    )
    static let screenGradientMiddle = dynamicColor(
        light: UIColor(red: 0.89, green: 0.95, blue: 1.0, alpha: 1),
        dark: UIColor(red: 0.10, green: 0.15, blue: 0.22, alpha: 1)
    )
    static let screenGradientBottom = dynamicColor(
        light: UIColor(red: 0.98, green: 0.99, blue: 1.0, alpha: 1),
        dark: UIColor(red: 0.06, green: 0.09, blue: 0.14, alpha: 1)
    )

    static let chatBackdropTop = dynamicColor(
        light: UIColor(red: 0.95, green: 0.98, blue: 1.0, alpha: 1),
        dark: UIColor(red: 0.08, green: 0.11, blue: 0.16, alpha: 1)
    )
    static let chatBackdropBottom = dynamicColor(
        light: UIColor(red: 0.90, green: 0.95, blue: 1.0, alpha: 1),
        dark: UIColor(red: 0.07, green: 0.13, blue: 0.20, alpha: 1)
    )
    static let chatBackdropGlow = dynamicColor(
        light: UIColor.white.withAlphaComponent(0.70),
        dark: UIColor.white.withAlphaComponent(0.06)
    )
    static let chatAccentGlow = dynamicColor(
        light: UIColor(red: 0.14, green: 0.55, blue: 0.98, alpha: 0.11),
        dark: UIColor(red: 0.14, green: 0.55, blue: 0.98, alpha: 0.22)
    )

    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        })
    }
}
