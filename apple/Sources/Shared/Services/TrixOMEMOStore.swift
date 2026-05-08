import CryptoKit
import Foundation
@preconcurrency import MartinOMEMO
import Security

struct TrixOMEMOStack {
    let store: TrixOMEMOStore
    let signalStorage: SignalStorage
    let signalContext: SignalContext
    let module: OMEMOModule
}

final class TrixOMEMOStore: SignalSessionStoreProtocol,
    SignalPreKeyStoreProtocol,
    SignalSignedPreKeyStoreProtocol,
    SignalIdentityKeyStoreProtocol,
    SignalSenderKeyStoreProtocol,
    @unchecked Sendable {
    private struct StoredIdentity: Codable {
        var keyData: Data
        var statusRawValue: Int
        var own: Bool

        var status: IdentityStatus {
            IdentityStatus(rawValue: statusRawValue) ?? .undecidedInactive
        }
    }

    private struct State: Codable {
        var localRegistrationID: UInt32?
        var identityKeyPairData: Data?
        var currentPreKeyID: UInt32 = 0
        var sessions: [String: Data] = [:]
        var preKeys: [String: Data] = [:]
        var signedPreKeys: [String: Data] = [:]
        var identities: [String: StoredIdentity] = [:]
        var senderKeys: [String: Data] = [:]
    }

    private struct AddressParts {
        var name: String
        var deviceID: Int32
    }

    private let service: String
    private let account: String
    private let queue: DispatchQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var state: State

    init(
        account: String,
        service: String = "com.softgrid.trix.xmpp.omemo"
    ) throws {
        self.account = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.service = service
        self.queue = DispatchQueue(label: "TrixOMEMOStore.\(self.account)")
        self.state = try Self.loadState(service: service, account: Self.keychainAccount(for: self.account), decoder: decoder)
    }

    static func makeStack(account: String) throws -> TrixOMEMOStack {
        let store = try TrixOMEMOStore(account: account)
        let signalStorage = SignalStorage(
            sessionStore: store,
            preKeyStore: store,
            signedPreKeyStore: store,
            identityKeyStore: store,
            senderKeyStore: store
        )
        guard let signalContext = SignalContext(withStorage: signalStorage) else {
            throw MatrixClientError.e2eeUnavailable
        }

        try store.ensureLocalIdentity(context: signalContext)

        let module = OMEMOModule(
            aesGCMEngine: CryptoKitAESGCMEngine(),
            signalContext: signalContext,
            signalStorage: signalStorage
        )
        module.defaultBody = nil

        return TrixOMEMOStack(
            store: store,
            signalStorage: signalStorage,
            signalContext: signalContext,
            module: module
        )
    }

    func ensureLocalIdentity(context: SignalContext) throws {
        try queue.sync {
            var next = state
            var changed = false

            if next.localRegistrationID == nil || next.localRegistrationID == 0 {
                let registrationID = context.generateRegistrationId()
                guard registrationID != 0 else {
                    throw MatrixClientError.e2eeUnavailable
                }
                next.localRegistrationID = registrationID
                changed = true
            }

            if next.identityKeyPairData == nil {
                guard let keyPair = SignalIdentityKeyPair.generateKeyPair(context: context),
                      let keyPairData = keyPair.keyPair,
                      let publicKey = keyPair.publicKey,
                      let registrationID = next.localRegistrationID else {
                    throw MatrixClientError.e2eeUnavailable
                }

                next.identityKeyPairData = keyPairData
                let localAddress = SignalAddress(
                    name: account,
                    deviceId: Int32(bitPattern: registrationID)
                )
                next.identities[Self.addressKey(localAddress)] = StoredIdentity(
                    keyData: publicKey,
                    statusRawValue: IdentityStatus.verifiedActive.rawValue,
                    own: true
                )
                changed = true
            }

            if changed {
                try persist(next)
                state = next
            }
        }
    }

    func sessionRecord(forAddress address: SignalAddress) -> Data? {
        queue.sync {
            state.sessions[Self.addressKey(address)]
        }
    }

    func allDevices(for name: String, activeAndTrusted: Bool) -> [Int32] {
        let normalizedName = Self.normalizedName(name)
        return queue.sync {
            state.identities.compactMap { key, identity in
                guard let parts = Self.addressParts(from: key),
                      parts.name == normalizedName,
                      identity.status.isActive else {
                    return nil
                }

                if activeAndTrusted {
                    switch identity.status.trust {
                    case .trusted, .verified:
                        break
                    case .compromised, .undecided:
                        return nil
                    }
                }

                return parts.deviceID
            }
        }
    }

    func storeSessionRecord(_ data: Data, forAddress address: SignalAddress) -> Bool {
        mutate { state in
            state.sessions[Self.addressKey(address)] = data
            return true
        }
    }

    func containsSessionRecord(forAddress address: SignalAddress) -> Bool {
        queue.sync {
            state.sessions[Self.addressKey(address)] != nil
        }
    }

    func deleteSessionRecord(forAddress address: SignalAddress) -> Bool {
        mutate { state in
            state.sessions.removeValue(forKey: Self.addressKey(address)) != nil
        }
    }

    func deleteAllSessions(for name: String) -> Bool {
        let normalizedName = Self.normalizedName(name)
        return mutate { state in
            state.sessions = state.sessions.filter { key, _ in
                Self.addressParts(from: key)?.name != normalizedName
            }
            return true
        }
    }

    func currentPreKeyId() -> UInt32 {
        queue.sync {
            state.currentPreKeyID
        }
    }

    func loadPreKey(withId id: UInt32) -> Data? {
        queue.sync {
            state.preKeys[String(id)]
        }
    }

    func storePreKey(_ data: Data, withId id: UInt32) -> Bool {
        mutate { state in
            state.preKeys[String(id)] = data
            state.currentPreKeyID = max(state.currentPreKeyID, id)
            return true
        }
    }

    func containsPreKey(withId id: UInt32) -> Bool {
        queue.sync {
            state.preKeys[String(id)] != nil
        }
    }

    func deletePreKey(withId id: UInt32) -> Bool {
        mutate { state in
            state.preKeys.removeValue(forKey: String(id)) != nil
        }
    }

    func flushDeletedPreKeys() -> Bool {
        true
    }

    func countSignedPreKeys() -> Int {
        queue.sync {
            state.signedPreKeys.keys.compactMap(UInt32.init).max().map(Int.init) ?? 0
        }
    }

    func loadSignedPreKey(withId id: UInt32) -> Data? {
        queue.sync {
            state.signedPreKeys[String(id)]
        }
    }

    func storeSignedPreKey(_ data: Data, withId id: UInt32) -> Bool {
        mutate { state in
            state.signedPreKeys[String(id)] = data
            return true
        }
    }

    func containsSignedPreKey(withId id: UInt32) -> Bool {
        queue.sync {
            state.signedPreKeys[String(id)] != nil
        }
    }

    func deleteSignedPreKey(withId id: UInt32) -> Bool {
        mutate { state in
            state.signedPreKeys.removeValue(forKey: String(id)) != nil
        }
    }

    func keyPair() -> SignalIdentityKeyPairProtocol? {
        queue.sync {
            state.identityKeyPairData.flatMap(SignalIdentityKeyPair.init(fromKeyPairData:))
        }
    }

    func localRegistrationId() -> UInt32 {
        queue.sync {
            state.localRegistrationID ?? 0
        }
    }

    func save(identity address: SignalAddress, key: SignalIdentityKeyProtocol?) -> Bool {
        guard let publicKey = key?.publicKey else {
            return false
        }

        return saveIdentity(address: address, publicKeyData: publicKey)
    }

    func isTrusted(identity address: SignalAddress, key: SignalIdentityKeyProtocol?) -> Bool {
        guard let publicKey = key?.publicKey else {
            return false
        }

        return isTrusted(identity: address, publicKeyData: publicKey)
    }

    func save(identity address: SignalAddress, publicKeyData: Data?) -> Bool {
        guard let publicKeyData else {
            return false
        }

        return saveIdentity(address: address, publicKeyData: publicKeyData)
    }

    func isTrusted(identity address: SignalAddress, publicKeyData: Data?) -> Bool {
        guard let publicKeyData else {
            return false
        }

        return queue.sync {
            guard let identity = state.identities[Self.addressKey(address)] else {
                return true
            }

            guard identity.keyData == publicKeyData else {
                return false
            }

            switch identity.status.trust {
            case .undecided, .trusted, .verified:
                return true
            case .compromised:
                return false
            }
        }
    }

    func setStatus(_ status: IdentityStatus, forIdentity address: SignalAddress) -> Bool {
        mutate { state in
            let key = Self.addressKey(address)
            guard var identity = state.identities[key] else {
                return false
            }
            identity.statusRawValue = status.rawValue
            state.identities[key] = identity
            return true
        }
    }

    func setStatus(active: Bool, forIdentity address: SignalAddress) -> Bool {
        mutate { state in
            let key = Self.addressKey(address)
            guard var identity = state.identities[key] else {
                return false
            }
            let status = identity.status
            identity.statusRawValue = (active ? status.toActive() : status.toInactive()).rawValue
            state.identities[key] = identity
            return true
        }
    }

    func identities(forName name: String) -> [Identity] {
        let normalizedName = Self.normalizedName(name)
        return queue.sync {
            state.identities.compactMap { key, stored in
                guard let parts = Self.addressParts(from: key),
                      parts.name == normalizedName else {
                    return nil
                }

                return Identity(
                    address: SignalAddress(name: parts.name, deviceId: parts.deviceID),
                    status: stored.status,
                    fingerprint: Self.fingerprint(stored.keyData),
                    key: stored.keyData,
                    own: stored.own
                )
            }
        }
    }

    func hasTrustedActiveDevice(forName name: String) -> Bool {
        !allDevices(for: name, activeAndTrusted: true).isEmpty
    }

    func trustIdentity(forName name: String, deviceID: String) -> Bool {
        guard let address = Self.signalAddress(name: name, deviceID: deviceID) else {
            return false
        }

        return mutate { state in
            let key = Self.addressKey(address)
            guard var identity = state.identities[key],
                  identity.status.isActive else {
                return false
            }

            identity.statusRawValue = identity.status.toTrust(.trusted).rawValue
            state.identities[key] = identity
            return true
        }
    }

    func identityFingerprint(forAddress address: SignalAddress) -> String? {
        queue.sync {
            state.identities[Self.addressKey(address)]
                .map { Self.fingerprint($0.keyData) }
        }
    }

    func storeSenderKey(_ key: Data, address: SignalAddress?, groupId: String?) -> Bool {
        mutate { state in
            state.senderKeys[Self.senderKey(address: address, groupID: groupId)] = key
            return true
        }
    }

    func loadSenderKey(forAddress address: SignalAddress?, groupId: String?) -> Data? {
        queue.sync {
            state.senderKeys[Self.senderKey(address: address, groupID: groupId)]
        }
    }

    private func saveIdentity(address: SignalAddress, publicKeyData: Data) -> Bool {
        mutate { state in
            let key = Self.addressKey(address)
            let own = Self.normalizedName(address.name) == account
                && state.localRegistrationID == UInt32(bitPattern: address.deviceId)
            let previous = state.identities[key]
            let status: IdentityStatus

            if let previous, previous.keyData == publicKeyData {
                status = previous.status.toActive()
            } else {
                status = own ? .verifiedActive : .undecidedActive
            }

            state.identities[key] = StoredIdentity(
                keyData: publicKeyData,
                statusRawValue: status.rawValue,
                own: own
            )
            return true
        }
    }

    private func mutate(_ body: (inout State) -> Bool) -> Bool {
        queue.sync {
            var next = state
            guard body(&next) else {
                return false
            }

            do {
                try persist(next)
                state = next
                return true
            } catch {
                return false
            }
        }
    }

    private func persist(_ state: State) throws {
        let data = try encoder.encode(state)
        let account = Self.keychainAccount(for: account)
        let query = Self.baseQuery(service: service, account: account)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw MatrixClientError.keychainFailure(updateStatus.description)
        }

        var item = query
        item[kSecValueData as String] = data
#if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MatrixClientError.keychainFailure(addStatus.description)
        }
    }

    private static func loadState(service: String, account: String, decoder: JSONDecoder) throws -> State {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return State()
        }

        guard status == errSecSuccess else {
            throw MatrixClientError.keychainFailure(status.description)
        }

        guard let data = result as? Data else {
            throw MatrixClientError.keychainFailure("stored OMEMO state has unexpected format")
        }

        return try decoder.decode(State.self, from: data)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainAccount(for account: String) -> String {
        "omemo:\(normalizedName(account))"
    }

    private static func addressKey(_ address: SignalAddress) -> String {
        "\(normalizedName(address.name))|\(address.deviceId)"
    }

    private static func addressParts(from key: String) -> AddressParts? {
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let deviceID = Int32(parts[1]) else {
            return nil
        }

        return AddressParts(name: String(parts[0]), deviceID: deviceID)
    }

    private static func signalAddress(name: String, deviceID: String) -> SignalAddress? {
        if let signedID = Int32(deviceID) {
            return SignalAddress(name: normalizedName(name), deviceId: signedID)
        }

        if let unsignedID = UInt32(deviceID) {
            return SignalAddress(name: normalizedName(name), deviceId: Int32(bitPattern: unsignedID))
        }

        return nil
    }

    private static func senderKey(address: SignalAddress?, groupID: String?) -> String {
        let addressKey = address.map(Self.addressKey) ?? "none"
        return "\(groupID ?? "none")|\(addressKey)"
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func fingerprint(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

final class CryptoKitAESGCMEngine: AES_GCM_Engine {
    func encrypt(
        iv: Data,
        key: Data,
        message: Data,
        output: UnsafeMutablePointer<Data>?,
        tag: UnsafeMutablePointer<Data>?
    ) -> Bool {
        do {
            let sealedBox = try AES.GCM.seal(
                message,
                using: SymmetricKey(data: key),
                nonce: AES.GCM.Nonce(data: iv)
            )
            output?.pointee = sealedBox.ciphertext
            tag?.pointee = sealedBox.tag
            return true
        } catch {
            return false
        }
    }

    func decrypt(
        iv: Data,
        key: Data,
        encoded: Data,
        auth tag: Data?,
        output: UnsafeMutablePointer<Data>?
    ) -> Bool {
        guard let tag else {
            return false
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: iv),
                ciphertext: encoded,
                tag: tag
            )
            output?.pointee = try AES.GCM.open(sealedBox, using: SymmetricKey(data: key))
            return true
        } catch {
            return false
        }
    }
}
