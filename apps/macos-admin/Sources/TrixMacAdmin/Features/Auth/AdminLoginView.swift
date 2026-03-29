import SwiftUI

struct AdminLoginView: View {
    @ObservedObject var model: AdminAppModel
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in")
                .font(.title2)
            if let cluster = model.selectedCluster {
                Text(cluster.displayName)
                    .foregroundStyle(.secondary)
            }
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            if let err = model.loginError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Button("Sign in") {
                    Task {
                        await model.signIn(username: username, password: password)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSigningIn || username.isEmpty || password.isEmpty)
                if model.isSigningIn {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 400)
    }
}
