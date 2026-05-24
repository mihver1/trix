import Foundation
import SwiftUI

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
            .background(.regularMaterial)
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

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
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
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TrixDesign.primarySurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
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
            Button(role: .destructive) {
                Task {
                    await model.leaveCall(roomID: presentation.roomID)
                }
            } label: {
                Label("End", systemImage: "phone.down.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.callViewModel.isActing(roomID: presentation.roomID))
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
        let phase = phaseText(now: now)
        let audio = audioText
        return "\(scope) · \(phase) · \(audio)"
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

    private var audioText: String {
        switch presentation.state.localAudioState {
        case .muted:
            return "Mic muted"
        case .unmuted:
            return "Mic on"
        case .unavailable:
            return "Mic unavailable"
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

#if os(macOS)
struct TrixMacActiveCallWindow: View {
    @ObservedObject var model: TrixAppModel
    @ObservedObject private var callViewModel: TrixCallViewModel

    init(model: TrixAppModel) {
        self.model = model
        self._callViewModel = ObservedObject(wrappedValue: model.callViewModel)
    }

    var body: some View {
        VStack(spacing: 12) {
            if TrixActiveCallPresentation.presentation(model: model) == nil,
               callViewModel.errorMessage == nil {
                ContentUnavailableView(
                    "No Active Call",
                    systemImage: "phone",
                    description: Text("Active encrypted calls appear here while the main window is hidden or minimized.")
                )
            } else {
                TrixActiveCallSurfaceHost(model: model, placement: .utilityWindow)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(TrixDesign.screenBackground)
    }
}
#endif
