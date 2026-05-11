import SwiftUI

struct TrixInviteIssueView: View {
    @ObservedObject var model: TrixAppModel
    @State private var localpart = ""
    @State private var displayName = ""
    @State private var ttlDays = 7
    @State private var issuedInvite: TrixIssuedInvite?
    @State private var isIssuing = false
    @State private var didCopy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Reserved handle", text: $localpart)
                .trixInviteLocalpartField()
                .textFieldStyle(.roundedBorder)

            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)

            Stepper(value: $ttlDays, in: 1...30) {
                LabeledContent("Valid for", value: "\(ttlDays) day\(ttlDays == 1 ? "" : "s")")
            }

            Button {
                Task {
                    await issueInvite()
                }
            } label: {
                if isIssuing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Create Invite", systemImage: "envelope.badge")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.isAuthenticated || isIssuing)

            if let issuedInvite {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Code") {
                        Text(issuedInvite.inviteCode)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }

                    if let reservedUserID = issuedInvite.reservedUserID {
                        LabeledContent("Reserved", value: reservedUserID)
                    }

                    LabeledContent("Expires", value: issuedInvite.expiresAt)

                    Button {
                        TrixPasteboard.copy(issuedInvite.inviteCode)
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Copied" : "Copy Code", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(TrixDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: localpart) { _, _ in
            clearIssuedState()
        }
        .onChange(of: displayName) { _, _ in
            clearIssuedState()
        }
        .onChange(of: ttlDays) { _, _ in
            clearIssuedState()
        }
    }

    private func issueInvite() async {
        guard !isIssuing else {
            return
        }

        isIssuing = true
        errorMessage = nil
        didCopy = false
        defer { isIssuing = false }

        do {
            issuedInvite = try await model.issueInvite(
                localpart: localpart,
                displayName: displayName,
                ttlDays: ttlDays
            )
        } catch {
            issuedInvite = nil
            errorMessage = error.trixUserFacingMessage
        }
    }

    private func clearIssuedState() {
        issuedInvite = nil
        didCopy = false
        errorMessage = nil
    }
}

private extension View {
    @ViewBuilder
    func trixInviteLocalpartField() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.username)
        #else
        self
            .autocorrectionDisabled()
            .textContentType(.username)
        #endif
    }
}
