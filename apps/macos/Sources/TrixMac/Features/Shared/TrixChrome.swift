import AppKit
import SwiftUI

struct TrixColors {
    let canvasStart: Color
    let canvasEnd: Color
    let canvasGlow: Color
    let sidebar: Color
    let sidebarElevated: Color
    let ink: Color
    let inkMuted: Color
    let inverseInk: Color
    let inverseInkMuted: Color
    let accent: Color
    let accentSoft: Color
    let rust: Color
    let panel: Color
    let panelStrong: Color
    let outline: Color
    let success: Color
    let warning: Color
    let inputFill: Color
    let tileFill: Color
    let panelShadow: Color

    static func resolve() -> TrixColors {
        let windowBackground = Color(nsColor: .windowBackgroundColor)
        let underPageBackground = Color(nsColor: .underPageBackgroundColor)
        let controlBackground = Color(nsColor: .controlBackgroundColor)
        let textBackground = Color(nsColor: .textBackgroundColor)
        let separator = Color(nsColor: .separatorColor)
        let accent = Color(nsColor: .controlAccentColor)

        return TrixColors(
            canvasStart: windowBackground,
            canvasEnd: underPageBackground,
            canvasGlow: accent.opacity(0.10),
            sidebar: controlBackground,
            sidebarElevated: underPageBackground,
            ink: .primary,
            inkMuted: .secondary,
            inverseInk: .primary,
            inverseInkMuted: .secondary,
            accent: accent,
            accentSoft: accent,
            rust: .orange,
            panel: underPageBackground,
            panelStrong: windowBackground,
            outline: separator,
            success: .green,
            warning: .orange,
            inputFill: textBackground,
            tileFill: controlBackground,
            panelShadow: .black.opacity(0.08)
        )
    }
}

private struct TrixColorsKey: EnvironmentKey {
    static let defaultValue = TrixColors.resolve()
}

extension EnvironmentValues {
    var trixColors: TrixColors {
        get { self[TrixColorsKey.self] }
        set { self[TrixColorsKey.self] = newValue }
    }
}

struct TrixCanvas: View {
    @Environment(\.trixColors) private var colors

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [colors.canvasStart, colors.canvasEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(colors.canvasGlow)
                .frame(width: 420, height: 420)
                .blur(radius: 120)
                .offset(x: 260, y: -180)

            Circle()
                .fill(colors.canvasGlow.opacity(0.7))
                .frame(width: 340, height: 340)
                .blur(radius: 140)
                .offset(x: -200, y: 260)
        }
        .drawingGroup(opaque: false)
        .compositingGroup()
            .ignoresSafeArea()
    }
}

struct TrixSurface<Content: View>: View {
    @Environment(\.trixColors) private var colors

    var emphasized: Bool = false
    var cornerRadius: CGFloat = 22
    @ViewBuilder let content: Content

    init(
        emphasized: Bool = false,
        cornerRadius: CGFloat = 22,
        @ViewBuilder content: () -> Content
    ) {
        self.emphasized = emphasized
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .background {
                surfaceShape
                    .fill(surfaceGradient)
                    .overlay {
                        surfaceShape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        colors.accent.opacity(emphasized ? 0.14 : 0.06),
                                        .clear,
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
            }
            .overlay {
                surfaceShape
                    .stroke(colors.outline.opacity(emphasized ? 0.78 : 0.58), lineWidth: 1)
            }
            .shadow(
                color: colors.panelShadow.opacity(emphasized ? 1 : 0.72),
                radius: emphasized ? 18 : 10,
                x: 0,
                y: emphasized ? 10 : 4
            )
    }

    private var surfaceShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var surfaceGradient: LinearGradient {
        LinearGradient(
            colors: emphasized
                ? [colors.panelStrong, colors.panel]
                : [colors.panel, colors.panelStrong.opacity(0.92)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct TrixPanel<Content: View>: View {
    @Environment(\.trixColors) private var colors

    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        TrixSurface {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(titleColor)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(subtitleColor)
                    }
                }

                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleColor: Color {
        colors.ink
    }

    private var subtitleColor: Color {
        colors.inkMuted
    }
}

struct TrixToneBadge: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tint.opacity(0.20), lineWidth: 1)
            }
    }
}

struct TrixMetricTile: View {
    @Environment(\.trixColors) private var colors

    let label: String
    let value: String
    let footnote: String?

    init(label: String, value: String, footnote: String? = nil) {
        self.label = label
        self.value = value
        self.footnote = footnote
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(colors.inkMuted)
            Text(value)
                .font(.headline)
                .foregroundStyle(colors.ink)
            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(colors.inkMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(colors.outline.opacity(0.62), lineWidth: 1)
        }
    }
}

struct TrixInputBlock<Content: View>: View {
    @Environment(\.trixColors) private var colors

    let label: String
    let hint: String?
    @ViewBuilder let content: Content

    init(
        _ label: String,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.headline)
                .foregroundStyle(colors.ink)
            content
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(colors.inkMuted)
            }
        }
    }
}

struct TrixInputChrome: ViewModifier {
    @Environment(\.trixColors) private var colors

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(colors.inputFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(colors.outline, lineWidth: 1)
            }
            .foregroundStyle(colors.ink)
    }
}

struct TrixPayloadBox: View {
    @Environment(\.trixColors) private var colors

    let payload: String
    var minHeight: CGFloat = 132
    var valueAccessibilityIdentifier: String?

    var body: some View {
        ScrollView {
            Group {
                if let valueAccessibilityIdentifier {
                    Text(payload)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(16)
                        .accessibilityIdentifier(valueAccessibilityIdentifier)
                } else {
                    Text(payload)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(16)
                }
            }
        }
        .frame(minHeight: minHeight, maxHeight: max(minHeight, 196))
        .background(colors.inputFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
        }
    }
}

enum TrixActionTone {
    case primary
    case secondary
    case ghost
    case sidebar
}

struct TrixActionButtonStyle: ButtonStyle {
    @Environment(\.trixColors) private var colors

    let tone: TrixActionTone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background(configuration: configuration), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .foregroundStyle(foregroundColor)
    }

    private func background(configuration: Configuration) -> some ShapeStyle {
        let opacity = configuration.isPressed ? 0.78 : 1

        switch tone {
        case .primary:
            return AnyShapeStyle(colors.accent.opacity(opacity))
        case .secondary:
            return AnyShapeStyle(colors.tileFill.opacity(opacity))
        case .ghost:
            return AnyShapeStyle(Color.clear)
        case .sidebar:
            return AnyShapeStyle(colors.tileFill.opacity(opacity))
        }
    }

    private var foregroundColor: Color {
        switch tone {
        case .primary:
            return .white
        case .secondary, .ghost:
            return colors.ink
        case .sidebar:
            return colors.ink
        }
    }

    private var borderColor: Color {
        switch tone {
        case .primary:
            return colors.accent.opacity(0.30)
        case .secondary, .ghost:
            return colors.outline
        case .sidebar:
            return colors.outline
        }
    }
}

extension View {
    func trixInputChrome() -> some View {
        modifier(TrixInputChrome())
    }
}

func copyStringToPasteboard(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
}
