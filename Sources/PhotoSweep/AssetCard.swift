import Photos
import SwiftUI

/// One photo or video, filling an opaque card. Only the top card plays video.
struct AssetCard: View {
    let asset: PHAsset
    let isActive: Bool

    @EnvironmentObject private var model: AppModel
    @StateObject private var image = ImageLoader()
    @StateObject private var video: VideoController

    init(asset: PHAsset, isActive: Bool) {
        self.asset = asset
        self.isActive = isActive
        // Evaluated once, when the card first appears. The top card picks up the player that was
        // prepared while it was still waiting underneath, so its video can start right away.
        _video = StateObject(
            wrappedValue: isActive && asset.mediaType == .video
                ? VideoPool.shared.checkout(asset) : VideoController())
    }

    private var isVideo: Bool { asset.mediaType == .video }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(white: 0.09))

            if let still = image.image {
                Image(nsImage: still)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if image.failed {
                unavailable("Couldn't load this item")
            } else {
                ProgressView().controlSize(.large)
            }

            if isActive, isVideo, let player = video.player, video.isReady {
                PlayerSurface(player: player)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 10) {
                Spacer()
                if let fraction = downloadFraction {
                    DownloadBadge(fraction: fraction)
                } else if isActive, isVideo, video.failed {
                    unavailable("Couldn't play this video")
                }
                if isActive, isVideo, video.player != nil {
                    VideoControls(video: video)
                }
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topLeading) { kindBadge.padding(14) }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .onAppear(perform: begin)
        .onDisappear(perform: end)
    }

    private var downloadFraction: Double? {
        if isActive, isVideo, let value = video.progress { return value }
        return image.progress
    }

    @ViewBuilder private var kindBadge: some View {
        if isVideo {
            Label(Format.duration(asset.duration), systemImage: "video.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
        } else if asset.mediaSubtypes.contains(.photoLive) {
            Label("Live", systemImage: "livephoto")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
        }
    }

    private func unavailable(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
    }

    private func begin() {
        image.load(asset, targetSize: ImagePipeline.cardSize)
        guard isActive else { return }
        if isVideo {
            video.prepare(asset)  // does nothing if it was already prepared ahead of time
            video.activate(muted: model.muted)
            model.activeVideo = video
        } else {
            model.activeVideo = nil
        }
    }

    private func end() {
        image.cancel()
        if model.activeVideo === video { model.activeVideo = nil }
        video.stop()
    }
}

private struct DownloadBadge: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.and.arrow.down")
            ProgressView(value: fraction)
                .frame(width: 120)
            Text("\(Int(fraction * 100))%")
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.6), in: Capsule())
        .foregroundStyle(.white)
    }
}

private struct VideoControls: View {
    @ObservedObject var video: VideoController
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Button(action: video.togglePlay) {
                Image(systemName: video.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .help("Play or pause (Space)")

            Slider(
                value: Binding(get: { video.time }, set: { video.seek(to: $0) }),
                in: 0...max(video.duration, 0.1))

            Text("\(Format.duration(video.time)) / \(Format.duration(video.duration))")
                .font(.caption)
                .monospacedDigit()

            Button {
                model.muted.toggle()
            } label: {
                Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
            }
            .help("Mute or unmute (M)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.black.opacity(0.6), in: Capsule())
        .frame(maxWidth: 520)
    }
}
