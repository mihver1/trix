import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#endif

#if os(macOS)
let TrixActiveCallWindowID = "trix-active-call"
#endif

enum TrixActiveCallSurfacePlacement {
    case workspace
    case utilityWindow
}

@MainActor
struct TrixActiveCallPresentation: Equatable, Identifiable {
    enum Mode: Equatable {
        case incomingDirect(TrixIncomingDirectCall)
        case active
        case outgoing
    }

    let id: String
    let mode: Mode
    let roomID: String
    let roomName: String
    let roomKind: TrixRoomKind
    let state: TrixCallLifecycleState

    @MainActor
    static func presentation(model: TrixAppModel) -> TrixActiveCallPresentation? {
        if let incomingCall = model.callViewModel.incomingDirectCallsByRoomID
            .sorted(by: { $0.key < $1.key })
            .first?
            .value {
            let state = model.callViewModel.callLifecycleState(roomID: incomingCall.roomID)
            return TrixActiveCallPresentation(
                id: "incoming-\(incomingCall.callID)",
                mode: .incomingDirect(incomingCall),
                roomID: incomingCall.roomID,
                roomName: roomName(roomID: incomingCall.roomID, model: model),
                roomKind: roomKind(roomID: incomingCall.roomID, model: model),
                state: state
            )
        }

        if let activeRoomID = model.callViewModel.activeRoomID {
            let state = model.callViewModel.callLifecycleState(roomID: activeRoomID)
            return TrixActiveCallPresentation(
                id: "active-\(state.callID ?? activeRoomID)",
                mode: .active,
                roomID: activeRoomID,
                roomName: roomName(roomID: activeRoomID, model: model),
                roomKind: roomKind(roomID: activeRoomID, model: model),
                state: state
            )
        }

        if let preparedCall = model.callViewModel.preparedCall {
            let state = model.callViewModel.callLifecycleState(roomID: preparedCall.roomID)
            return TrixActiveCallPresentation(
                id: "outgoing-\(preparedCall.authorization.callID)",
                mode: .outgoing,
                roomID: preparedCall.roomID,
                roomName: roomName(roomID: preparedCall.roomID, model: model),
                roomKind: roomKind(roomID: preparedCall.roomID, model: model),
                state: state
            )
        }

        return nil
    }

    @MainActor
    private static func roomName(roomID: String, model: TrixAppModel) -> String {
        model.roomListViewModel.rooms.first { $0.id == roomID }?.name ?? roomID
    }

    @MainActor
    private static func roomKind(roomID: String, model: TrixAppModel) -> TrixRoomKind {
        model.roomListViewModel.rooms.first { $0.id == roomID }?.kind ?? .direct
    }
}

struct TrixActiveCallSurfaceHost: View {
    @ObservedObject var model: TrixAppModel
    @ObservedObject private var callViewModel: TrixCallViewModel
    let placement: TrixActiveCallSurfacePlacement

    init(model: TrixAppModel, placement: TrixActiveCallSurfacePlacement) {
        self.model = model
        self.placement = placement
        self._callViewModel = ObservedObject(wrappedValue: model.callViewModel)
    }

    var body: some View {
        if callViewModel.errorMessage != nil || presentation != nil {
            VStack(spacing: 0) {
                if let errorMessage = callViewModel.errorMessage {
                    TrixBannerView(
                        text: errorMessage,
                        systemImage: "phone.connection",
                        tint: .orange,
                        dismissAction: {
                            callViewModel.dismissErrorMessage()
                        }
                    )
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, presentation == nil ? 8 : 4)
                }

                if let presentation {
                    TrixActiveCallBar(
                        model: model,
                        presentation: presentation,
                        placement: placement
                    )
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, callViewModel.errorMessage == nil ? 8 : 4)
                    .padding(.bottom, 8)
                }
            }
            .background {
                if placement == .workspace {
                    Rectangle()
                        .fill(.regularMaterial)
                }
            }
            .onAppear {
                TrixForegroundCallRinger.playIfNeeded(presentation?.state.foregroundCue ?? .none)
            }
            .onChange(of: presentation?.state.foregroundCue ?? .none) { _, cue in
                TrixForegroundCallRinger.playIfNeeded(cue)
            }
        }
    }

    private var presentation: TrixActiveCallPresentation? {
        TrixActiveCallPresentation.presentation(model: model)
    }

    private var horizontalPadding: CGFloat {
        switch placement {
        case .workspace:
            return 12
        case .utilityWindow:
            return 0
        }
    }
}

