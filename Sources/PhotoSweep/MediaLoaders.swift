import AVKit
import Photos
import SwiftUI

/// Loads one still image for a card or thumbnail, including pulling it down from iCloud.
final class ImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    /// 0...1 while the image is downloading from iCloud.
    @Published private(set) var progress: Double?
    @Published private(set) var failed = false

    private var requestID: PHImageRequestID?
    private var loadedID: String?

    func load(_ asset: PHAsset, targetSize: CGSize) {
        guard loadedID != asset.localIdentifier else { return }
        cancel()
        loadedID = asset.localIdentifier
        let isCard = targetSize == ImagePipeline.cardSize
        let cacheKey = asset.localIdentifier as NSString
        if isCard, let cached = ImagePipeline.recentCards.object(forKey: cacheKey) {
            image = cached
            return
        }
        let options = ImagePipeline.options(progress: { [weak self] value, _, _, _ in
            DispatchQueue.main.async { self?.progress = value < 1 ? value : nil }
        })
        requestID = ImagePipeline.manager.requestImage(
            for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options
        ) { [weak self] result, info in
            DispatchQueue.main.async {
                guard let self else { return }
                let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                if let result {
                    self.image = result
                    self.failed = false
                    if isCard, !degraded { ImagePipeline.recentCards.setObject(result, forKey: cacheKey) }
                } else if !degraded, self.image == nil {
                    self.failed = true
                }
                if !degraded { self.progress = nil }
            }
        }
    }

    func cancel() {
        if let requestID { ImagePipeline.manager.cancelImageRequest(requestID) }
        requestID = nil
        loadedID = nil
    }

    deinit {
        if let requestID { ImagePipeline.manager.cancelImageRequest(requestID) }
    }
}

/// Plays one video: streams it from iCloud when needed, loops, and reports time for the scrubber.
///
/// It works in two steps so the next videos can be made ready ahead of time: `prepare` loads the
/// video and buffers its start while staying silent and paused, and `activate` starts playback
/// once the card is on top.
final class VideoController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    /// 0...1 while the video is downloading from iCloud.
    @Published private(set) var progress: Double?
    @Published private(set) var failed = false
    @Published var time: Double = 0
    @Published private(set) var duration: Double = 0

    /// How much of a video to buffer while it is only waiting its turn.
    private static let waitingBufferSeconds: TimeInterval = 8

    private var requestID: PHImageRequestID?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var stopped = false
    private var wantsPlayback = false
    private var wantsMuted = true

    /// Starts loading the video and buffering its beginning. Nothing plays yet.
    func prepare(_ asset: PHAsset) {
        guard requestID == nil, player == nil else { return }
        stopped = false
        failed = false
        duration = asset.duration
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic  // streams a medium-quality version instead of the full original
        options.progressHandler = { [weak self] value, _, _, _ in
            DispatchQueue.main.async { self?.progress = value < 1 ? value : nil }
        }
        requestID = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) {
            [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.requestID = nil
                self.progress = nil
                guard let item else {
                    self.failed = true
                    return
                }
                self.attach(item)
            }
        }
    }

    /// Starts playback, now or as soon as the video has loaded.
    func activate(muted: Bool) {
        wantsPlayback = true
        wantsMuted = muted
        guard let player else { return }
        player.currentItem?.preferredForwardBufferDuration = 0  // 0 lets the system decide
        player.isMuted = muted
        player.play()
        isPlaying = true
    }

    private func attach(_ item: AVPlayerItem) {
        // A waiting video only buffers its first few seconds, so skipping past it wastes little.
        item.preferredForwardBufferDuration = wantsPlayback ? 0 : Self.waitingBufferSeconds
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.status == .readyToPlay { self?.isReady = true }
                if item.status == .failed { self?.failed = true }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] current in
            self?.time = current.seconds.isFinite ? current.seconds : 0
        }
        self.player = player
        if wantsPlayback { activate(muted: wantsMuted) }
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func setMuted(_ muted: Bool) {
        wantsMuted = muted
        if wantsPlayback { player?.isMuted = muted }
    }

    func seek(to seconds: Double) {
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
    }

    func stop() {
        stopped = true
        wantsPlayback = false
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        requestID = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        player?.pause()
        player = nil
        isReady = false
        isPlaying = false
        progress = nil
    }

    deinit {
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

/// Gets the next videos ready while the current card is still on screen, so playback can start
/// the moment a card reaches the top. Used from the main thread only.
final class VideoPool {
    static let shared = VideoPool()

    private var waiting: [String: VideoController] = [:]

    /// Prepares the given upcoming videos and stops preparing anything else.
    /// `currentID` is the card that is on top right now: if its video is still waiting here to be
    /// picked up, it is left alone.
    func prepare(upcoming: [PHAsset], keeping currentID: String?) {
        var wanted = Set(upcoming.map(\.localIdentifier))
        if let currentID { wanted.insert(currentID) }
        for (id, controller) in waiting where !wanted.contains(id) {
            controller.stop()
            waiting[id] = nil
        }
        for asset in upcoming where waiting[asset.localIdentifier] == nil {
            let controller = VideoController()
            controller.prepare(asset)
            waiting[asset.localIdentifier] = controller
        }
    }

    /// Hands over the prepared video for a card that just reached the top, or a fresh one.
    func checkout(_ asset: PHAsset) -> VideoController {
        if let prepared = waiting.removeValue(forKey: asset.localIdentifier) {
            if !prepared.failed { return prepared }
            prepared.stop()
        }
        return VideoController()
    }

    /// Stops and forgets everything that was being prepared.
    func reset() {
        for controller in waiting.values { controller.stop() }
        waiting = [:]
    }

    var waitingCount: Int { waiting.count }
}

/// The video surface, with no built-in controls so it never competes with the swipe gesture.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
