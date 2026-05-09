import Foundation

@MainActor
final class TrixAPNsCoordinator {
    static let shared = TrixAPNsCoordinator()

    private weak var model: TrixAppModel?
    private var latestToken: TrixAPNsDeviceToken?

    private init() {}

    func attach(model: TrixAppModel) {
        self.model = model
        guard let latestToken else {
            return
        }

        Task {
            await model.registerAPNsDeviceToken(latestToken)
        }
    }

    func didRegister(deviceToken: Data) {
        let token = TrixAPNsDeviceToken(data: deviceToken)
        latestToken = token

        guard let model else {
            return
        }

        Task {
            await model.registerAPNsDeviceToken(token)
        }
    }

    func didFailToRegisterForRemoteNotifications() {
        latestToken = nil
    }

    func didReceiveRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let model else {
            return false
        }

        return await model.handleRemoteNotification(userInfo: userInfo)
    }
}
