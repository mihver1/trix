import Combine
import Foundation

@MainActor
final class TrixCallAudioLevelRegistry: ObservableObject {
    static let shared = TrixCallAudioLevelRegistry()

    @Published private(set) var levelsByCallID: [String: Double] = [:]
    @Published private(set) var lastAudibleInputAtByCallID: [String: Date] = [:]

    private init() {}

    func level(for callID: String?) -> Double {
        guard let callID else {
            return 0
        }

        return levelsByCallID[callID] ?? 0
    }

    func localInputSignalState(
        callID: String?,
        audioState: TrixCallLocalAudioState,
        startedAt: Date?,
        now: Date = Date()
    ) -> TrixCallLocalInputSignalState {
        switch audioState {
        case .unavailable:
            return .unavailable
        case .muted:
            return .muted
        case .unmuted:
            guard let callID else {
                return .detecting
            }

            if level(for: callID) >= 0.05 {
                return .active
            }

            if let lastAudibleInputAt = lastAudibleInputAtByCallID[callID],
               now.timeIntervalSince(lastAudibleInputAt) <= 2.5 {
                return .active
            }

            if let startedAt, now.timeIntervalSince(startedAt) >= 5 {
                return .low
            }

            return .detecting
        }
    }

    func setLevel(_ level: Double, callID: String, now: Date = Date()) {
        let clampedLevel = min(max(level, 0), 1)
        if clampedLevel >= 0.05 {
            lastAudibleInputAtByCallID[callID] = now
        }

        let previousLevel = levelsByCallID[callID] ?? 0
        guard clampedLevel == 0 || abs(previousLevel - clampedLevel) >= 0.01 else {
            return
        }

        levelsByCallID[callID] = clampedLevel
    }

    func clear(callID: String) {
        levelsByCallID[callID] = nil
        lastAudibleInputAtByCallID[callID] = nil
    }
}
