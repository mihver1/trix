import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum TrixDesign {
    static let accent = Color(red: 0.14, green: 0.55, blue: 0.98)
    static let groupAccent = Color(red: 0.10, green: 0.66, blue: 0.54)
    static let unlockedAccent = Color.yellow

    #if os(iOS)
    static let screenBackground = Color(uiColor: .systemGroupedBackground)
    static let primarySurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let secondarySurface = Color(uiColor: .tertiarySystemGroupedBackground)
    static let elevatedFieldSurface = Color(uiColor: .systemBackground)
    static let incomingBubbleSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let surfaceStroke = Color(uiColor: .separator).opacity(0.22)
    static let softShadow = Color.black.opacity(0.08)
    #elseif os(macOS)
    static let screenBackground = Color(nsColor: .windowBackgroundColor)
    static let primarySurface = Color(nsColor: .controlBackgroundColor)
    static let secondarySurface = Color(nsColor: .underPageBackgroundColor)
    static let elevatedFieldSurface = Color(nsColor: .textBackgroundColor)
    static let incomingBubbleSurface = Color(nsColor: .controlBackgroundColor)
    static let surfaceStroke = Color(nsColor: .separatorColor).opacity(0.35)
    static let softShadow = Color.black.opacity(0.14)
    #endif

    static let successSurface = Color.green.opacity(0.12)
    static let warningSurface = Color.orange.opacity(0.14)
    static let errorSurface = Color.red.opacity(0.10)
}

extension TrixRoomKind {
    var tint: Color {
        switch self {
        case .direct:
            return TrixDesign.accent
        case .group:
            return TrixDesign.groupAccent
        }
    }
}

struct TrixAvatarView: View {
    let title: String
    let systemImage: String
    let size: CGFloat
    var tint: Color = TrixDesign.accent

    var body: some View {
        ZStack {
            Circle()
                .fill(resolvedTint.opacity(0.15))

            if initials.isEmpty {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(resolvedTint)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(resolvedTint)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
    }

    private var resolvedTint: Color {
        guard !initials.isEmpty else {
            return tint
        }

        let palette: [Color] = [
            TrixDesign.accent,
            TrixDesign.groupAccent,
            Color(red: 0.72, green: 0.28, blue: 0.34),
            Color(red: 0.58, green: 0.36, blue: 0.78),
            Color(red: 0.17, green: 0.56, blue: 0.48),
            Color(red: 0.76, green: 0.42, blue: 0.18),
        ]
        let hash = title.unicodeScalars.reduce(UInt64(0)) { partialResult, scalar in
            partialResult &* 31 &+ UInt64(scalar.value)
        }
        let index = Int(hash % UInt64(palette.count))
        return palette[index]
    }

    private var initials: String {
        let parts = title
            .replacingOccurrences(of: "@", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(2)
        return parts
            .compactMap(\.first)
            .map { String($0).uppercased() }
            .joined()
    }
}

struct TrixStatusPill: View {
    let title: String
    let systemImage: String
    var tint: Color = TrixDesign.accent

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tint.opacity(0.20), lineWidth: 1)
            }
    }
}

struct TrixRoomKindMark: View {
    let kind: TrixRoomKind
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(kind.tint)
            .frame(width: size, height: size)
            .background(kind.tint.opacity(0.13), in: Circle())
            .accessibilityLabel(kind.label)
    }
}

struct TrixRoomSecurityMark: View {
    let isEncrypted: Bool
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: isEncrypted ? "lock.fill" : "lock.open.fill")
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(isEncrypted ? .green : TrixDesign.unlockedAccent)
            .frame(width: size, height: size)
            .background(
                (isEncrypted ? Color.green : TrixDesign.unlockedAccent)
                    .opacity(isEncrypted ? 0.13 : 0.18),
                in: Circle()
            )
            .accessibilityLabel(isEncrypted ? "E2EE on" : "E2EE off")
    }
}

struct TrixBannerView: View {
    let text: String
    let systemImage: String
    var tint: Color

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.footnote)
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct TrixEmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(TrixDesign.accent)

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    @ViewBuilder
    func trixScrollContentBackgroundHidden() -> some View {
        #if os(iOS)
        self.scrollContentBackground(.hidden)
        #elseif os(macOS)
        self.scrollContentBackground(.hidden)
        #else
        self
        #endif
    }

    @ViewBuilder
    func trixInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func trixScrollDismissesKeyboard() -> some View {
        #if os(iOS)
        self.scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }

    func trixDialogSurface(minWidth: CGFloat? = nil, minHeight: CGFloat? = nil) -> some View {
        #if os(iOS)
        self
            .tint(TrixDesign.accent)
            .background(TrixDesign.screenBackground.ignoresSafeArea())
        #else
        self
            .tint(TrixDesign.accent)
            .frame(minWidth: minWidth, minHeight: minHeight)
            .background(TrixDesign.screenBackground.ignoresSafeArea())
        #endif
    }
}
