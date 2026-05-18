import SwiftUI

struct TrixAppLockProtectedView<Content: View>: View {
    @ObservedObject var model: TrixAppModel
    @ObservedObject private var appLockViewModel: TrixAppLockViewModel
    private let content: () -> Content

    init(model: TrixAppModel, @ViewBuilder content: @escaping () -> Content) {
        self.model = model
        self._appLockViewModel = ObservedObject(wrappedValue: model.appLockViewModel)
        self.content = content
    }

    var body: some View {
        if model.isAuthenticated && appLockViewModel.isLocked {
            TrixAppLockScreenView(viewModel: appLockViewModel)
        } else {
            content()
        }
    }
}

struct TrixAppLockScreenView: View {
    @ObservedObject var viewModel: TrixAppLockViewModel

    var body: some View {
        VStack(spacing: 18) {
            TrixAvatarView(
                title: "Trix",
                systemImage: "lock.shield.fill",
                size: 64
            )

            VStack(spacing: 6) {
                Text("Trix Locked")
                    .font(.title2.weight(.semibold))
                Text("Unlock with system authentication to view chats and settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task {
                    await viewModel.unlock()
                }
            } label: {
                Label(
                    viewModel.isAuthenticating ? "Unlocking" : "Unlock",
                    systemImage: "lock.open"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isAuthenticating || !viewModel.availability.canAuthenticate)

            Text(viewModel.availability.authenticationLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TrixDesign.screenBackground)
    }
}

struct TrixAppLockSettingsSection: View {
    @ObservedObject var viewModel: TrixAppLockViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "App Lock",
                isOn: Binding(
                    get: { viewModel.settings.isEnabled },
                    set: { viewModel.setEnabled($0) }
                )
            )
            .disabled(!viewModel.availability.canAuthenticate && !viewModel.settings.isEnabled)

            Toggle(
                "Lock When App Leaves Foreground",
                isOn: Binding(
                    get: { viewModel.settings.locksOnBackground },
                    set: { viewModel.setLocksOnBackground($0) }
                )
            )
            .disabled(!viewModel.settings.isEnabled)

            Picker(
                "Idle Timeout",
                selection: Binding(
                    get: { viewModel.settings.idleTimeout },
                    set: { viewModel.setIdleTimeout($0) }
                )
            ) {
                ForEach(TrixAppLockIdleTimeout.allCases) { timeout in
                    Text(timeout.label)
                        .tag(timeout)
                }
            }
            .disabled(!viewModel.settings.isEnabled)

            LabeledContent("System Auth", value: viewModel.availability.authenticationLabel)

            if let message = viewModel.errorMessage ?? viewModel.availability.unavailableReason,
               !viewModel.availability.canAuthenticate || viewModel.errorMessage != nil {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(viewModel.availability.canAuthenticate ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                viewModel.lockNow()
            } label: {
                Label("Lock Now", systemImage: "lock")
            }
            .disabled(!viewModel.canLock || viewModel.isLocked)
        }
    }
}
