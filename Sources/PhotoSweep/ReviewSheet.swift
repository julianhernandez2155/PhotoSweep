import Photos
import SwiftUI

/// Everything marked for deletion, as a grid. Clicking a thumbnail takes it back off the list.
struct ReviewSheet: View {
    @EnvironmentObject private var model: AppModel
    // Declared by hand: this SDK turns `@State` into a macro whose plugin only ships with full Xcode.
    private var _assets = State<[PHAsset]>(initialValue: [])
    private var assets: [PHAsset] {
        get { _assets.wrappedValue }
        nonmutating set { _assets.wrappedValue = newValue }
    }

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Delete list")
                    .font(.title2.weight(.semibold))
                Text(summary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("Click anything you want to keep after all. Deleted items go to Recently Deleted in Photos for 30 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            if assets.isEmpty {
                Text("Nothing is marked.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            ReviewThumbnail(asset: asset, bytes: model.store.markedBytes[asset.localIdentifier] ?? 0) {
                                keep(asset)
                            }
                        }
                    }
                    .padding(16)
                }
            }

            Divider()

            HStack {
                Button("Close") { model.showReview = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.isDeleting {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Photos…").foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    model.deleteMarked()
                } label: {
                    Text(assets.count == 1 ? "Delete 1 Item" : "Delete \(Format.count(assets.count)) Items")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(assets.isEmpty || model.isDeleting)
            }
            .padding(16)
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 540, idealHeight: 640)
        .onAppear { assets = model.markedAssets() }
    }

    private var summary: String {
        let count = assets.count
        let noun = count == 1 ? "item" : "items"
        return "\(Format.count(count)) \(noun) · \(Format.bytes(model.store.totalMarkedBytes))"
    }

    private func keep(_ asset: PHAsset) {
        model.unmark(asset.localIdentifier)
        withAnimation(.easeOut(duration: 0.15)) {
            assets.removeAll { $0.localIdentifier == asset.localIdentifier }
        }
    }
}

private struct ReviewThumbnail: View {
    let asset: PHAsset
    let bytes: Int64
    let onKeep: () -> Void

    @StateObject private var image = ImageLoader()
    private var _hovering = State<Bool>(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    // Written out because, before Swift 6.4, the private state above makes the automatic initializer private.
    init(asset: PHAsset, bytes: Int64, onKeep: @escaping () -> Void) {
        self.asset = asset
        self.bytes = bytes
        self.onKeep = onKeep
    }

    var body: some View {
        Button(action: onKeep) {
            ZStack {
                Color(white: 0.12)
                if let thumbnail = image.image {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                if hovering {
                    Color.black.opacity(0.55)
                    Label("Keep", systemImage: "arrow.uturn.backward")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottom) {
                HStack {
                    if asset.mediaType == .video {
                        Label(Format.duration(asset.duration), systemImage: "video.fill")
                    }
                    Spacer()
                    if bytes > 0 { Text(Format.bytes(bytes)) }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5))
                .clipShape(
                    UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to keep this one")
        .onAppear { image.load(asset, targetSize: ImagePipeline.thumbnailSize) }
        .onDisappear { image.cancel() }
    }
}
