import Photos
import SweepCore
import SwiftUI

/// The open queue as a grid of thumbnails. A click puts an item on the delete list or takes it
/// back off; nothing is deleted here, exactly as with swiping.
struct GalleryView: View {
    @EnvironmentObject private var model: AppModel

    private let spacing: CGFloat = 8
    private let padding: CGFloat = 16
    private let targetCellWidth: CGFloat = 150

    var body: some View {
        GeometryReader { geometry in
            // The column count is worked out here, not left to the grid, so the arrow keys
            // know how far "up" and "down" are.
            let columnCount = max(1, Int((geometry.size.width - padding * 2 + spacing) / (targetCellWidth + spacing)))
            let marked = Set(model.store.marked)
            ZStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount),
                            spacing: spacing
                        ) {
                            ForEach(model.deck.ids, id: \.self) { id in
                                if let asset = model.asset(forID: id) {
                                    GalleryCell(
                                        asset: asset,
                                        decision: marked.contains(id) ? .delete : (model.store.isKept(id) ? .keep : nil),
                                        isFocused: model.galleryFocus == id,
                                        onClick: { model.galleryClick(id) },
                                        onEnlarge: { model.openPreview(id) })
                                }
                            }
                        }
                        .padding(padding)
                    }
                    .onChange(of: model.galleryFocus) { _, focus in
                        if let focus { proxy.scrollTo(focus) }
                    }
                }

                if let id = model.previewID, let asset = model.asset(forID: id) {
                    GalleryPreview(asset: asset, isMarked: marked.contains(id))
                }
            }
            .onAppear { model.galleryColumns = columnCount }
            .onChange(of: columnCount) { _, count in model.galleryColumns = count }
        }
    }
}

private struct GalleryCell: View {
    let asset: PHAsset
    let decision: Decision?
    let isFocused: Bool
    let onClick: () -> Void
    let onEnlarge: () -> Void

    @StateObject private var image = ImageLoader()
    // Declared by hand: this SDK turns `@State` into a macro whose plugin only ships with full Xcode.
    private var _hovering = State<Bool>(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    private var isMarked: Bool { decision == .delete }
    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        Color(white: 0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail = image.image {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay { if isMarked { Color.red.opacity(0.38) } }
            .clipShape(shape)
            .overlay(alignment: .topLeading) { stateBadge.padding(6) }
            .overlay(alignment: .bottomLeading) { videoBadge.padding(6) }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: onEnlarge) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.65), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("See it larger (Space)")
                }
            }
            .overlay {
                if isFocused {
                    shape.strokeBorder(Color.white, lineWidth: 3)
                } else if isMarked {
                    shape.strokeBorder(Color.red, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onClick)
            .onHover { hovering = $0 }
            .help(isMarked ? "Click to take it off the delete list" : "Click to mark for deletion")
            .onAppear { image.load(asset, targetSize: ImagePipeline.thumbnailSize) }
            .onDisappear { image.cancel() }
    }

    @ViewBuilder private var stateBadge: some View {
        if isMarked {
            Image(systemName: "trash.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Color.red, in: Circle())
        } else if decision == .keep {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Color.green.opacity(0.85), in: Circle())
        }
    }

    @ViewBuilder private var videoBadge: some View {
        if asset.mediaType == .video {
            Label(Format.duration(asset.duration), systemImage: "video.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
        }
    }
}

/// One gallery item shown large, over the grid. Videos play here.
private struct GalleryPreview: View {
    let asset: PHAsset
    let isMarked: Bool

    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .onTapGesture { model.closePreview() }

            VStack(spacing: 14) {
                AssetCard(asset: asset, isActive: true)
                    .id("preview-" + asset.localIdentifier)
                    .overlay(alignment: .topTrailing) {
                        if isMarked {
                            Label("On delete list", systemImage: "trash.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.6), in: Capsule())
                                .foregroundStyle(.red)
                                .padding(14)
                        }
                    }

                HStack(spacing: 12) {
                    Button { model.moveGalleryFocus(by: -1) } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .help("Previous item (←)")

                    Button { model.toggleMark(asset.localIdentifier) } label: {
                        Label(
                            isMarked ? "Take Off Delete List" : "Mark for Deletion",
                            systemImage: isMarked ? "arrow.uturn.backward" : "trash")
                            .frame(minWidth: 170)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isMarked ? .gray : .red)
                    .help("Delete key")

                    Button { model.moveGalleryFocus(by: 1) } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .help("Next item (→)")

                    Button("Back to Grid") { model.closePreview() }
                        .help("Space or Esc")
                }
                .controlSize(.large)

                Text("\(Format.date(asset.creationDate))  ·  \(Format.bytes(model.size(for: asset)))  ·  \(asset.pixelWidth) × \(asset.pixelHeight)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(24)
        }
    }
}

/// The strip under the grid: what the keys do, and "Keep the Rest".
struct GalleryFooter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text("Click to mark for deletion, click again to undo it  ·  Space to see it larger  ·  Arrow keys to move, Delete to mark")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("Keep the Rest…") { model.requestKeepRest() }
                .disabled(model.isLoading || model.deck.total == 0)
                .help("Keep everything here that you have not marked, so this queue is finished")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .confirmationDialog(title, isPresented: $model.confirmKeepRest) {
            if model.keepRestCount > 0 {
                Button("Keep \(Format.count(model.keepRestCount))") { model.keepRest() }
            }
            Button(model.keepRestCount > 0 ? "Cancel" : "OK", role: .cancel) {}
        } message: {
            Text(model.keepRestCount > 0
                ? "They will be skipped from now on in every queue. What you marked stays on your delete list, and Undo takes this back."
                : "Every item here is already kept or on your delete list.")
        }
    }

    private var title: String {
        let count = model.keepRestCount
        guard count > 0 else { return "Nothing left to keep in this queue" }
        return "Keep the \(Format.count(count)) \(count == 1 ? "item" : "items") you did not mark?"
    }
}
