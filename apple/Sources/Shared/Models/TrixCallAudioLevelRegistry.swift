import Combine
import Foundation

@MainActor
final class TrixCallAudioLevelRegistry: ObservableObject {
    static let shared = TrixCallAudioLevelRegistry()

    @Published private(set) var levelsByCallID: [String: Double] = [:]

    private init() {}

    func level(for callID: String?) -> Double {
        guard let callID else {
            return 0
        }

        return levelsByCallID[callID] ?? 0
    }

    func setLevel(_ level: Double, callID: String) {
        let clampedLevel = min(max(level, 0), 1)
        let previousLevel = levelsByCallID[callID] ?? 0
        guard clampedLevel == 0 || abs(previousLevel - clampedLevel) >= 0.01 else {
            return
        }

        levelsByCallID[callID] = clampedLevel
    }

    func clear(callID: String) {
        levelsByCallID[callID] = nil
    }
}
