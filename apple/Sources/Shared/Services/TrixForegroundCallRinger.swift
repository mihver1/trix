import Foundation

#if os(iOS)
import AudioToolbox
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
enum TrixForegroundCallRinger {
    private static var lastPlayedIncomingCallID: String?

    static func playIfNeeded(_ cue: TrixCallForegroundCue) {
        guard case .incomingDirectCall(let callID) = cue,
              lastPlayedIncomingCallID != callID else {
            return
        }

        lastPlayedIncomingCallID = callID
        playIncomingDirectCallCue()
    }

    private static func playIncomingDirectCallCue() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlayAlertSound(1007)
        #elseif os(macOS)
        NSSound(named: NSSound.Name("Glass"))?.play()
        #endif
    }
}