private struct TrixActiveCallBar: View {
    @ObservedObject var model: TrixAppModel
    let presentation: TrixActiveCallPresentation
    let placement: TrixActiveCallSurfacePlacement
    @ObservedObject private var audioLevelRegistry = TrixCallAudioLevelRegistry.shared
    @ObservedObject private var mediaQualityRegistry = TrixCallMediaQualityRegistry.shared

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 32, height: 32)
                        .background(tint.opacity(0.13), in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.roomName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        Text(statusText(now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    controls
                }

                TrixCallMediaQualityStrip(state: presentation.state, tint: tint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(barBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if placement == .workspace {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(now: context.date))
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch presentation.mode {
        case .incomingDirect(let incomingCall):
            HStack(spacing: 8) {
                Button {
                    Task {
                        await model.acceptIncomingDirectCall(incomingCall)
                    }
                } label: {
                    Label("Accept", systemImage: "phone.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.callViewModel.isActing(roomID: presentation.roomID))

                Button(role: .destructive) {
                    Task {
                        await model.declineIncomingDirectCall(incomingCall)
                    }
                } label: {
                    Label("Decline", systemImage: "phone.down.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.callViewModel.isActing(roomID: presentation.roomID))
            }
        case .active, .outgoing:
            HStack(spacing: 6) {
                Button {
                    Task {
                        await model.setCallMicrophoneMuted(
                            presentation.state.localAudioState != .muted,
                            roomID: presentation.roomID
                        )
                    }
                } label: {
                    TrixMicrophoneButtonContent(
                        audioState: presentation.state.localAudioState,
                        callID: presentation.state.callID,
                        tint: tint
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isWorking || presentation.state.localAudioState == .unavailable)
                .help(microphoneHelp)
                .accessibilityLabel(microphoneHelp)

                if presentation.state.kind == .directVideo {
                    Button {
                        Task {
                            await model.setCallCameraEnabled(
                                presentation.state.localCameraState != .on,
                                roomID: presentation.roomID
                            )
                        }
                    } label: {
                        Image(systemName: presentation.state.localCameraState == .on ? "video.fill" : "video.slash.fill")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking || presentation.state.localCameraState == .unavailable)
                    .help(cameraHelp)
                    .accessibilityLabel(cameraHelp)
                }

                Button(role: .destructive) {
                    Task {
                        await model.leaveCall(roomID: presentation.roomID)
                    }
                } label: {
                    Label("End", systemImage: "phone.down.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isWorking)
                .help("End")
                .accessibilityLabel("End call")
            }
            .controlSize(.small)
        }
    }

    private var isWorking: Bool {
        presentation.state.isActing || model.callViewModel.isActing(roomID: presentation.roomID)
    }

    private var microphoneHelp: String {
        switch presentation.state.localAudioState {
        case .unavailable:
            return "Microphone unavailable or permission denied"
        case .muted:
            return "Unmute microphone"
        case .unmuted:
            return "Mute microphone"
        }
    }

    private var cameraHelp: String {
        switch presentation.state.localCameraState {
        case .unavailable:
            return "Camera unavailable or permission denied"
        case .off:
            return "Turn camera on"
        case .on:
            return "Turn camera off"
        }
    }

    private var barBackground: Color {
        switch placement {
        case .workspace:
            return TrixDesign.primarySurface
        case .utilityWindow:
            return TrixDesign.elevatedFieldSurface
        }
    }

    private var cornerRadius: CGFloat {
        switch placement {
        case .workspace:
            return 8
        case .utilityWindow:
            return 14
        }
    }

    private var tint: Color {
        switch presentation.mode {
        case .incomingDirect:
            return Color.orange
        case .active, .outgoing:
            return presentation.roomKind.tint
        }
    }

    private var systemImage: String {
        switch presentation.mode {
        case .incomingDirect:
            return "phone.down.waves.left.and.right"
        case .active, .outgoing:
            return presentation.state.kind == .groupVoice ? "waveform" : "phone.fill"
        }
    }

    private func statusText(now: Date) -> String {
        let scope = presentation.state.kind == .groupVoice ? "Encrypted group voice" : "Encrypted direct call"
        let parts = [
            scope,
            phaseText(now: now),
            localAudioText(now: now),
            remoteMediaText,
        ].compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return parts.joined(separator: " · ")
    }

    private func accessibilityLabel(now: Date) -> String {
        "\(presentation.roomName), \(statusText(now: now))"
    }

    private func phaseText(now: Date) -> String {
        switch presentation.state.phase {
        case .incomingRinging:
            if let expiresAt = presentation.state.expiresAt {
                return "expires in \(durationText(from: now, to: expiresAt))"
            }
            return "incoming"
        case .outgoingRinging:
            return "ringing"
        case .connecting:
            return "connecting"
        case .active:
            if let startedAt = presentation.state.startedAt {
                return durationText(from: startedAt, to: now)
            }
            return "active"
        case .reconnecting:
            return "reconnecting"
        case .ending:
            return "ending"
        case .idle, .outgoingPreparing, .ended, .failed:
            return presentation.state.phase.rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func localAudioText(now: Date) -> String {
        switch audioLevelRegistry.localInputSignalState(
            callID: presentation.state.callID,
            audioState: presentation.state.localAudioState,
            startedAt: presentation.state.startedAt,
            now: now
        ) {
        case .unavailable:
            return "Mic unavailable"
        case .muted:
            return "Mic muted"
        case .detecting:
            return "Checking mic"
        case .active:
            return "Mic input ok"
        case .low:
            return "Low mic input"
        }
    }

    private var remoteMediaText: String {
        guard presentation.state.phase.isActiveLike || presentation.state.phase == .connecting else {
            return ""
        }

        let snapshot = mediaQualityRegistry.snapshot(for: presentation.state.callID)
        if presentation.state.kind == .groupVoice {
            return remoteAudioText(snapshot.remoteAudioStatus)
        }

        switch snapshot.remoteVideoStatus {
        case .receiving:
            return "Remote video ok"
        case .waiting:
            return "Waiting for video"
        case .muted:
            return "Remote camera off"
        case .paused:
            return "Video paused"
        case .unavailable:
            return remoteAudioText(snapshot.remoteAudioStatus)
        }
    }

    private func remoteAudioText(_ status: TrixCallMediaSignalStatus) -> String {
        switch status {
        case .receiving:
            return "Remote audio ok"
        case .waiting:
            return "Waiting for audio"
        case .muted:
            return "Remote muted"
        case .paused:
            return "Audio paused"
        case .unavailable:
            return ""
        }
    }

    private func durationText(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60

        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remainingSeconds))"
        }

        return "\(minutes):\(String(format: "%02d", remainingSeconds))"
    }
}

struct TrixCallMediaQualityStrip: View {
    let state: TrixCallLifecycleState
    let tint: Color
    @ObservedObject private var audioLevelRegistry = TrixCallAudioLevelRegistry.shared
    @ObservedObject private var mediaQualityRegistry = TrixCallMediaQualityRegistry.shared

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let items = qualityItems(now: context.date)
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(items) { item in
                            TrixCallMediaQualityChip(item: item)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(items.map(\.label).joined(separator: ", "))
            }
        }
    }

    private func qualityItems(now: Date) -> [TrixCallMediaQualityItem] {
        guard state.phase.isActiveLike || state.phase == .connecting else {
            return []
        }

        let snapshot = mediaQualityRegistry.snapshot(for: state.callID)
        var items: [TrixCallMediaQualityItem] = [
            localInputItem(now: now),
            e2eeItem,
        ]

        if snapshot.relayOnly {
            items.append(TrixCallMediaQualityItem(
                id: "relay",
                label: "Relay-only",
                systemImage: "network",
                tint: .blue
            ))
        }

        if let remoteAudioItem = remoteAudioItem(snapshot.remoteAudioStatus) {
            items.append(remoteAudioItem)
        }

        if state.kind == .directVideo,
           let remoteVideoItem = remoteVideoItem(snapshot.remoteVideoStatus) {
            items.append(remoteVideoItem)
        }

        return items
    }

    private func localInputItem(now: Date) -> TrixCallMediaQualityItem {
        switch audioLevelRegistry.localInputSignalState(
            callID: state.callID,
            audioState: state.localAudioState,
            startedAt: state.startedAt,
            now: now
        ) {
        case .unavailable:
            return TrixCallMediaQualityItem(
                id: "mic-unavailable",
                label: "Mic unavailable",
                systemImage: "mic.slash.fill",
                tint: .orange
            )
        case .muted:
            return TrixCallMediaQualityItem(
                id: "mic-muted",
                label: "Muted",
                systemImage: "mic.slash.fill",
                tint: .secondary
            )
        case .detecting:
            return TrixCallMediaQualityItem(
                id: "mic-detecting",
                label: "Checking mic",
                systemImage: "waveform",
                tint: .secondary
            )
        case .active:
            return TrixCallMediaQualityItem(
                id: "mic-active",
                label: "Mic input",
                systemImage: "mic.fill",
                tint: tint
            )
        case .low:
            return TrixCallMediaQualityItem(
                id: "mic-low",
                label: "Low mic input",
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
    }

    private var e2eeItem: TrixCallMediaQualityItem {
        switch state.e2eeState {
        case .active:
            return TrixCallMediaQualityItem(
                id: "e2ee-active",
                label: "Media E2EE",
                systemImage: "lock.fill",
                tint: .green
            )
        case .required:
            return TrixCallMediaQualityItem(
                id: "e2ee-required",
                label: "E2EE setup",
                systemImage: "lock.fill",
                tint: .orange
            )
        case .failed:
            return TrixCallMediaQualityItem(
                id: "e2ee-failed",
                label: "E2EE failed",
                systemImage: "lock.slash.fill",
                tint: .red
            )
        case .none:
            return TrixCallMediaQualityItem(
                id: "e2ee-none",
                label: "No media E2EE",
                systemImage: "lock.slash",
                tint: .secondary
            )
        }
    }

    private func remoteAudioItem(_ status: TrixCallMediaSignalStatus) -> TrixCallMediaQualityItem? {
        switch status {
        case .unavailable:
            return nil
        case .waiting:
            return TrixCallMediaQualityItem(
                id: "remote-audio-waiting",
                label: "Waiting audio",
                systemImage: "speaker.wave.2.fill",
                tint: .orange
            )
        case .receiving:
            return TrixCallMediaQualityItem(
                id: "remote-audio-receiving",
                label: "Audio receiving",
                systemImage: "speaker.wave.2.fill",
                tint: .green
            )
        case .muted:
            return TrixCallMediaQualityItem(
                id: "remote-audio-muted",
                label: "Remote muted",
                systemImage: "speaker.slash.fill",
                tint: .secondary
            )
        case .paused:
            return TrixCallMediaQualityItem(
                id: "remote-audio-paused",
                label: "Audio paused",
                systemImage: "pause.circle.fill",
                tint: .orange
            )
        }
    }

    private func remoteVideoItem(_ status: TrixCallMediaSignalStatus) -> TrixCallMediaQualityItem? {
        switch status {
        case .unavailable:
            return nil
        case .waiting:
            return TrixCallMediaQualityItem(
                id: "remote-video-waiting",
                label: "Waiting video",
                systemImage: "video.fill",
                tint: .orange
            )
        case .receiving:
            return TrixCallMediaQualityItem(
                id: "remote-video-receiving",
                label: "Video receiving",
                systemImage: "video.fill",
                tint: .green
            )
        case .muted:
            return TrixCallMediaQualityItem(
                id: "remote-video-muted",
                label: "Camera off",
                systemImage: "video.slash.fill",
                tint: .secondary
            )
        case .paused:
            return TrixCallMediaQualityItem(
                id: "remote-video-paused",
                label: "Video paused",
                systemImage: "pause.circle.fill",
                tint: .orange
            )
        }
    }
}

private struct TrixCallMediaQualityItem: Identifiable {
    let id: String
    let label: String
    let systemImage: String
    let tint: Color
}

private struct TrixCallMediaQualityChip: View {
    let item: TrixCallMediaQualityItem

    var body: some View {
        Label(item.label, systemImage: item.systemImage)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .foregroundStyle(item.tint)
            .background(item.tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(item.tint.opacity(0.22), lineWidth: 1)
            }
    }
}

struct TrixMicrophoneButtonContent: View {
    let audioState: TrixCallLocalAudioState
    let callID: String?
    let tint: Color
    @ObservedObject private var audioLevelRegistry = TrixCallAudioLevelRegistry.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(systemName: audioState == .muted ? "mic.slash.fill" : "mic.fill")
                .frame(width: 30, height: 30)

            if audioState == .unmuted {
                TrixMicrophoneLevelMeter(level: audioLevel, tint: tint)
                    .frame(width: 18, height: 8)
                    .padding(.bottom, 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 30, height: 30)
    }

    private var audioLevel: Double {
        audioLevelRegistry.level(for: callID)
    }
}

private struct TrixMicrophoneLevelMeter: View {
    let level: Double
    let tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint.opacity(opacity(for: index)))
                    .frame(width: 2.5, height: height(for: index))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        let thresholds = [0.04, 0.18, 0.36, 0.58]
        let threshold = thresholds[index]
        let normalized = min(max((level - threshold) / 0.36, 0), 1)
        return 2 + CGFloat(normalized) * 6
    }

    private func opacity(for index: Int) -> Double {
        let thresholds = [0.04, 0.18, 0.36, 0.58]
        return level >= thresholds[index] ? 0.95 : 0.28
    }
}

#if os(macOS)
struct TrixMacActiveCallWindow: View {
    @ObservedObject var model: TrixAppModel
    @ObservedObject private var callViewModel: TrixCallViewModel

    init(model: TrixAppModel) {
        self.model = model
        self._callViewModel = ObservedObject(wrappedValue: model.callViewModel)
    }

    var body: some View {
        Group {
            if TrixActiveCallPresentation.presentation(model: model) != nil || callViewModel.errorMessage != nil {
                TrixActiveCallSurfaceHost(model: model, placement: .utilityWindow)
                    .padding(10)
                    .frame(width: 430)
            } else {
                EmptyView()
                    .frame(width: 1, height: 1)
            }
        }
        .background(TrixActiveCallWindowConfigurator())
    }
}

private struct TrixActiveCallWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureSoon(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureSoon(from: nsView)
    }

    private func configureSoon(from view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else {
                return
            }

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.titled)
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}
#endif
