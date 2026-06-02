import SwiftUI

enum TrixUserDirectorySelectionMode {
    case single
    case multiple
}

struct TrixUserDirectoryPickerView: View {
    @ObservedObject var model: TrixAppModel
    @Binding var selection: [TrixUserProfile]
    let mode: TrixUserDirectorySelectionMode
    var excludedUserIDs: Set<String> = []
    @StateObject private var searchViewModel = TrixUserDirectorySearchViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search people or enter handle", text: $searchViewModel.query)
                    .trixDirectorySearchInput()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
            }

            if !selection.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(selection) { profile in
                        TrixSelectedDirectoryUserRow(profile: profile) {
                            remove(profile)
                        }
                    }
                }
            }

            if searchViewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            ForEach(availableResults) { profile in
                Button {
                    select(profile)
                } label: {
                    TrixDirectoryUserRow(profile: profile, systemImage: "plus.circle.fill")
                }
                .buttonStyle(.plain)
            }

            if let errorMessage = searchViewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if shouldShowNoMatches {
                Text("No matches")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if searchViewModel.isLimited {
                Text("More matches available")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: searchViewModel.query) {
            await searchViewModel.search(
                excluding: excludedUserIDs.union(selection.map(\.userID)),
                searchUsers: { query, limit in
                    try await model.searchUsers(query, limit: limit)
                }
            )
        }
    }

    private var availableResults: [TrixUserProfile] {
        let excluded = Set(excludedUserIDs.union(selection.map(\.userID)).map { $0.lowercased() })
        return searchViewModel.results.filter { profile in
            !excluded.contains(profile.userID.lowercased())
        }
    }

    private var shouldShowNoMatches: Bool {
        !searchViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            selection.isEmpty &&
            !searchViewModel.isSearching &&
            availableResults.isEmpty &&
            searchViewModel.errorMessage == nil
    }

    private func select(_ profile: TrixUserProfile) {
        switch mode {
        case .single:
            selection = [profile]
        case .multiple:
            guard !selection.contains(where: { $0.userID.caseInsensitiveCompare(profile.userID) == .orderedSame }) else {
                return
            }
            selection.append(profile)
        }
    }

    private func remove(_ profile: TrixUserProfile) {
        selection.removeAll { $0.userID.caseInsensitiveCompare(profile.userID) == .orderedSame }
    }
}

private struct TrixDirectoryUserRow: View {
    let profile: TrixUserProfile
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            TrixAvatarView(
                title: profile.title,
                systemImage: "person.fill",
                size: 32,
                avatarURL: profile.avatarURL
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(profile.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let bio = profile.metadata.bio {
                    Text(bio)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(TrixDesign.accent)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

private struct TrixSelectedDirectoryUserRow: View {
    let profile: TrixUserProfile
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TrixDirectoryUserRow(profile: profile, systemImage: "checkmark.circle.fill")

            Button {
                remove()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(profile.title)")
        }
    }
}

extension View {
    @ViewBuilder
    func trixDirectorySearchInput() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.username)
        #else
        self
            .autocorrectionDisabled()
            .textContentType(.username)
        #endif
    }
}
