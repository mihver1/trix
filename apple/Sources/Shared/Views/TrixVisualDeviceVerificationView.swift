import SwiftUI

struct TrixVisualDeviceVerificationView: View {
    let device: TrixPeerDeviceIdentity
    let canApprove: Bool
    let isBusy: Bool
    let approve: () -> Void

    @State private var declined = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let visualVerification = device.visualVerification {
                TrixVisualDeviceChallengeView(visualVerification: visualVerification)

                technicalDetails(visualVerification)
            } else {
                Label {
                    Text("Visual check unavailable. Refresh before trusting.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.orange)

                rawFingerprintDisclosure
            }

            if canApprove {
                ViewThatFits(in: .horizontal) {
                    actionRow
                    VStack(alignment: .leading, spacing: 8) {
                        actionRow
                    }
                }
            } else if device.canSendEncrypted {
                Label("Trusted", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if declined {
                Label {
                    Text("Not trusted.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "xmark.shield")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                declined = false
                approve()
            } label: {
                Label("Match", systemImage: "checkmark.shield")
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || device.visualVerification == nil)

            Button(role: .destructive) {
                declined = true
            } label: {
                Label("No Match", systemImage: "xmark.shield")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
    }

    private func technicalDetails(_ visualVerification: TrixDeviceVisualVerification) -> some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Primitive", value: visualVerification.kind.label)

                Text(visualVerification.kind.explanation)
                    .fixedSize(horizontal: false, vertical: true)

                TrixFingerprintTechnicalText(
                    title: visualVerification.kind == .libsignalSafetyNumber ? "Safety number" : "Visual fingerprint",
                    value: visualVerification.wrappedSourceText,
                    unavailableLabel: "Unavailable"
                )

                rawFingerprintText
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private var rawFingerprintDisclosure: some View {
        DisclosureGroup("Technical fingerprint") {
            rawFingerprintText
                .padding(.top, 4)
        }
        .font(.caption)
    }

    private var rawFingerprintText: some View {
        TrixFingerprintTechnicalText(
            title: "Raw fingerprint",
            value: device.hasFingerprint ? device.groupedFingerprint : "",
            unavailableLabel: "Unavailable"
        )
    }
}

private struct TrixVisualDeviceChallengeView: View {
    let visualVerification: TrixDeviceVisualVerification

    var body: some View {
        switch visualVerification.kind {
        case .libsignalSafetyNumber:
            TrixVisualChallengeSymbolsView(symbols: visualVerification.symbols)

        case .fingerprintDisplayTransform:
            ViewThatFits(in: .horizontal) {
                horizontalLayout
                verticalLayout
            }
        }
    }

    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            TrixFingerprintPixelArtView(pixelArt: visualVerification.pixelArt)
            summary
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            TrixFingerprintPixelArtView(pixelArt: visualVerification.pixelArt)
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Device image", systemImage: "square.grid.3x3.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if !visualVerification.compactSourceText.isEmpty {
                Text(visualVerification.compactSourceText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TrixFingerprintPixelArtView: View {
    let pixelArt: TrixDeviceFingerprintPixelArt

    private let palette: [Color] = [
        Color(red: 0.04, green: 0.62, blue: 0.58),
        Color(red: 0.13, green: 0.45, blue: 0.95),
        Color(red: 0.44, green: 0.32, blue: 0.88),
        Color(red: 0.78, green: 0.22, blue: 0.68),
        Color(red: 0.88, green: 0.26, blue: 0.27),
        Color(red: 0.94, green: 0.58, blue: 0.16),
        Color(red: 0.28, green: 0.66, blue: 0.24),
        Color(red: 0.24, green: 0.36, blue: 0.72),
    ]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<TrixDeviceFingerprintPixelArt.gridSize, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<TrixDeviceFingerprintPixelArt.gridSize, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color(row: row, column: column))
                            .frame(width: 14, height: 14)
                    }
                }
            }
        }
        .padding(7)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.secondary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityLabel("Device fingerprint image")
    }

    private func color(row: Int, column: Int) -> Color {
        guard let colorIndex = pixelArt.colorIndex(row: row, column: column) else {
            return Color.primary.opacity(0.08)
        }

        return palette[colorIndex % palette.count]
    }
}

struct TrixFingerprintTechnicalText: View {
    let title: String
    let value: String
    let unavailableLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .foregroundStyle(.secondary)

            Text(value.isEmpty ? unavailableLabel : value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TrixVisualChallengeSymbolsView: View {
    let symbols: [TrixDeviceVerificationEmoji]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(symbols) { symbol in
                VStack(spacing: 2) {
                    Text(symbol.symbol)
                        .font(.title3)
                        .frame(width: 30, height: 28)

                    Text(symbol.description)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityLabel(symbols.map(\.description).joined(separator: ", "))
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 34, maximum: 34), spacing: 8, alignment: .center)]
    }
}
