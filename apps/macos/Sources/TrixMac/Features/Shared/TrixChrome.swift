import SwiftUI

struct TrixColors {
    let canvasStart: Color
    let canvasEnd: Color
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

    static func resolve(for scheme: ColorScheme) -> TrixColors {
        switch scheme {
        case .dark:
            return TrixColors(
                canvasStart: Color(red: 0.07, green: 0.08, blue: 0.09),
                canvasEnd: Color(red: 0.10, green: 0.11, blue: 0.13),
                sidebar: Color(red: 0.05, green: 0.06, blue: 0.07),
                sidebarElevated: Color(red: 0.09, green: 0.10, blue: 0.11),
                ink: Color(red: 0.93, green: 0.92, blue: 0.89),
                inkMuted: Color(red: 0.66, green: 0.68, blue: 0.70),
                inverseInk: Color.white,
                inverseInkMuted: Color.white.opacity(0.72),
                accent: Color(red: 0.52, green: 0.70, blue: 0.45),
                accentSoft: Color(red: 0.23, green: 0.31, blue: 0.21),
                rust: Color(red: 0.82, green: 0.56, blue: 0.33),
                panel: Color.white.opacity(0.06),
                panelStrong: Color(red: 0.12, green: 0.13, blue: 0.15),
                outline: Color.white.opacity(0.09),
                success: Color(red: 0.55, green: 0.79, blue: 0.53),
                warning: Color(red: 0.91, green: 0.66, blue: 0.37),
                inputFill: Color.white.opacity(0.07),
                tileFill: Color.white.opacity(0.05)
            )
        case .light:
            return TrixColors(
                canvasStart: Color(red: 0.95, green: 0.93, blue: 0.88),
                canvasEnd: Color(red: 0.99, green: 0.98, blue: 0.95),
                sidebar: Color(red: 0.13, green: 0.14, blue: 0.13),
                sidebarElevated: Color(red: 0.18, green: 0.19, blue: 0.17),
                ink: Color(red: 0.15, green: 0.12, blue: 0.10),
                inkMuted: Color(red: 0.39, green: 0.35, blue: 0.31),
                inverseInk: Color.white,
                inverseInkMuted: Color.white.opacity(0.72),
                accent: Color(red: 0.32, green: 0.45, blue: 0.26),
                accentSoft: Color(red: 0.88, green: 0.92, blue: 0.84),
                rust: Color(red: 0.72, green: 0.43, blue: 0.25),
                panel: Color.white.opacity(0.70),
                panelStrong: Color(red: 0.99, green: 0.98, blue: 0.95),
                outline: Color.black.opacity(0.08),
                success: Color(red: 0.24, green: 0.55, blue: 0.29),
                warning: Color(red: 0.75, green: 0.46, blue: 0.21),
                inputFill: Color.white.opacity(0.76),
                tileFill: Color.white.opacity(0.52)
            )
        @unknown default:
            return resolve(for: .light)
        }
    }
}

private struct TrixColorsKey: EnvironmentKey {
    static let defaultValue = TrixColors.resolve(for: .light)
}

extension EnvironmentValues {
    var trixColors: TrixColors {
        get { self[TrixColorsKey.self] }
        set { self[TrixColorsKey.self] = newValue }
    }
}

struct TrixCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.trixColors) private var colors

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [colors.canvasStart, colors.canvasEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(colors.accent.opacity(colorScheme == .dark ? 0.20 : 0.16))
                .frame(width: 460, height: 460)
                .blur(radius: 110)
                .offset(x: 320, y: -240)

            RoundedRectangle(cornerRadius: 120, style: .continuous)
                .fill(colors.rust.opacity(colorScheme == .dark ? 0.14 : 0.10))
                .frame(width: 420, height: 280)
                .rotationEffect(.degrees(-18))
                .blur(radius: 70)
                .offset(x: -340, y: 280)
        }
    }
}

enum TrixPanelTone {
    case surface
    case strong
    case inverted
}

struct TrixPanel<Content: View>: View {
    @Environment(\.trixColors) private var colors

    let title: String
    let subtitle: String?
    let tone: TrixPanelTone
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        tone: TrixPanelTone = .surface,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 25, weight: .bold, design: .serif))
                    .foregroundStyle(titleColor)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(subtitleColor)
                }
            }

            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .shadow(color: shadowColor, radius: 28, y: 12)
    }

    private var background: some ShapeStyle {
        switch tone {
        case .surface:
            return AnyShapeStyle(colors.panel)
        case .strong:
            return AnyShapeStyle(colors.panelStrong)
        case .inverted:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [colors.sidebarElevated, colors.sidebar],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var borderColor: Color {
        tone == .inverted ? Color.white.opacity(0.08) : colors.outline
    }

    private var titleColor: Color {
        tone == .inverted ? colors.inverseInk : colors.ink
    }

    private var subtitleColor: Color {
        tone == .inverted ? colors.inverseInkMuted : colors.inkMuted
    }

    private var shadowColor: Color {
        tone == .inverted ? .black.opacity(0.24) : .black.opacity(0.10)
    }
}

struct TrixToneBadge: View {
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
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
            Text(label.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(colors.inkMuted)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(colors.ink)
            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(colors.inkMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.tileFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(colors.outline, lineWidth: 1)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(colors.inputFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(colors.outline, lineWidth: 1)
            }
            .foregroundStyle(colors.ink)
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
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(background(configuration: configuration), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(borderColor, lineWidth: 1)
            }
            .foregroundStyle(foregroundColor)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }

    private func background(configuration: Configuration) -> some ShapeStyle {
        let opacity = configuration.isPressed ? 0.88 : 1

        switch tone {
        case .primary:
            return AnyShapeStyle(colors.accent.opacity(opacity))
        case .secondary:
            return AnyShapeStyle(colors.panelStrong.opacity(opacity))
        case .ghost:
            return AnyShapeStyle(colors.tileFill.opacity(configuration.isPressed ? 0.88 : 0.72))
        case .sidebar:
            return AnyShapeStyle(colors.sidebarElevated.opacity(opacity))
        }
    }

    private var foregroundColor: Color {
        switch tone {
        case .primary:
            return .white
        case .secondary, .ghost:
            return colors.ink
        case .sidebar:
            return colors.inverseInk
        }
    }

    private var borderColor: Color {
        switch tone {
        case .primary:
            return colors.accent.opacity(0.25)
        case .secondary, .ghost:
            return colors.outline
        case .sidebar:
            return Color.white.opacity(0.08)
        }
    }
}

extension View {
    func trixInputChrome() -> some View {
        modifier(TrixInputChrome())
    }
}
