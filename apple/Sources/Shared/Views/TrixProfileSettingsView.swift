import SwiftUI
import ImageIO
import UniformTypeIdentifiers

#if os(iOS)
import PhotosUI
#endif

struct TrixProfileSettingsView: View {
    @ObservedObject var model: TrixAppModel
    @StateObject private var viewModel = TrixProfileViewModel()
    @State private var avatarCropImageData: Data?
    @State private var isShowingAvatarCropper = false
    @State private var avatarImportError: String?

    #if os(iOS)
    @State private var selectedAvatarPhoto: PhotosPickerItem?
    #elseif os(macOS)
    @State private var isShowingAvatarImporter = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.isLoading, viewModel.profile == nil {
                ProgressView()
                    .controlSize(.small)
            }

            if let profile = viewModel.profile {
                LabeledContent("User", value: TrixUserIdentity.handle(from: profile.userID))
            }

            avatarSection

            TextField("Name", text: $viewModel.draftDisplayName)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("Bio")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $viewModel.draftBio)
                    .frame(minHeight: 76)
                    .padding(6)
                    .scrollContentBackground(.hidden)
                    .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
                    }
            }

            TextField("Status", text: $viewModel.draftStatusMessage)
                .textFieldStyle(.roundedBorder)

            TextField("Website", text: $viewModel.draftWebsite)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .textInputAutocapitalizationNever()

            HStack(spacing: 10) {
                Button {
                    Task {
                        await viewModel.save { update in
                            try await model.updateProfile(update)
                        }
                    }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Save", systemImage: "checkmark")
                    }
                }
                .disabled(!viewModel.canSave)

                Button {
                    Task {
                        await viewModel.load {
                            try await model.profile()
                        }
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading || viewModel.isSaving)
            }
            .buttonStyle(.bordered)

            if viewModel.didSave {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let avatarImportError {
                Text(avatarImportError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: model.session?.userID) {
            await viewModel.load {
                try await model.profile()
            }
        }
        #if os(iOS)
        .onChange(of: selectedAvatarPhoto) { _, item in
            guard let item else {
                return
            }

            Task {
                await importAvatarPhoto(item)
            }
        }
        #elseif os(macOS)
        .fileImporter(
            isPresented: $isShowingAvatarImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            importAvatarFile(result)
        }
        #endif
        .sheet(isPresented: $isShowingAvatarCropper) {
            if let avatarCropImageData {
                TrixAvatarCropperSheet(
                    imageData: avatarCropImageData,
                    onApply: { image in
                        viewModel.setAvatarImage(image)
                        clearAvatarCropSelection()
                    },
                    onCancel: {
                        clearAvatarCropSelection()
                    }
                )
            }
        }
        .onChange(of: isShowingAvatarCropper) { _, isPresented in
            if !isPresented {
                avatarCropImageData = nil
            }
        }
        .onChange(of: viewModel.draftDisplayName) { _, _ in
            viewModel.resetSavedState()
        }
        .onChange(of: viewModel.draftBio) { _, _ in
            viewModel.resetSavedState()
        }
        .onChange(of: viewModel.draftStatusMessage) { _, _ in
            viewModel.resetSavedState()
        }
        .onChange(of: viewModel.draftWebsite) { _, _ in
            viewModel.resetSavedState()
        }
    }

    private var avatarSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Avatar")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 12) {
                TrixProfileAvatarPreview(
                    title: avatarTitle,
                    avatarURL: viewModel.displayedAvatarURL,
                    size: 72
                )

                VStack(alignment: .leading, spacing: 8) {
                    avatarImportControl

                    Button {
                        viewModel.removeAvatar()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .disabled(viewModel.displayedAvatarURL == nil || viewModel.isSaving)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var avatarImportControl: some View {
        #if os(iOS)
        PhotosPicker(
            selection: $selectedAvatarPhoto,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Label("Upload", systemImage: "photo.on.rectangle")
        }
        .disabled(viewModel.isLoading || viewModel.isSaving)
        #elseif os(macOS)
        Button {
            isShowingAvatarImporter = true
        } label: {
            Label("Upload", systemImage: "photo.on.rectangle")
        }
        .disabled(viewModel.isLoading || viewModel.isSaving)
        #endif
    }

    private var avatarTitle: String {
        let draftName = viewModel.draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draftName.isEmpty {
            return draftName
        }

        return viewModel.profile?.title ?? "Profile"
    }

    #if os(iOS)
    @MainActor
    private func importAvatarPhoto(_ item: PhotosPickerItem) async {
        defer {
            selectedAvatarPhoto = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                avatarImportError = "Avatar image could not be loaded."
                return
            }

            presentAvatarCropper(with: data)
        } catch {
            avatarImportError = error.trixUserFacingMessage
        }
    }
    #elseif os(macOS)
    private func importAvatarFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                return
            }

            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            presentAvatarCropper(with: try Data(contentsOf: url))
        } catch {
            avatarImportError = error.trixUserFacingMessage
        }
    }
    #endif

    private func presentAvatarCropper(with data: Data) {
        guard TrixAvatarImageRenderer.cgImage(from: data) != nil else {
            avatarImportError = "Avatar image could not be opened."
            return
        }

        avatarImportError = nil
        avatarCropImageData = data
        isShowingAvatarCropper = true
    }

    private func clearAvatarCropSelection() {
        avatarCropImageData = nil
        isShowingAvatarCropper = false
    }
}

