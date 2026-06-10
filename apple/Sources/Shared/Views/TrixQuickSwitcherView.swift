#if os(macOS)
import SwiftUI

/// Cmd+K quick switcher: fuzzy search over the chat list with a user
/// directory fallback for starting new DMs. Fully keyboard-driven: Up/Down
/// move the selection, Return opens it, Escape closes the sheet.
struct TrixQuickSwitcherView: View {
    @ObservedObject var model: TrixAppModel
    @ObservedObject private var roomListViewModel: RoomListViewModel
    @StateObject private var directorySearchViewModel = TrixUserDirectorySearchViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var selectedResultID: String?
    @State private var pendingDirectChatUserID: String?
    @State private var showsDirectChatError = false
    @FocusState private var isSearchFieldFocused: Bool

    private static let maxVisibleRooms = 10
    private static let maxVisiblePeople = 6
    /// Directory people are offered when the query matches fewer rooms than this.
    private static let directoryFallbackRoomThreshold = 5

    init(model: TrixAppModel) {
        self.model = model
        self._roomListViewModel = ObservedObject(wrappedValue: model.roomListViewModel)
    }

    var body: some View {
        // One fuzzy-ranking pass per render: the section partition and the
        // selection highlight all reuse this snapshot instead of re-ranking
        // the room list on every derived-property access.
        let results = self.results
        let selectedID = selectedResult(in: results)?.id

        VStack(spacing: 0) {
            searchField
                .padding(12)

            Divider()

            resultsList(results: results, selectedID: selectedID)

            Divider()

            footer
        }
        .frame(width: 560, height: 440)
        .background(TrixDesign.screenBackground)
        .tint(TrixDesign.accent)
        .onExitCommand {
            dismiss()
        }
        .defaultFocus($isSearchFieldFocused, true)
        .onAppear {
            isSearchFieldFocused = true
        }
        .onChange(of: directorySearchViewModel.query) { _, _ in
            selectedResultID = nil
            showsDirectChatError = false
        }
        .task(id: directorySearchViewModel.query) {
            await directorySearchViewModel.search(
                excluding: searchExcludedUserIDs,
                limit: 20,
                searchUsers: { query, limit in
                    try await model.searchUsers(query, limit: limit)
                }
            )
        }
    }

