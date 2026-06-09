import Combine
import Foundation

enum TrixCallMediaSignalStatus: String, Equatable, Sendable {
    case unavailable
    case waiting
    case receiving
    case muted
    case paused
}

enum TrixCallMediaKind: Equatable, Sendable {
    case audio
    case video
}

enum TrixCallLocalInputSignalState: Equatable, Sendable {
    case unavailable
    case muted
    case detecting
    case active
    case low
}

struct TrixCallMediaQualitySnapshot: Equatable, Sendable {
    var relayOnly: Bool
    var audioProbeEnabled: Bool
    var remoteAudioStatus: TrixCallMediaSignalStatus
    var remoteVideoStatus: TrixCallMediaSignalStatus
    var lastRemoteAudioFrameAt: Date?
    var updatedAt: Date?

    static let empty = TrixCallMediaQualitySnapshot(
        relayOnly: false,
        audioProbeEnabled: false,
        remoteAudioStatus: .unavailable,
        remoteVideoStatus: .unavailable,
        lastRemoteAudioFrameAt: nil,
        updatedAt: nil
    )
}

@MainActor
final class TrixCallMediaQualityRegistry: ObservableObject {
    static let shared = TrixCallMediaQualityRegistry()

    @Published private(set) var snapshotsByCallID: [String: TrixCallMediaQualitySnapshot] = [:]

    private init() {}

    func snapshot(for callID: String?) -> TrixCallMediaQualitySnapshot {
        guard let callID else {
            return .empty
        }

        return snapshotsByCallID[callID] ?? .empty
    }

    func configure(
        callID: String,
        expectsRemoteAudio: Bool,
        expectsRemoteVideo: Bool,
        relayOnly: Bool,
        audioProbeEnabled: Bool,
        now: Date = Date()
    ) {
        snapshotsByCallID[callID] = TrixCallMediaQualitySnapshot(
            relayOnly: relayOnly,
            audioProbeEnabled: audioProbeEnabled,
            remoteAudioStatus: expectsRemoteAudio ? .waiting : .unavailable,
            remoteVideoStatus: expectsRemoteVideo ? .waiting : .unavailable,
            lastRemoteAudioFrameAt: nil,
            updatedAt: now
        )
    }

    func updateRemoteMedia(
        callID: String,
        kind: TrixCallMediaKind,
        status: TrixCallMediaSignalStatus,
        now: Date = Date()
    ) {
        var snapshot = snapshotsByCallID[callID] ?? .empty
        switch kind {
        case .audio:
            snapshot.remoteAudioStatus = status
        case .video:
            snapshot.remoteVideoStatus = status
        }
        snapshot.updatedAt = now
        snapshotsByCallID[callID] = snapshot
    }

    func noteRemoteAudioFrame(callID: String, now: Date = Date()) {
        var snapshot = snapshotsByCallID[callID] ?? .empty
        snapshot.remoteAudioStatus = .receiving
        snapshot.lastRemoteAudioFrameAt = now
        snapshot.updatedAt = now
        snapshotsByCallID[callID] = snapshot
    }

    func clear(callID: String) {
        snapshotsByCallID[callID] = nil
    }
}