private extension View {
    @ViewBuilder
    func textInputAutocapitalizationNever() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
            .autocorrectionDisabled()
        #endif
    }
}

private struct TrixProfileAvatarPreview: View {
    let title: String
    let avatarURL: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let avatarData = TrixUserAvatarImage.imageData(fromDataURL: avatarURL),
               let cgImage = TrixAvatarImageRenderer.cgImage(from: avatarData) {
                avatarImage(cgImage)
            } else if let url = remoteAvatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallbackAvatar
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: size, height: size)
    }

    private var fallbackAvatar: some View {
        TrixAvatarView(title: title, systemImage: "person.crop.circle", size: size)
    }

    private func avatarImage(_ cgImage: CGImage) -> some View {
        Image(decorative: cgImage, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
            }
    }

    private var remoteAvatarURL: URL? {
        guard let avatarURL,
              let url = URL(string: avatarURL),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }

        return url
    }
}

private struct TrixAvatarCropperSheet: View {
    private let imageData: Data
    private let sourceImage: CGImage?
    private let onApply: (TrixUserAvatarImage) -> Void
    private let onCancel: () -> Void
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var settledOffset = CGSize.zero
    @State private var viewportSide: CGFloat = 320
    @State private var errorMessage: String?

    init(
        imageData: Data,
        onApply: @escaping (TrixUserAvatarImage) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.imageData = imageData
        self.sourceImage = TrixAvatarImageRenderer.cgImage(from: imageData)
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Crop avatar")
                    .font(.headline)

                Spacer()

                Button {
                    onCancel()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }

                Button {
                    applyCrop()
                } label: {
                    Label("Apply", systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sourceImage == nil)
            }
            .buttonStyle(.bordered)

            if let sourceImage {
                TrixAvatarCropCanvas(
                    image: sourceImage,
                    zoom: $zoom,
                    settledZoom: $settledZoom,
                    offset: $offset,
                    settledOffset: $settledOffset,
                    viewportSide: $viewportSide
                )
                .frame(maxWidth: .infinity)
                .frame(height: 340)

                HStack(spacing: 10) {
                    Image(systemName: "minus.magnifyingglass")
                        .foregroundStyle(.secondary)
                    Slider(value: $zoom, in: 1...4)
                        .onChange(of: zoom) { _, newValue in
                            let clampedZoom = min(max(newValue, 1), 4)
                            zoom = clampedZoom
                            settledZoom = clampedZoom
                            offset = TrixAvatarCropLayout(
                                image: sourceImage,
                                viewportSide: viewportSide,
                                zoom: clampedZoom,
                                offset: offset
                            ).clampedOffset(offset)
                            settledOffset = offset
                        }
                    Image(systemName: "plus.magnifyingglass")
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Avatar image could not be opened.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        #if os(macOS)
        .frame(width: 460)
        #endif
    }

    private func applyCrop() {
        guard let sourceImage else {
            errorMessage = "Avatar image could not be opened."
            return
        }

        let layout = TrixAvatarCropLayout(
            image: sourceImage,
            viewportSide: viewportSide,
            zoom: zoom,
            offset: offset
        )
        guard let avatarImage = TrixAvatarImageRenderer.avatarImage(
            from: sourceImage,
            cropRect: layout.cropRect
        ) else {
            errorMessage = "Avatar image could not be cropped."
            return
        }

        onApply(avatarImage)
    }
}

private struct TrixAvatarCropCanvas: View {
    let image: CGImage
    @Binding var zoom: CGFloat
    @Binding var settledZoom: CGFloat
    @Binding var offset: CGSize
    @Binding var settledOffset: CGSize
    @Binding var viewportSide: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let layout = TrixAvatarCropLayout(
                image: image,
                viewportSide: side,
                zoom: zoom,
                offset: offset
            )

            ZStack {
                TrixDesign.secondarySurface

                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: layout.displayedSize.width, height: layout.displayedSize.height)
                    .offset(offset)
                    .gesture(dragGesture(for: side))
                    .simultaneousGesture(zoomGesture(for: side))

                Circle()
                    .stroke(.white.opacity(0.95), lineWidth: 2)
                    .shadow(color: .black.opacity(0.28), radius: 2)
                    .padding(1)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                updateViewportSide(side)
            }
            .onChange(of: side) { _, newValue in
                updateViewportSide(newValue)
            }
        }
    }

    private func dragGesture(for side: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let proposed = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
                offset = TrixAvatarCropLayout(
                    image: image,
                    viewportSide: side,
                    zoom: zoom,
                    offset: proposed
                ).clampedOffset(proposed)
            }
            .onEnded { _ in
                settledOffset = offset
            }
    }

    private func zoomGesture(for side: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let nextZoom = min(max(settledZoom * value, 1), 4)
                zoom = nextZoom
                offset = TrixAvatarCropLayout(
                    image: image,
                    viewportSide: side,
                    zoom: nextZoom,
                    offset: offset
                ).clampedOffset(offset)
            }
            .onEnded { _ in
                zoom = min(max(zoom, 1), 4)
                settledZoom = zoom
                offset = TrixAvatarCropLayout(
                    image: image,
                    viewportSide: side,
                    zoom: zoom,
                    offset: offset
                ).clampedOffset(offset)
                settledOffset = offset
            }
    }

    private func updateViewportSide(_ side: CGFloat) {
        guard side > 0 else {
            return
        }

        viewportSide = side
        offset = TrixAvatarCropLayout(
            image: image,
            viewportSide: side,
            zoom: zoom,
            offset: offset
        ).clampedOffset(offset)
        settledOffset = offset
    }
}

