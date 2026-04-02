import Foundation

@MainActor
struct AuthenticatedContext {
    let baseURLString: String
    let identity: LocalDeviceIdentity
    let session: AuthSessionResponse
}

@MainActor
final class AuthenticatedSessionCoordinator {
    private let identityStore: LocalDeviceIdentityStore
    private let authSessionResolutionGate = AuthSessionResolutionGate()

    init(identityStore: LocalDeviceIdentityStore) {
        self.identityStore = identityStore
    }

    func validatedBaseURLString(_ baseURLString: String) throws -> String {
        try TrixCoreServerBridge.validatedBaseURLString(baseURLString)
    }

    func currentUsableSession(
        for identity: LocalDeviceIdentity,
        baseURLString: String,
        leewaySeconds: UInt64
    ) -> AuthSessionResponse? {
        authSessionResolutionGate.currentUsableSession(
            for: identity,
            baseURLString: baseURLString,
            leewaySeconds: leewaySeconds
        )
    }

    func makeAuthenticatedContext(
        baseURLString: String,
        identity: LocalDeviceIdentity,
        existingSession: AuthSessionResponse? = nil
    ) async throws -> AuthenticatedContext {
        let normalizedBaseURL = try validatedBaseURLString(baseURLString)
        let session = try await authSessionResolutionGate.resolve(
            identity: identity,
            baseURLString: normalizedBaseURL,
            existingSession: existingSession,
            leewaySeconds: 60
        ) {
            try TrixCoreServerBridge.authenticate(
                baseURLString: normalizedBaseURL,
                identity: identity
            )
        }
        let effectiveIdentity = try reconcileAuthenticatedIdentity(
            baseURLString: normalizedBaseURL,
            accessToken: session.accessToken,
            identity: identity
        )
        return AuthenticatedContext(
            baseURLString: normalizedBaseURL,
            identity: effectiveIdentity,
            session: session
        )
    }

    func invalidateCachedAuthSession(currentServerBaseURLString: String?) {
        if let invalidatedSession = authSessionResolutionGate.invalidate(),
           let baseURLString = currentServerBaseURLString {
            try? TrixCoreServerBridge.clearAccessToken(
                baseURLString: baseURLString,
                accessToken: invalidatedSession.accessToken
            )
        }
    }

    private func reconcileAuthenticatedIdentity(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity
    ) throws -> LocalDeviceIdentity {
        var effectiveIdentity = identity.trustState == .active ? identity : identity.markingActive()

        if !effectiveIdentity.hasFullAccountAccess {
            do {
                let transferBundle = try TrixCoreServerBridge.fetchDeviceTransferBundle(
                    baseURLString: baseURLString,
                    accessToken: accessToken,
                    deviceId: effectiveIdentity.deviceId
                )
                if let transferBundleData = Data(base64Encoded: transferBundle.transferBundleB64),
                   !transferBundleData.isEmpty {
                    effectiveIdentity = try effectiveIdentity.importingAccountRoot(
                        fromTransferBundle: transferBundleData
                    )
                } else {
                    effectiveIdentity = effectiveIdentity.markingRequiresRootUpgrade()
                }
            } catch {
                effectiveIdentity = effectiveIdentity.markingRequiresRootUpgrade()
            }
        }

        if effectiveIdentity != identity {
            try identityStore.save(effectiveIdentity)
        }

        return effectiveIdentity
    }
}

@MainActor
final class AuthSessionResolutionGate {
    private var cachedAuthSession: CachedAuthSession?
    private var inFlightResolution: (key: AuthSessionResolutionKey, task: Task<AuthSessionResponse, Error>)?

    func currentUsableSession(
        for identity: LocalDeviceIdentity,
        baseURLString: String,
        leewaySeconds: UInt64
    ) -> AuthSessionResponse? {
        guard let cachedAuthSession,
              cachedAuthSession.isUsable(
                  for: identity,
                  baseURLString: normalize(baseURLString),
                  leewaySeconds: leewaySeconds
              ) else {
            return nil
        }

        return cachedAuthSession.session
    }

    func resolve(
        identity: LocalDeviceIdentity,
        baseURLString: String,
        existingSession: AuthSessionResponse?,
        leewaySeconds: UInt64,
        authenticate: @escaping @MainActor () async throws -> AuthSessionResponse
    ) async throws -> AuthSessionResponse {
        let normalizedBaseURL = normalize(baseURLString)
        if let existingSession {
            cache(existingSession, for: identity, baseURLString: normalizedBaseURL)
            return existingSession
        }

        if let cachedAuthSession,
           cachedAuthSession.isUsable(
               for: identity,
               baseURLString: normalizedBaseURL,
               leewaySeconds: leewaySeconds
           ) {
            return cachedAuthSession.session
        }

        let key = AuthSessionResolutionKey(
            baseURLString: normalizedBaseURL,
            accountId: identity.accountId,
            deviceId: identity.deviceId
        )
        if let inFlightResolution,
           inFlightResolution.key == key {
            return try await inFlightResolution.task.value
        }

        let task = Task { @MainActor in
            try await authenticate()
        }
        inFlightResolution = (key, task)

        do {
            let session = try await task.value
            cache(session, for: identity, baseURLString: normalizedBaseURL)
            if inFlightResolution?.key == key {
                inFlightResolution = nil
            }
            return session
        } catch {
            if inFlightResolution?.key == key {
                inFlightResolution = nil
            }
            throw error
        }
    }

    func invalidate() -> AuthSessionResponse? {
        let invalidatedSession = cachedAuthSession?.session
        cachedAuthSession = nil
        inFlightResolution?.task.cancel()
        inFlightResolution = nil
        return invalidatedSession
    }

    private func cache(
        _ session: AuthSessionResponse,
        for identity: LocalDeviceIdentity,
        baseURLString: String
    ) {
        cachedAuthSession = CachedAuthSession(
            baseURLString: normalize(baseURLString),
            accountId: identity.accountId,
            deviceId: identity.deviceId,
            session: session
        )
    }

    private func normalize(_ baseURLString: String) -> String {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AuthSessionResolutionKey: Equatable {
    let baseURLString: String
    let accountId: String
    let deviceId: String
}

private struct CachedAuthSession {
    let baseURLString: String
    let accountId: String
    let deviceId: String
    let session: AuthSessionResponse

    func isUsable(
        for identity: LocalDeviceIdentity,
        baseURLString: String,
        leewaySeconds: UInt64
    ) -> Bool {
        guard self.baseURLString == baseURLString,
              accountId == identity.accountId,
              deviceId == identity.deviceId,
              session.deviceStatus != .revoked
        else {
            return false
        }

        let nowUnix = UInt64(Date().timeIntervalSince1970)
        if session.expiresAtUnix <= nowUnix {
            return false
        }

        return session.expiresAtUnix > nowUnix + leewaySeconds
    }
}
