import SwiftUI

enum TrixRoomSearch {
    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matchingRooms(
        _ rooms: [TrixRoomSummary],
        query: String,
        directoryResults: [TrixUserProfile]
    ) -> [TrixRoomSummary] {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty else {
            return rooms
        }

        let matchedDirectoryUserIDs = Set(directoryResults.map { $0.userID.lowercased() })
        return rooms.filter { room in
            room.name.localizedCaseInsensitiveContains(needle) ||
                room.id.localizedCaseInsensitiveContains(needle) ||
                (room.kind == .direct && matchedDirectoryUserIDs.contains(room.id.lowercased()))
        }
    }

    static func peopleResults(
        _ profiles: [TrixUserProfile],
        query: String,
        rooms: [TrixRoomSummary],
        currentUserID: String?
    ) -> [TrixUserProfile] {
        guard !normalizedQuery(query).isEmpty else {
            return []
        }

        let existingDirectRoomIDs = Set(
            rooms
                .filter { $0.kind == .direct }
                .map { $0.id.lowercased() }
        )
        let currentUserKey = currentUserID?.lowercased()
        var seen = Set<String>()
        return profiles.filter { profile in
            let key = profile.userID.lowercased()
            guard key != currentUserKey,
                  !existingDirectRoomIDs.contains(key),
                  seen.insert(key).inserted else {
                return false
            }

            return true
        }
    }
}

struct TrixRoomSearchField: View {
    @Binding var query: String
    let isSearching: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search chats or people", text: $query)
                .trixDirectorySearchInput()

            if isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
    }
}

struct TrixRoomDirectoryUserSearchRow: View {
    let profile: TrixUserProfile
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 10) {
            TrixAvatarView(
                title: profile.title,
                systemImage: "person.fill",
                size: 34
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
            }

            Spacer(minLength: 8)

            if isWorking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "message.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TrixDesign.accent)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .accessibilityLabel("Start chat with \(profile.title)")
    }
}
