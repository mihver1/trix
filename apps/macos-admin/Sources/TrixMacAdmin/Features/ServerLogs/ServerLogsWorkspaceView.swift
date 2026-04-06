import SwiftUI

struct ServerLogsWorkspaceView: View {
    @ObservedObject var model: AdminAppModel
    @State private var filterText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                TextField("Filter by message, target, file, or rendered text", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                Text("\(model.serverLogEntries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.serverLogDroppedEntries > 0 {
                    Text("Dropped \(model.serverLogDroppedEntries)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if let err = model.serverLogsError, !err.isEmpty {
                Text(err)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }

            HSplitView {
                logList
                    .frame(minWidth: 360)
                logDetail
                    .frame(minWidth: 420)
            }
        }
        .task(id: model.selectedClusterID) {
            await model.refreshServerLogs()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") {
                    Task { await model.refreshServerLogs() }
                }
                .disabled(model.activeSession == nil || model.isServerLogsLoading)
            }
        }
    }

    private var filteredEntries: [AdminServerLogEntry] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return model.serverLogEntries
        }
        return model.serverLogEntries.filter { entry in
            [
                entry.message,
                entry.target,
                entry.modulePath ?? "",
                entry.file ?? "",
                entry.rendered,
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(query)
        }
    }

    private var selectedEntry: AdminServerLogEntry? {
        guard let id = model.selectedServerLogEntryID else { return nil }
        return model.serverLogEntries.first(where: { $0.entryId == id })
    }

    private var logList: some View {
        Group {
            if model.isServerLogsLoading && model.serverLogEntries.isEmpty {
                ProgressView("Loading server logs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "No logs",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Server logs are kept in memory for the current backend process only.")
                )
            } else {
                List(selection: $model.selectedServerLogEntryID) {
                    ForEach(filteredEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(formattedDate(entry.recordedAtUnixMs))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(entry.level.rawValue.uppercased())
                                    .font(.system(.caption2, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(levelColor(entry.level).opacity(0.15))
                                    .foregroundStyle(levelColor(entry.level))
                                    .clipShape(Capsule())
                                Spacer(minLength: 8)
                            }
                            Text(entry.message)
                                .font(.subheadline)
                                .lineLimit(2)
                            Text(entry.target)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(entry.entryId)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var logDetail: some View {
        Group {
            if let entry = selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        GroupBox("Metadata") {
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent("Time", value: formattedDate(entry.recordedAtUnixMs))
                                LabeledContent("Level", value: entry.level.rawValue.uppercased())
                                LabeledContent("Target", value: entry.target)
                                if let modulePath = entry.modulePath {
                                    LabeledContent("Module", value: modulePath)
                                }
                                if let file = entry.file {
                                    let location = entry.line.map { "\(file):\($0)" } ?? file
                                    LabeledContent("Location", value: location)
                                }
                            }
                        }

                        GroupBox("Rendered") {
                            Text(entry.rendered)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !entry.fields.isEmptyObject {
                            GroupBox("Fields") {
                                Text(entry.fields.prettyPrinted())
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView(
                    "Select a log entry",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Choose a row to inspect the full rendered log line and fields.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formattedDate(_ unixMs: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000)
        return date.formatted(
            Date.FormatStyle()
                .year(.defaultDigits)
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
                .secondFraction(.fractional(3))
        )
    }

    private func levelColor(_ level: AdminServerLogLevel) -> Color {
        switch level {
        case .trace:
            return .secondary
        case .debug:
            return .blue
        case .info:
            return .green
        case .warn:
            return .orange
        case .error:
            return .red
        }
    }
}