    // MARK: - Subviews

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search chats or people", text: $directorySearchViewModel.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .trixDirectorySearchInput()
                .focused($isSearchFieldFocused)
                .onSubmit(activateSelection)
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
                    moveSelection(by: -1)
                }
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
                    moveSelection(by: 1)
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    dismiss()
                    return .handled
                }

            if directorySearchViewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !normalizedQuery.isEmpty {
                Button {
                    directorySearchViewModel.query = ""
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

    private func resultsList(
        results: [TrixQuickSwitcherResult],
        selectedID: String?
    ) -> some View {
        let roomResults = results.filter { result in
            if case .room = result { return true }
            return false
        }
        let personResults = results.filter { result in
            if case .person = result { return true }
            return false
        }

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if results.isEmpty {
                        emptyState
                    } else {
                        if !roomResults.isEmpty {
                            sectionHeader("Chats")
                            ForEach(roomResults) { result in
                                resultButton(result, isSelected: result.id == selectedID)
                            }
                        }

                        if !personResults.isEmpty {
                            sectionHeader("People")
                            ForEach(personResults) { result in
                                resultButton(result, isSelected: result.id == selectedID)
                            }
                        }
                    }

                    if let errorMessage = visibleErrorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .padding(.top, 6)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: selectedResultID) { _, newValue in
                guard let newValue else {
                    return
                }

                proxy.scrollTo(newValue)
            }
        }
    }

    @ViewBuilder
    private func resultButton(_ result: TrixQuickSwitcherResult, isSelected: Bool) -> some View {
        Button {
            activate(result)
        } label: {
            Group {
                switch result {
                case .room(let room):
                    TrixQuickSwitcherRoomRow(
                        room: room,
                        isMarkedUnread: roomListViewModel.isMarkedUnread(roomID: room.id)
                    )
                case .person(let profile):
                    TrixRoomDirectoryUserSearchRow(
                        profile: profile,
                        isWorking: isStartingDirectChat(with: profile)
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? TrixDesign.accent.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(result.id)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if normalizedQuery.isEmpty {
                Text("No chats yet")
            } else if directorySearchViewModel.isSearching {
                Text("Searching…")
            } else {
                Text("No matches")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            footerHint(symbol: "arrow.up.arrow.down", text: "Navigate")
            footerHint(symbol: "return", text: "Open")
            footerHint(symbol: "escape", text: "Close")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func footerHint(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - Results

    private var normalizedQuery: String {
        TrixRoomSearch.normalizedQuery(directorySearchViewModel.query)
    }

    private var matchedRooms: [TrixRoomSummary] {
        let rooms = roomListViewModel.sortedRooms
        guard !normalizedQuery.isEmpty else {
            return Array(rooms.prefix(Self.maxVisibleRooms))
        }

        let rankedRooms = TrixFuzzyMatcher.ranked(rooms, query: normalizedQuery) { room in
            [room.name, TrixUserIdentity.handle(from: room.id)]
        }
        return Array(rankedRooms.prefix(Self.maxVisibleRooms))
    }

    private func visiblePeople(matchedRoomCount: Int) -> [TrixUserProfile] {
        guard !normalizedQuery.isEmpty,
              matchedRoomCount < Self.directoryFallbackRoomThreshold else {
            return []
        }

        let people = TrixRoomSearch.peopleResults(
            directorySearchViewModel.results,
            query: directorySearchViewModel.query,
            rooms: roomListViewModel.rooms,
            currentUserID: model.session?.userID
        )
        return Array(people.prefix(Self.maxVisiblePeople))
    }

    /// Single source for the result list; ranks the rooms exactly once and
    /// derives the people fallback from that same pass.
    private var results: [TrixQuickSwitcherResult] {
        let rooms = matchedRooms
        let people = visiblePeople(matchedRoomCount: rooms.count)
        return rooms.map(TrixQuickSwitcherResult.room) +
            people.map(TrixQuickSwitcherResult.person)
    }

    private func selectedResult(
        in results: [TrixQuickSwitcherResult]
    ) -> TrixQuickSwitcherResult? {
        if let selectedResultID,
           let selected = results.first(where: { $0.id == selectedResultID }) {
            return selected
        }

        return results.first
    }

    private var visibleErrorMessage: String? {
        if let directoryError = directorySearchViewModel.errorMessage {
            return directoryError
        }

        guard showsDirectChatError else {
            return nil
        }

        return roomListViewModel.errorMessage
    }

    private var searchExcludedUserIDs: Set<String> {
        guard let userID = model.session?.userID else {
            return []
        }

        return [userID]
    }

    // MARK: - Actions

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        let results = self.results
        guard !results.isEmpty else {
            return .ignored
        }

        let selectedID = selectedResult(in: results)?.id
        let currentIndex = results.firstIndex { $0.id == selectedID } ?? 0
        let nextIndex = (currentIndex + delta + results.count) % results.count
        selectedResultID = results[nextIndex].id
        return .handled
    }

    private func activateSelection() {
        guard let selected = selectedResult(in: results) else {
            return
        }

        activate(selected)
    }

    private func activate(_ result: TrixQuickSwitcherResult) {
        guard pendingDirectChatUserID == nil else {
            return
        }

        switch result {
        case .room(let room):
            model.openRoomFromKeyboardNavigation(room)
            dismiss()
        case .person(let profile):
            startDirectChat(with: profile)
        }
    }

    private func startDirectChat(with profile: TrixUserProfile) {
        if let existingRoom = roomListViewModel.rooms.first(where: { room in
            room.kind == .direct &&
                room.id.caseInsensitiveCompare(profile.userID) == .orderedSame
        }) {
            model.openRoomFromKeyboardNavigation(existingRoom)
            dismiss()
            return
        }

        showsDirectChatError = false
        pendingDirectChatUserID = profile.userID
        Task {
            let didOpen = await model.createEncryptedDirectRoom(
                inviteeUserID: profile.userID,
                roomName: profile.title
            )
            pendingDirectChatUserID = nil
            if didOpen {
                dismiss()
            } else {
                showsDirectChatError = true
            }
        }
    }

    private func isStartingDirectChat(with profile: TrixUserProfile) -> Bool {
        guard let pendingDirectChatUserID else {
            return false
        }

        return pendingDirectChatUserID.caseInsensitiveCompare(profile.userID) == .orderedSame
    }
}

private enum TrixQuickSwitcherResult: Equatable, Identifiable {
    case room(TrixRoomSummary)
    case person(TrixUserProfile)

    var id: String {
        switch self {
        case .room(let room):
            return "room:\(room.id.lowercased())"
        case .person(let profile):
            return "person:\(profile.id)"
        }
    }
}

private struct TrixQuickSwitcherRoomRow: View {
    let room: TrixRoomSummary
    let isMarkedUnread: Bool

    var body: some View {
        HStack(spacing: 10) {
            TrixAvatarView(
                title: room.name,
                systemImage: room.kind.systemImage,
                size: 34,
                avatarURL: nil,
                tint: room.kind.tint
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(room.lastMessagePreview.isEmpty ? room.subtitle : room.lastMessagePreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if room.unreadCount > 0 {
                Text("\(room.unreadCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(TrixDesign.accent, in: Capsule())
                    .accessibilityLabel("\(room.unreadCount) unread")
            } else if isMarkedUnread {
                Circle()
                    .fill(TrixDesign.accent)
                    .frame(width: 9, height: 9)
                    .accessibilityLabel("Marked unread")
            }
        }
        .padding(.vertical, 2)
        .accessibilityLabel("Open \(room.name)")
    }
}
#endif
