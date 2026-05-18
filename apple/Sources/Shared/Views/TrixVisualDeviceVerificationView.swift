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
                TrixVisualChallengeSymbolsView(symbols: visualVerification.symbols)

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

                LabeledContent {
                    Text(visualVerification.groupedSourceText)
                        .font(.caption.monospacedDigit())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text(visualVerification.kind == .libsignalSafetyNumber ? "Safety number" : "Visual fingerprint")
                }

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
        LabeledContent {
            Text(device.hasFingerprint ? device.fingerprint : "Unavailable")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Text("Raw fingerprint")
        }
    }
}

struct TrixVisualChallengeSymbolsView: View {
    let symbols: [TrixDeviceVerificationEmoji]

    var body: some View {
        HStack(spacing: 8) {
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
}
