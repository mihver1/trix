import SwiftUI

enum TrixPalette {
    static let canvasStart = Color(red: 0.95, green: 0.93, blue: 0.88)
    static let canvasEnd = Color(red: 0.99, green: 0.98, blue: 0.95)
    static let sidebar = Color(red: 0.13, green: 0.14, blue: 0.13)
    static let sidebarElevated = Color(red: 0.18, green: 0.19, blue: 0.17)
    static let ink = Color(red: 0.15, green: 0.12, blue: 0.10)
    static let inkMuted = Color(red: 0.39, green: 0.35, blue: 0.31)
    static let accent = Color(red: 0.32, green: 0.45, blue: 0.26)
    static let accentSoft = Color(red: 0.88, green: 0.92, blue: 0.84)
    static let rust = Color(red: 0.72, green: 0.43, blue: 0.25)
    static let panel = Color.white.opacity(0.70)
    static let panelStrong = Color(red: 0.99, green: 0.98, blue: 0.95)
    static let outline = Color.black.opacity(0.08)
    static let success = Color(red: 0.24, green: 0.55, blue: 0.29)
    static let warning = Color(red: 0.75, green: 0.46, blue: 0.21)
}

struct TrixCanvas: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TrixPalette.canvasStart, TrixPalette.canvasEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(TrixPalette.accent.opacity(0.16))
                .frame(width: 460, height: 460)
                .blur(radius: 110)
                .offset(x: 320, y: -240)

            RoundedRectangle(cornerRadius: 120, style: .continuous)
                .fill(TrixPalette.rust.opacity(0.10))
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
        .shadow(color: .black.opacity(tone == .inverted ? 0.22 : 0.08), radius: 28, y: 12)
    }

    private var background: some ShapeStyle {
        switch tone {
        case .surface:
            return AnyShapeStyle(TrixPalette.panel)
        case .strong:
            return AnyShapeStyle(TrixPalette.panelStrong)
        case .inverted:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [TrixPalette.sidebarElevated, TrixPalette.sidebar],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var borderColor: Color {
        switch tone {
        case .inverted:
            return Color.white.opacity(0.08)
        case .surface, .strong:
            return TrixPalette.outline
        }
    }

    private var titleColor: Color {
        tone == .inverted ? .white : TrixPalette.ink
    }

    private var subtitleColor: Color {
        tone == .inverted ? .white.opacity(0.72) : TrixPalette.inkMuted
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
                .foregroundStyle(TrixPalette.inkMuted)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(TrixPalette.ink)
            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(TrixPalette.inkMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(TrixPalette.outline, lineWidth: 1)
        }
    }
}

struct TrixInputBlock<Content: View>: View {
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
                .foregroundStyle(TrixPalette.ink)
            content
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(TrixPalette.inkMuted)
            }
        }
    }
}

struct TrixInputChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(TrixPalette.outline, lineWidth: 1)
            }
            .foregroundStyle(TrixPalette.ink)
    }
}

enum TrixActionTone {
    case primary
    case secondary
    case ghost
    case sidebar
}

struct TrixActionButtonStyle: ButtonStyle {
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
            return AnyShapeStyle(TrixPalette.accent.opacity(opacity))
        case .secondary:
            return AnyShapeStyle(TrixPalette.panelStrong.opacity(opacity))
        case .ghost:
            return AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.42 : 0.22))
        case .sidebar:
            return AnyShapeStyle(TrixPalette.sidebarElevated.opacity(opacity))
        }
    }

    private var foregroundColor: Color {
        switch tone {
        case .primary:
            return .white
        case .secondary:
            return TrixPalette.ink
        case .ghost:
            return TrixPalette.ink
        case .sidebar:
            return .white
        }
    }

    private var borderColor: Color {
        switch tone {
        case .primary:
            return TrixPalette.accent.opacity(0.25)
        case .secondary, .ghost:
            return TrixPalette.outline
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
