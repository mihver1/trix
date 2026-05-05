import SwiftUI

struct MatrixTimelineView: View {
    @ObservedObject var model: MatrixAppModel
    let room: MatrixRoomSummary
    @ObservedObject private var timelineViewModel: TimelineViewModel
    @State private var draft = ""

    init(model: MatrixAppModel, room: MatrixRoomSummary) {
        self.model = model
        self.room = room
        self._timelineViewModel = ObservedObject(wrappedValue: model.timelineViewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
                .background(.regularMaterial)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if timelineViewModel.isLoading {
                            ProgressView("Loading timeline")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 32)
                        }

                        ForEach(timelineViewModel.items) { item in
                            MatrixTimelineRow(item: item)
                                .id(item.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: timelineViewModel.items) { _, items in
                    guard let last = items.last else {
                        return
                    }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }

            if let errorMessage = timelineViewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Divider()

            HStack(spacing: 10) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)

                Button {
                    let text = draft
                    draft = ""
                    Task {
                        await model.send(text: text)
                    }
                } label: {
                    if timelineViewModel.isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(timelineViewModel.isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send message")
            }
            .padding(16)
        }
        .navigationTitle(room.name)
        .task(id: room.id) {
            await model.loadTimeline(roomID: room.id)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .font(.title2.weight(.semibold))
                    if room.isEncrypted {
                        Label("Encrypted", systemImage: "lock.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
                Text(room.subtitle)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await model.loadTimeline(roomID: room.id)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh timeline")
        }
    }
}

private struct MatrixTimelineRow: View {
    let item: MatrixTimelineItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(item.sender)
                    .font(.caption.weight(.semibold))
                Text(item.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.isLocalEcho {
                    Text("sent")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(item.body)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(item.isLocalEcho ? Color.blue.opacity(0.10) : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 680, alignment: .leading)
    }
}
