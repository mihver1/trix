import SwiftUI

struct TrixMediaCacheSettingsView: View {
    @ObservedObject var model: TrixAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let mediaCacheMessage = model.mediaCacheMessage {
                TrixBannerView(
                    text: mediaCacheMessage,
                    systemImage: "internaldrive",
                    tint: TrixDesign.accent,
                    dismissAction: model.dismissMediaCacheMessage
                )
            }

            LabeledContent("Media cached", value: model.mediaCacheSnapshot.formattedTotalBytes)
            LabeledContent("Media entries", value: "\(model.mediaCacheSnapshot.entryCount)")
            LabeledContent("Sticker packs", value: "\(model.stickerLibraryStats.packCount)")
            LabeledContent("Sticker storage", value: model.stickerLibraryStats.formattedTotalBytes)

            Picker("Size limit", selection: sizeSelection) {
                ForEach(TrixMediaCacheSizeOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            Picker("Keep by age", selection: ageSelection) {
                ForEach(TrixMediaCacheAgeOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            Picker("Per chat media", selection: countSelection) {
                ForEach(TrixMediaCacheCountOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    mediaCacheActionButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    mediaCacheActionButtons
                }
            }

            if !model.stickerPacks.isEmpty {
                Divider()
                stickerPackList
            }
        }
    }

    @ViewBuilder
    private var mediaCacheActionButtons: some View {
        Button(role: .destructive) {
            Task {
                await model.clearMediaCache()
            }
        } label: {
            Label("Clear Media", systemImage: "trash")
        }
        .disabled(!model.isAuthenticated || model.isUpdatingMediaCache)

        Button {
            Task {
                await model.clearSelectedRoomMediaCache()
            }
        } label: {
            Label("Clear Chat Media", systemImage: "bubble.left.and.bubble.right")
        }
        .disabled(!model.isAuthenticated || model.selectedRoomID == nil || model.isUpdatingMediaCache)

        Button {
            Task {
                await model.clearMediaCacheOlderThan(days: 30)
            }
        } label: {
            Label("Clear 30+ Days", systemImage: "calendar.badge.minus")
        }
        .disabled(!model.isAuthenticated || model.isUpdatingMediaCache)

        Button(role: .destructive) {
            Task {
                await model.clearStickerLibrary()
            }
        } label: {
            Label("Clear Stickers", systemImage: "face.smiling")
        }
        .disabled(!model.isAuthenticated || model.stickerPacks.isEmpty || model.isUpdatingMediaCache)
    }

    private var stickerPackList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.stickerPacks) { pack in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pack.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)

                        Text("\(pack.stickers.count) stickers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        Task {
                            await model.deleteStickerPack(pack)
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isUpdatingMediaCache)
                    .help("Remove sticker pack")
                    .accessibilityLabel("Remove \(pack.title)")
                }
            }
        }
    }

    private var sizeSelection: Binding<TrixMediaCacheSizeOption> {
        Binding {
            TrixMediaCacheSizeOption(policyValue: model.mediaCachePolicy.maxSizeBytes)
        } set: { option in
            updatePolicy(
                TrixMediaCachePolicy(
                    maxSizeBytes: option.bytes,
                    maxAgeDays: model.mediaCachePolicy.maxAgeDays,
                    maxMediaItemsPerRoom: model.mediaCachePolicy.maxMediaItemsPerRoom
                )
            )
        }
    }

    private var ageSelection: Binding<TrixMediaCacheAgeOption> {
        Binding {
            TrixMediaCacheAgeOption(policyValue: model.mediaCachePolicy.maxAgeDays)
        } set: { option in
            updatePolicy(
                TrixMediaCachePolicy(
                    maxSizeBytes: model.mediaCachePolicy.maxSizeBytes,
                    maxAgeDays: option.days,
                    maxMediaItemsPerRoom: model.mediaCachePolicy.maxMediaItemsPerRoom
                )
            )
        }
    }

    private var countSelection: Binding<TrixMediaCacheCountOption> {
        Binding {
            TrixMediaCacheCountOption(policyValue: model.mediaCachePolicy.maxMediaItemsPerRoom)
        } set: { option in
            updatePolicy(
                TrixMediaCachePolicy(
                    maxSizeBytes: model.mediaCachePolicy.maxSizeBytes,
                    maxAgeDays: model.mediaCachePolicy.maxAgeDays,
                    maxMediaItemsPerRoom: option.count
                )
            )
        }
    }

    private func updatePolicy(_ policy: TrixMediaCachePolicy) {
        Task {
            await model.updateMediaCachePolicy(policy)
        }
    }
}

private enum TrixMediaCacheSizeOption: String, CaseIterable, Identifiable {
    case megabytes128
    case megabytes512
    case gigabyte1
    case gigabytes2
    case unlimited

    var id: String { rawValue }

    init(policyValue: Int64?) {
        guard let policyValue else {
            self = .unlimited
            return
        }

        self = Self.allCases.first { $0.bytes == policyValue } ?? .megabytes512
    }

    var bytes: Int64? {
        switch self {
        case .megabytes128:
            return 128 * 1024 * 1024
        case .megabytes512:
            return 512 * 1024 * 1024
        case .gigabyte1:
            return 1024 * 1024 * 1024
        case .gigabytes2:
            return 2 * 1024 * 1024 * 1024
        case .unlimited:
            return nil
        }
    }

    var title: String {
        switch self {
        case .megabytes128:
            return "128 MB"
        case .megabytes512:
            return "512 MB"
        case .gigabyte1:
            return "1 GB"
        case .gigabytes2:
            return "2 GB"
        case .unlimited:
            return "Unlimited"
        }
    }
}

private enum TrixMediaCacheAgeOption: String, CaseIterable, Identifiable {
    case days7
    case days30
    case days90
    case forever

    var id: String { rawValue }

    init(policyValue: Int?) {
        guard let policyValue else {
            self = .forever
            return
        }

        self = Self.allCases.first { $0.days == policyValue } ?? .days30
    }

    var days: Int? {
        switch self {
        case .days7:
            return 7
        case .days30:
            return 30
        case .days90:
            return 90
        case .forever:
            return nil
        }
    }

    var title: String {
        switch self {
        case .days7:
            return "7 days"
        case .days30:
            return "30 days"
        case .days90:
            return "90 days"
        case .forever:
            return "Forever"
        }
    }
}

private enum TrixMediaCacheCountOption: String, CaseIterable, Identifiable {
    case messages50
    case messages200
    case messages500
    case forever

    var id: String { rawValue }

    init(policyValue: Int?) {
        guard let policyValue else {
            self = .forever
            return
        }

        self = Self.allCases.first { $0.count == policyValue } ?? .messages500
    }

    var count: Int? {
        switch self {
        case .messages50:
            return 50
        case .messages200:
            return 200
        case .messages500:
            return 500
        case .forever:
            return nil
        }
    }

    var title: String {
        switch self {
        case .messages50:
            return "50"
        case .messages200:
            return "200"
        case .messages500:
            return "500"
        case .forever:
            return "Forever"
        }
    }
}
