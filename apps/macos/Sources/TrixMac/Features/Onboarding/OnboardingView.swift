import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                leadingColumn
                    .frame(width: 410)

                formColumn
            }

            VStack(alignment: .leading, spacing: 24) {
                leadingColumn
                formColumn
            }
        }
    }

    private var leadingColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            TrixPanel(
                title: "Mac-First Bootstrap",
                subtitle: "The first device flow should feel like a launch console, not a settings screen.",
                tone: .inverted
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    OnboardingFeature(
                        symbol: "wave.3.right.circle.fill",
                        title: "Live runtime handshake",
                        detail: "Reads `/v0/system/health` and `/v0/system/version` before you register anything."
                    )
                    OnboardingFeature(
                        symbol: "key.horizontal.fill",
                        title: "Real device material",
                        detail: "Generates account-root and transport signing keys locally on this Mac."
                    )
                    OnboardingFeature(
                        symbol: "rectangle.stack.badge.person.crop.fill",
                        title: "Stateful restore",
                        detail: "Replays challenge/session auth using stored device keys instead of fake local login."
                    )
                    OnboardingFeature(
                        symbol: "text.line.first.and.arrowtriangle.forward",
                        title: "Next slice already queued",
                        detail: "After sign-in the shell loads devices, chats, selected chat detail and encrypted history."
                    )
                }
            }

            TrixPanel(
                title: "Environment Readiness",
                subtitle: "Useful when the local backend is down or only partially started."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        TrixToneBadge(label: readinessLabel, tint: readinessTint)

                        if let health = model.health {
                            Text("uptime \(formatUptime(health.uptimeMs))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(TrixPalette.inkMuted)
                        }
                    }

                    TrixMetricTile(
                        label: "Suggested target",
                        value: model.serverBaseURLString,
                        footnote: model.health == nil ? "Make sure the backend is reachable from this Mac." : "Handshake succeeded at least once in this session."
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        CommandLineChip("docker compose up postgres")
                        CommandLineChip("cargo run -p trixd")
                    }

                    Text("Until MLS and native Rust bindings land, this screen is the quickest way to validate backend lifecycle and account bootstrap.")
                        .font(.footnote)
                        .foregroundStyle(TrixPalette.inkMuted)
                }
            }
        }
    }

    private var formColumn: some View {
        TrixPanel(
            title: "Create The First Trusted Device",
            subtitle: "Register the account root, transport key and local device profile in one pass.",
            tone: .strong
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    TrixToneBadge(label: endpointLabel, tint: readinessTint)
                    Text("platform macos")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TrixPalette.inkMuted)
                }

                TrixInputBlock("Server URL", hint: "Usually `http://127.0.0.1:8080` in local development.") {
                    TextField("http://127.0.0.1:8080", text: $model.serverBaseURLString)
                        .textFieldStyle(.plain)
                        .trixInputChrome()
                }

                TrixInputBlock("Profile Name", hint: "Visible name for the account.") {
                    TextField("Maksym", text: $model.draft.profileName)
                        .textFieldStyle(.plain)
                        .trixInputChrome()
                }

                HStack(alignment: .top, spacing: 16) {
                    TrixInputBlock("Handle", hint: "Optional public handle.") {
                        TextField("optional handle", text: $model.draft.handle)
                            .textFieldStyle(.plain)
                            .trixInputChrome()
                    }

                    TrixInputBlock("Device Name", hint: "How this Mac appears in the device list.") {
                        TextField("This Mac", text: $model.draft.deviceDisplayName)
                            .textFieldStyle(.plain)
                            .trixInputChrome()
                    }
                }

                TrixInputBlock("Profile Bio", hint: "Stored as profile metadata on the server.") {
                    TextEditor(text: $model.draft.profileBio)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140)
                        .font(.body)
                        .trixInputChrome()
                }

                HStack(spacing: 12) {
                    Button {
                        Task {
                            await model.refreshServerStatus()
                        }
                    } label: {
                        Label("Check Server", systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(TrixActionButtonStyle(tone: .secondary))
                    .frame(maxWidth: 190)

                    Button {
                        Task {
                            await model.createAccount()
                        }
                    } label: {
                        if model.isCreatingAccount {
                            Label("Creating Device…", systemImage: "hourglass")
                        } else {
                            Label("Create Account", systemImage: "arrow.up.right.circle.fill")
                        }
                    }
                    .buttonStyle(TrixActionButtonStyle(tone: .primary))
                    .disabled(!model.canCreateAccount || model.isCreatingAccount)
                    .frame(maxWidth: 240)
                }

                Text("Private keys stay on this Mac. The server only receives public material and the signed bootstrap payload.")
                    .font(.footnote)
                    .foregroundStyle(TrixPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var readinessLabel: String {
        if model.isRefreshingStatus {
            return "Checking runtime"
        }
        if let health = model.health {
            return health.status == .ok ? "Runtime ready" : "Runtime degraded"
        }
        return "Runtime offline"
    }

    private var endpointLabel: String {
        model.health == nil ? "Handshake pending" : "Handshake complete"
    }

    private var readinessTint: Color {
        if model.isRefreshingStatus {
            return TrixPalette.rust
        }
        if let health = model.health {
            return health.status == .ok ? TrixPalette.success : TrixPalette.warning
        }
        return TrixPalette.warning
    }

    private func formatUptime(_ uptimeMs: UInt64) -> String {
        let seconds = Int(uptimeMs / 1000)
        if seconds < 60 {
            return "\(seconds)s"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        let remainderMinutes = minutes % 60
        return "\(hours)h \(remainderMinutes)m"
    }
}

private struct OnboardingFeature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(TrixPalette.accentSoft)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.70))
            }
        }
    }
}

private struct CommandLineChip: View {
    let command: String

    init(_ command: String) {
        self.command = command
    }

    var body: some View {
        Text(command)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(TrixPalette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(TrixPalette.outline, lineWidth: 1)
            }
    }
}
