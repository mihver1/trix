import CallKit
import Foundation
import PushKit

final class TrixVoIPPushCoordinator: NSObject {
    @MainActor
    static let shared = TrixVoIPPushCoordinator()

    private let provider: CXProvider
    private var registry: PKPushRegistry?
    private var callUUIDByCallID: [String: UUID] = [:]
    private var callIDByCallUUID: [UUID: String] = [:]
    private weak var model: TrixAppModel?
    private var latestToken: TrixVoIPDeviceToken?

    private override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        self.provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func start() {
        guard registry == nil else {
            return
        }

        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    func attach(model: TrixAppModel) {
        self.model = model

        guard let latestToken else {
            return
        }

        Task {
            await model.registerVoIPDeviceToken(latestToken)
        }
    }

    private func register(token: TrixVoIPDeviceToken) {
        latestToken = token

        guard let model else {
            return
        }

        Task {
            await model.registerVoIPDeviceToken(token)
        }
    }

    private func invalidateToken() {
        latestToken = nil

        guard let model else {
            return
        }

        Task {
            await model.invalidateVoIPDeviceToken()
        }
    }

    @MainActor
    private func answer(callID: String, completion: TrixCallKitActionCompletion) async {
        guard let model else {
            completion.fail()
            return
        }

        if await model.acceptIncomingCallKitCall(callID: callID) {
            completion.fulfill()
        } else {
            completion.fail()
        }
    }

    @MainActor
    private func end(callID: String, completion: TrixCallKitActionCompletion) async {
        guard let model else {
            completion.fail()
            return
        }

        if await model.endCallKitCall(callID: callID) {
            let uuid = callUUIDByCallID[callID]
            callUUIDByCallID[callID] = nil
            if let uuid {
                callIDByCallUUID[uuid] = nil
            }
            completion.fulfill()
        } else {
            completion.fail()
        }
    }
}

extension TrixVoIPPushCoordinator: PKPushRegistryDelegate {
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else {
            return
        }
        let token = TrixVoIPDeviceToken(data: pushCredentials.token)
        Task { @MainActor in
            TrixVoIPPushCoordinator.shared.register(token: token)
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        guard type == .voIP else {
            return
        }
        Task { @MainActor in
            TrixVoIPPushCoordinator.shared.invalidateToken()
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        let pushCompletion = TrixVoIPPushCompletion(completion)
        let callPayload = TrixVoIPCallPayload(userInfo: payload.dictionaryPayload)
        guard callPayload.isCallNotification, let callID = callPayload.callID else {
            pushCompletion()
            return
        }

        let callUUID = callUUIDByCallID[callID] ?? UUID()
        callUUIDByCallID[callID] = callUUID
        callIDByCallUUID[callUUID] = callID

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Trix")
        update.localizedCallerName = "Trix"
        update.hasVideo = true

        provider.reportNewIncomingCall(with: callUUID, update: update) { _ in
            pushCompletion()
        }
    }
}

extension TrixVoIPPushCoordinator: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            TrixVoIPPushCoordinator.shared.callUUIDByCallID = [:]
            TrixVoIPPushCoordinator.shared.callIDByCallUUID = [:]
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let callID = callIDByCallUUID[action.callUUID] else {
            action.fail()
            return
        }

        let completion = TrixCallKitActionCompletion(
            fulfill: { action.fulfill() },
            fail: { action.fail() }
        )
        Task { @MainActor in
            await TrixVoIPPushCoordinator.shared.answer(callID: callID, completion: completion)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let callID = callIDByCallUUID[action.callUUID] else {
            action.fail()
            return
        }

        let completion = TrixCallKitActionCompletion(
            fulfill: { action.fulfill() },
            fail: { action.fail() }
        )
        Task { @MainActor in
            await TrixVoIPPushCoordinator.shared.end(callID: callID, completion: completion)
        }
    }
}

private struct TrixVoIPPushCompletion: @unchecked Sendable {
    private let complete: () -> Void

    init(_ complete: @escaping () -> Void) {
        self.complete = complete
    }

    func callAsFunction() {
        complete()
    }
}

private struct TrixCallKitActionCompletion: @unchecked Sendable {
    let fulfill: () -> Void
    let fail: () -> Void
}
