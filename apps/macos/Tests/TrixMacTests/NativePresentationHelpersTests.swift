import Testing
@testable import TrixMac

@Test
func formattedUptimeRendersSecondsForShortDurations() {
    #expect(formattedUptime(45_000) == "45s")
}

@Test
func formattedUptimeRendersMinutesForMidDurations() {
    #expect(formattedUptime(3 * 60 * 1_000) == "3m")
}

@Test
func formattedUptimeRendersHoursAndMinutesForLongDurations() {
    #expect(formattedUptime(((2 * 60 * 60) + (5 * 60)) * 1_000) == "2h 5m")
}

@Test
func localizedPendingOutgoingErrorNormalizesTransportAndMlsFailures() {
    #expect(
        localizedPendingOutgoingError("MLS epoch mismatch in conversation state")
            == "Couldn't send this message right now. Try again in a moment."
    )
}

@Test
func localizedPendingOutgoingErrorPreservesOtherErrors() {
    #expect(localizedPendingOutgoingError("Request timed out") == "Request timed out")
}