private struct TrixAvatarCropLayout {
    let image: CGImage
    let viewportSide: CGFloat
    let zoom: CGFloat
    let offset: CGSize

    private var sourceSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    private var baseScale: CGFloat {
        guard sourceSize.width > 0, sourceSize.height > 0, viewportSide > 0 else {
            return 1
        }

        return max(viewportSide / sourceSize.width, viewportSide / sourceSize.height)
    }

    private var imageScale: CGFloat {
        baseScale * max(zoom, 1)
    }

    var displayedSize: CGSize {
        CGSize(width: sourceSize.width * imageScale, height: sourceSize.height * imageScale)
    }

    var cropRect: CGRect {
        guard imageScale > 0 else {
            return CGRect(origin: .zero, size: sourceSize)
        }

        let clamped = clampedOffset(offset)
        let origin = CGPoint(
            x: ((displayedSize.width - viewportSide) / 2 - clamped.width) / imageScale,
            y: ((displayedSize.height - viewportSide) / 2 - clamped.height) / imageScale
        )
        let cropSize = viewportSide / imageScale
        let fullRect = CGRect(origin: .zero, size: sourceSize)
        return CGRect(x: origin.x, y: origin.y, width: cropSize, height: cropSize)
            .intersection(fullRect)
            .integral
    }

    func clampedOffset(_ proposed: CGSize) -> CGSize {
        let maxX = max((displayedSize.width - viewportSide) / 2, 0)
        let maxY = max((displayedSize.height - viewportSide) / 2, 0)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}

enum TrixAvatarImageRenderer {
    static let maxEncodedAvatarBytes = 48 * 1024
    private static let preferredOutputSides = [192, 160, 128]
    private static let preferredJPEGQualities: [CGFloat] = [0.82, 0.72, 0.62]

    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func avatarImage(from image: CGImage, cropRect: CGRect) -> TrixUserAvatarImage? {
        for outputSide in preferredOutputSides {
            for quality in preferredJPEGQualities {
                guard let data = jpegData(
                    from: image,
                    cropRect: cropRect,
                    outputSide: outputSide,
                    quality: quality
                ) else {
                    continue
                }

                if data.count <= maxEncodedAvatarBytes {
                    return TrixUserAvatarImage(data: data, mimeType: "image/jpeg")
                }
            }
        }

        return nil
    }

    private static func jpegData(
        from image: CGImage,
        cropRect: CGRect,
        outputSide: Int,
        quality: CGFloat
    ) -> Data? {
        let fullRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let safeCropRect = cropRect.intersection(fullRect).integral
        guard !safeCropRect.isNull,
              !safeCropRect.isEmpty,
              let croppedImage = image.cropping(to: safeCropRect),
              let context = CGContext(
                data: nil,
                width: outputSide,
                height: outputSide,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: outputSide, height: outputSide))
        context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: outputSide, height: outputSide))

        guard let outputImage = context.makeImage() else {
            return nil
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, outputImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }
}
