import SwiftUI

func formattedUptime(_ uptimeMs: UInt64) -> String {
    let seconds = Int(uptimeMs / 1000)
    if seconds < 60 {
        return "\(seconds)s"
    }

    let minutes = seconds / 60
    if minutes < 60 {
        return "\(minutes)m"
    }

    let hours = minutes / 60
    let remainderMinutes = minutes % 60
    return "\(hours)h \(remainderMinutes)m"
}

func localizedPendingOutgoingError(_ rawValue: String) -> String {
    TrixUserFacingText.sanitize(rawMessage: rawValue)
}
