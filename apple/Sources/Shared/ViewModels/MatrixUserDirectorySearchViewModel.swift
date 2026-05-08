import Foundation

@MainActor
final class MatrixUserDirectorySearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [MatrixUserProfile] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isLimited = false
    @Published private(set) var errorMessage: String?

    func search(
        excluding excludedUserIDs: Set<String>,
        limit: Int = 20,
        searchUsers: (String, Int) async throws -> MatrixUserSearchResult
    ) async {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            clearResults()
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            let searchResult = try await searchUsers(normalizedQuery, limit)
            guard !Task.isCancelled else {
                return
            }

            let excluded = Set(excludedUserIDs.map { $0.lowercased() })
            results = searchResult.users.filter { profile in
                !excluded.contains(profile.userID.lowercased())
            }
            isLimited = searchResult.limited
        } catch {
            guard !Task.isCancelled else {
                return
            }

            results = []
            isLimited = false
            errorMessage = error.matrixUserFacingMessage
        }
    }

    func clearResults() {
        results = []
        isSearching = false
        isLimited = false
        errorMessage = nil
    }
}
