import SwiftUI

private let pendingApprovalAccent = Color(red: 0.14, green: 0.55, blue: 0.98)

struct PendingApprovalView: View {
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel

    @State private var isShowingForgetAlert = false
    @State private var isShowingTechnicalDetails = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.98, blue: 1.0),
                    Color(red: 0.9, green: 0.95, blue: 1.0),
                    Color.white,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    statusHero

                    if let errorMessage = model.errorMessage {
                        PendingApprovalBanner(
                            tint: .red,
                            systemImage: "wifi.exclamationmark",
                            text: errorMessage
                        )
                    }

                    if let localIdentity = model.localIdentity {
                        identityCard(localIdentity)
                    }

                    approvalCard
                    technicalCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 120)
            }
        }
        .accessibilityIdentifier(TrixAccessibilityID.Root.pendingApprovalScreen)
        .safeAreaInset(edge: .bottom) {
            bottomActions
        }
        .toolbar(.hidden, for: .navigationBar)
        .alert("Forget this device?", isPresented: $isShowingForgetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                model.forgetLocalDevice()
            }
        } message: {
            Text("This removes the locally stored pending device identity so you can restart the link flow.")
        }
    }

    private var statusHero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(pendingApprovalAccent.opacity(0.14))
                    .frame(width: 96, height: 96)

                Image(systemName: "lock.iphone")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(pendingApprovalAccent)
            }

            VStack(spacing: 8) {
                Text("Approve This iPhone")
                    .font(.system(size: 32, weight: .bold, design: .rounded))

                Text("This phone is almost ready. Approve it from one of your signed-in devices and your chats will appear here.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func identityCard(_ localIdentity: LocalDeviceIdentity) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pending Device")
                .font(.headline)

            HStack(spacing: 12) {
                Circle()
                    .fill(pendingApprovalAccent.opacity(0.12))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "iphone.gen3")
                            .foregroundStyle(pendingApprovalAccent)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(localIdentity.deviceDisplayName)
                        .font(.body.weight(.semibold))

                    Text("Ready to join account \(localIdentity.accountId.prefix(8))…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            HStack {
                Text("Status")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Pending")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 18, y: 10)
        .accessibilityIdentifier(TrixAccessibilityID.PendingApproval.deviceCard)
    }

    private var approvalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What happens next")
                .font(.headline)

            ApprovalStepRow(
                number: "1",
                title: "Open another signed-in device",
                text: "Use a phone or desktop that is already active on this account."
            )

            ApprovalStepRow(
                number: "2",
                title: "Approve this iPhone",
                text: "In Settings, approve this pending device from the linked devices list."
            )

            ApprovalStepRow(
                number: "3",
                title: "Come back here",
                text: "Tap “Check Approval” and the app will continue straight into your chats."
            )
        }
        .padding(20)
        .background(Color.white.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var technicalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isShowingTechnicalDetails.toggle()
                }
            } label: {
                HStack {
                    Text("Advanced Details")
                        .font(.headline)

                    Spacer()

                    Image(systemName: isShowingTechnicalDetails ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(TrixAccessibilityID.PendingApproval.technicalDetailsToggle)

            if isShowingTechnicalDetails {
                VStack(alignment: .leading, spacing: 12) {
                    if let localIdentity = model.localIdentity {
                        technicalRow("Account", value: localIdentity.accountId)
                        technicalRow("This Device", value: localIdentity.deviceId)
                    }

                    technicalRow("Server", value: serverBaseURL)

                    if let snapshot = model.systemSnapshot {
                        technicalRow("Service", value: snapshot.health.service)
                        technicalRow("Version", value: snapshot.health.version)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var bottomActions: some View {
        VStack(spacing: 10) {
            Button(action: reload) {
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                } else {
                    Text("Check Approval")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                }
            }
            .foregroundStyle(.white)
            .background(pendingApprovalAccent)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .disabled(model.isLoading)
            .accessibilityIdentifier(TrixAccessibilityID.PendingApproval.checkApprovalButton)

            Button("Forget This Device", role: .destructive) {
                isShowingForgetAlert = true
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier(TrixAccessibilityID.PendingApproval.forgetDeviceButton)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
    }

    private func technicalRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
    }

    private func reload() {
        Task {
            await model.refresh(baseURLString: serverBaseURL)
        }
    }
}

private struct PendingApprovalBanner: View {
    let tint: Color
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(tint)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ApprovalStepRow: View {
    let number: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(pendingApprovalAccent)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        PendingApprovalView(
            serverBaseURL: .constant(ServerConfiguration.defaultBaseURL.absoluteString),
            model: AppModel()
        )
    }
}
