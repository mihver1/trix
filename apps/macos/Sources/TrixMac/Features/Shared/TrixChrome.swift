import AppKit
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

    static func resolve() -> TrixColors {
        let windowBackground = Color(nsColor: .windowBackgroundColor)
        let underPageBackground = Color(nsColor: .underPageBackgroundColor)
        let controlBackground = Color(nsColor: .controlBackgroundColor)
        let textBackground = Color(nsColor: .textBackgroundColor)
        let separator = Color(nsColor: .separatorColor)

        return TrixColors(
            canvasStart: windowBackground,
            canvasEnd: underPageBackground,
            sidebar: controlBackground,
            sidebarElevated: underPageBackground,
            ink: .primary,
            inkMuted: .secondary,
            inverseInk: .primary,
            inverseInkMuted: .secondary,
            accent: .accentColor,
            accentSoft: .accentColor,
            rust: .orange,
            panel: controlBackground,
            panelStrong: windowBackground,
            outline: separator,
            success: .green,
            warning: .orange,
            inputFill: textBackground,
            tileFill: controlBackground
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
        colors.canvasStart
            .ignoresSafeArea()
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
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
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
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        ScrollView {
            Text(payload)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
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
