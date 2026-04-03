import Foundation

enum TrixUserFacingText {
    static func errorMessage(_ error: Error) -> String {
        sanitize(rawMessage: rawDescription(error))
    }

    static func conversationMessage(
        _ error: Error,
        chatId: String?,
        historySyncJobs: [HistorySyncJobSummary]
    ) -> String {
        sanitize(
            rawMessage: rawDescription(error),
            chatId: chatId,
            historySyncJobs: historySyncJobs
        )
    }

    static func sanitize(
        rawMessage: String?,
        chatId: String? = nil,
        historySyncJobs: [HistorySyncJobSummary] = []
    ) -> String {
        guard let trimmed = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return TrixStrings.text(.chatErrorGenericTryAgain)
        }

        let normalized = trimmed.lowercased()
        if isUnavailableContentMessage(normalized) {
            if let chatId, hasActiveBackfill(chatId: chatId, historySyncJobs: historySyncJobs) {
                return TrixStrings.text(.chatPreviewBackfillQueued)
            }
            return TrixStrings.text(.chatPreviewLoadingOnDevice)
        }

        if normalized.contains("epoch") ||
            normalized.contains("mls") ||
            normalized.contains("projected") ||
            normalized.contains("group state") ||
            normalized.contains("conversation material") {
            return TrixStrings.text(.chatErrorSendRetry)
        }

        if normalized.contains("ffimessengererror") ||
            normalized.contains("trixffierror") ||
            normalized.contains("panic") {
            return TrixStrings.text(.chatErrorGenericTryAgain)
        }

        return trimmed
    }

    private static func rawDescription(_ error: Error) -> String? {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }

        let localizedDescription = error.localizedDescription
        return localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : localizedDescription
    }

    private static func hasActiveBackfill(
        chatId: String,
        historySyncJobs: [HistorySyncJobSummary]
    ) -> Bool {
        historySyncJobs.contains { job in
            job.chatId == chatId &&
                job.jobType == .chatBackfill &&
                (job.jobStatus == .pending || job.jobStatus == .running)
        }
    }

    private static func isUnavailableContentMessage(_ normalized: String) -> Bool {
        normalized.contains("unavailable on this device") ||
            normalized.contains("content is unavailable") ||
            normalized.contains("backfill queued")
    }
}

extension Error {
    var trixUserFacingMessage: String {
        TrixUserFacingText.errorMessage(self)
    }
}
