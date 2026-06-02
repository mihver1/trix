import Foundation

@MainActor
final class TrixProfileViewModel: ObservableObject {
    @Published private(set) var profile: TrixUserProfile?
    @Published private(set) var activity: TrixUserActivity?
    @Published var draftDisplayName = ""
    @Published var draftBio = ""
    @Published var draftStatusMessage = ""
    @Published var draftWebsite = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var didSave = false

    var canSave: Bool {
        guard !isLoading, !isSaving, let profile else {
            return false
        }

        let currentDisplayName = (profile.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let currentBio = (profile.metadata.bio ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let currentStatusMessage = (profile.metadata.statusMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let currentWebsite = (profile.metadata.website ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines) != currentDisplayName ||
            draftBio.trimmingCharacters(in: .whitespacesAndNewlines) != currentBio ||
            draftStatusMessage.trimmingCharacters(in: .whitespacesAndNewlines) != currentStatusMessage ||
            draftWebsite.trimmingCharacters(in: .whitespacesAndNewlines) != currentWebsite
    }

    func load(profile loadProfile: () async throws -> TrixUserProfile) async {
        guard !isLoading else {
            return
        }

        isLoading = true
        activity = nil
        errorMessage = nil
        didSave = false
        defer { isLoading = false }

        do {
            apply(try await loadProfile())
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    func load(
        profile loadProfile: () async throws -> TrixUserProfile,
        activity loadActivity: () async throws -> TrixUserActivity
    ) async {
        guard !isLoading else {
            return
        }

        isLoading = true
        activity = nil
        errorMessage = nil
        didSave = false
        defer { isLoading = false }

        do {
            apply(try await loadProfile())
        } catch {
            errorMessage = error.trixUserFacingMessage
            return
        }

        do {
            activity = try await loadActivity()
        } catch {
            activity = .unknown
        }
    }

    func save(updateProfile: (TrixUserProfileUpdate) async throws -> TrixUserProfile) async {
        guard canSave else {
            return
        }

        isSaving = true
        errorMessage = nil
        didSave = false
        defer { isSaving = false }

        do {
            apply(try await updateProfile(TrixUserProfileUpdate(
                displayName: draftDisplayName,
                bio: draftBio,
                statusMessage: draftStatusMessage,
                website: draftWebsite
            )))
            didSave = true
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    func resetSavedState() {
        didSave = false
    }

    private func apply(_ profile: TrixUserProfile) {
        self.profile = profile
        self.draftDisplayName = profile.displayName ?? ""
        self.draftBio = profile.metadata.bio ?? ""
        self.draftStatusMessage = profile.metadata.statusMessage ?? ""
        self.draftWebsite = profile.metadata.website ?? ""
    }
}
