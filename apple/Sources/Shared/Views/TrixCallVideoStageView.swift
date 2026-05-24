import SwiftUI

#if canImport(LiveKit)
import LiveKit
#endif

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if canImport(LiveKit)
@MainActor
final class TrixLiveKitVideoTrackRegistry: ObservableObject {
    static let shared = TrixLiveKitVideoTrackRegistry()

    @Published private(set) var tracksByCallID: [String: TrixLiveKitVideoTracks] = [:]

    private init() {}

    func tracks(for callID: String) -> TrixLiveKitVideoTracks {
        tracksByCallID[callID] ?? TrixLiveKitVideoTracks()
    }

    func setLocalTrack(_ track: VideoTrack?, callID: String) {
        var tracks = tracksByCallID[callID] ?? TrixLiveKitVideoTracks()
        tracks.localTrack = track
        tracksByCallID[callID] = tracks
    }

    func setRemoteTrack(_ track: VideoTrack?, callID: String) {
        var tracks = tracksByCallID[callID] ?? TrixLiveKitVideoTracks()
        tracks.remoteTrack = track
        tracksByCallID[callID] = tracks
    }

    func clear(callID: String) {
        tracksByCallID[callID] = nil
    }
}

struct TrixLiveKitVideoTracks {
    var localTrack: VideoTrack?
    var remoteTrack: VideoTrack?
}
#else
@MainActor
final class TrixLiveKitVideoTrackRegistry: ObservableObject {
    static let shared = TrixLiveKitVideoTrackRegistry()

    @Published private(set) var tracksByCallID: [String: TrixLiveKitVideoTracks] = [:]

    private init() {}

    func tracks(for callID: String) -> TrixLiveKitVideoTracks {
        tracksByCallID[callID] ?? TrixLiveKitVideoTracks()
    }

    func clear(callID: String) {
        tracksByCallID[callID] = nil
    }
}

struct TrixLiveKitVideoTracks {}
#endif

struct TrixCallVideoStage: View {
    let activeCall: TrixActiveMediaCall?
    let state: TrixCallLifecycleState
    @ObservedObject private var trackRegistry = TrixLiveKitVideoTrackRegistry.shared

    var body: some View {
        if state.kind == .directVideo {
            ZStack(alignment: .bottomTrailing) {
                remoteVideoSurface

                if state.localCameraState != .unavailable {
                    localVideoSurface
                        .frame(width: 118, height: 82)
                        .padding(8)
                        .accessibilitySortPriority(1)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private var remoteVideoSurface: some View {
        #if canImport(LiveKit)
        let track = videoTracks?.remoteTrack
        TrixVideoSurface(
            track: track,
            title: remoteVideoTitle,
            systemImage: remoteVideoSystemImage,
            prominence: .primary
        )
        #else
        TrixVideoSurface(
            title: remoteVideoTitle,
            systemImage: remoteVideoSystemImage,
            prominence: .primary
        )
        #endif
    }

    @ViewBuilder
    private var localVideoSurface: some View {
        #if canImport(LiveKit)
        let track = state.localCameraState == .on ? videoTracks?.localTrack : nil
        TrixVideoSurface(
            track: track,
            title: localVideoTitle,
            systemImage: localVideoSystemImage,
            prominence: .thumbnail
        )
        #else
        TrixVideoSurface(
            title: localVideoTitle,
            systemImage: localVideoSystemImage,
            prominence: .thumbnail
        )
        #endif
    }

    #if canImport(LiveKit)
    private var videoTracks: TrixLiveKitVideoTracks? {
        guard let activeCall else {
            return nil
        }

        return trackRegistry.tracks(for: activeCall.callID)
    }
    #endif

    private var remoteVideoTitle: String {
        switch state.remoteMediaReadiness {
        case .ready:
            return "Remote video"
        case .waiting:
            return "Waiting for remote video"
        case .none:
            return "Remote video unavailable"
        }
    }

    private var remoteVideoSystemImage: String {
        state.remoteMediaReadiness == .none ? "video.slash" : "video"
    }

    private var localVideoTitle: String {
        switch state.localCameraState {
        case .on:
            return "Local preview"
        case .off:
            return "Camera off"
        case .unavailable:
            return "Camera unavailable"
        }
    }

    private var localVideoSystemImage: String {
        state.localCameraState == .on ? "video" : "video.slash"
    }
}

private enum TrixVideoSurfaceProminence {
    case primary
    case thumbnail
}

private struct TrixVideoSurface: View {
    #if canImport(LiveKit)
    let track: VideoTrack?
    #endif
    let title: String
    let systemImage: String
    let prominence: TrixVideoSurfaceProminence

    #if canImport(LiveKit)
    init(
        track: VideoTrack?,
        title: String,
        systemImage: String,
        prominence: TrixVideoSurfaceProminence
    ) {
        self.track = track
        self.title = title
        self.systemImage = systemImage
        self.prominence = prominence
    }
    #else
    init(
        title: String,
        systemImage: String,
        prominence: TrixVideoSurfaceProminence
    ) {
        self.title = title
        self.systemImage = systemImage
        self.prominence = prominence
    }
    #endif

    var body: some View {
        ZStack {
            #if canImport(LiveKit)
            if let track {
                TrixLiveKitVideoTrackView(track: track)
            } else {
                placeholder
            }
            #else
            placeholder
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel(title)
    }

    private var placeholder: some View {
        VStack(spacing: prominence == .primary ? 8 : 4) {
            Image(systemName: systemImage)
                .font(.system(size: prominence == .primary ? 28 : 16, weight: .semibold))
            Text(title)
                .font(prominence == .primary ? .caption.weight(.semibold) : .caption2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.secondary)
        .padding(prominence == .primary ? 14 : 6)
    }

    private var background: Color {
        switch prominence {
        case .primary:
            return Color.black.opacity(0.08)
        case .thumbnail:
            return TrixDesign.primarySurface
        }
    }

    private var cornerRadius: CGFloat {
        switch prominence {
        case .primary:
            return 8
        case .thumbnail:
            return 6
        }
    }
}

#if canImport(LiveKit) && os(iOS)
private struct TrixLiveKitVideoTrackView: UIViewRepresentable {
    let track: VideoTrack

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.isEnabled = true
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        uiView.track = track
        uiView.isEnabled = true
    }
}
#elseif canImport(LiveKit) && os(macOS)
private struct TrixLiveKitVideoTrackView: NSViewRepresentable {
    let track: VideoTrack

    func makeNSView(context: Context) -> VideoView {
        let view = VideoView()
        view.isEnabled = true
        return view
    }

    func updateNSView(_ nsView: VideoView, context: Context) {
        nsView.track = track
        nsView.isEnabled = true
    }
}
#endif
