import AppKit
import Photos
import SweepCore

enum QueueKind: Hashable {
    case screenshots
    case screenRecordings
    case videos
    case livePhotos
    case duplicates
    case largeVideos
    case savedBy(String)  // bundle identifier of the app that saved the items
    case all
    case album(String)  // album localIdentifier

    /// Queues whose contents come from the background scan, not from a plain library fetch.
    var isScanned: Bool {
        switch self {
        case .duplicates, .largeVideos, .savedBy: return true
        default: return false
        }
    }

    /// Whether the queue can hold video, which decides if "Longest" is a useful sort.
    var canContainVideo: Bool {
        switch self {
        case .screenshots, .livePhotos: return false
        default: return true
        }
    }
}

enum QueueSection: String {
    case cleanup = "Cleanup"
    case library = "Library"
    case albums = "Albums"
}

struct SweepQueue: Identifiable, Hashable {
    let kind: QueueKind
    let title: String
    let symbol: String
    let section: QueueSection
    /// Everything in the queue, decided or not.
    var count: Int

    var id: QueueKind { kind }
}

/// The sidebar's queues plus the item IDs in each one, which is what the counts are built from.
struct LibraryIndex {
    var queues: [SweepQueue]
    var members: [QueueKind: [String]]
}

enum SortOrder: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case oldest = "Oldest"
    case largest = "Largest"
    case longest = "Longest"

    var id: String { rawValue }
}

enum PhotoLibrary {
    static var isAuthorized: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// Hidden items and shared-album items are never shown or counted.
    static func baseOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary]
        return options
    }

    private static func predicate(for kind: QueueKind) -> NSPredicate? {
        let image = PHAssetMediaType.image.rawValue
        let video = PHAssetMediaType.video.rawValue
        switch kind {
        case .screenshots:
            return NSPredicate(
                format: "mediaType == %d AND (mediaSubtypes & %d) != 0",
                image, Int(PHAssetMediaSubtype.photoScreenshot.rawValue))
        case .screenRecordings:
            return NSPredicate(
                format: "mediaType == %d AND (mediaSubtypes & %d) != 0",
                video, Int(PHAssetMediaSubtype.videoScreenRecording.rawValue))
        case .videos:
            return NSPredicate(format: "mediaType == %d", video)
        case .livePhotos:
            return NSPredicate(
                format: "mediaType == %d AND (mediaSubtypes & %d) != 0",
                image, Int(PHAssetMediaSubtype.photoLive.rawValue))
        case .all:
            return NSPredicate(format: "mediaType == %d OR mediaType == %d", image, video)
        case .album, .duplicates, .largeVideos, .savedBy:
            return nil
        }
    }

    private static func sortDescriptors(for sort: SortOrder) -> [NSSortDescriptor] {
        switch sort {
        case .newest, .largest:
            return [NSSortDescriptor(key: "creationDate", ascending: false)]
        case .oldest:
            return [NSSortDescriptor(key: "creationDate", ascending: true)]
        case .longest:
            return [
                NSSortDescriptor(key: "duration", ascending: false),
                NSSortDescriptor(key: "creationDate", ascending: false),
            ]
        }
    }

    /// `scannedIDs` supplies the contents of queues that come from the background scan.
    /// `withSources` also loads which app saved each item, which only the scan needs.
    static func fetch(
        _ kind: QueueKind, sort: SortOrder = .newest, scannedIDs: [String] = [], withSources: Bool = false
    ) -> PHFetchResult<PHAsset> {
        let options = baseOptions()
        options.sortDescriptors = sortDescriptors(for: sort)
        if withSources { ImportSource.prefetch(on: options) }
        if kind.isScanned {
            return PHAsset.fetchAssets(withLocalIdentifiers: scannedIDs, options: options)
        }
        if case .album(let identifier) = kind {
            guard
                let album = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [identifier], options: nil
                ).firstObject
            else {
                return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil)
            }
            return PHAsset.fetchAssets(in: album, options: options)
        }
        options.predicate = predicate(for: kind)
        let result = PHAsset.fetchAssets(with: options)
        // If the subtype predicate matches nothing, fall back to the system's own Screen Recordings album.
        if kind == .screenRecordings, result.count == 0,
            let album = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: .smartAlbumScreenRecordings, options: nil
            ).firstObject
        {
            let fallback = baseOptions()
            fallback.sortDescriptors = sortDescriptors(for: sort)
            return PHAsset.fetchAssets(in: album, options: fallback)
        }
        return result
    }

    static func identifiers(in result: PHFetchResult<PHAsset>) -> [String] {
        var ids: [String] = []
        ids.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }

    /// The queues that come straight from the library, in display order, with the IDs of the
    /// items in each. Empty ones are left out. Queues found by the background scan (Duplicates,
    /// Large Videos, per-app) are added separately. Reads the whole library, so call it off
    /// the main thread.
    static func index() -> LibraryIndex {
        var members: [QueueKind: [String]] = [:]
        var albums: [SweepQueue] = []
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil)
        collections.enumerateObjects { album, _, _ in
            let ids = identifiers(in: PHAsset.fetchAssets(in: album, options: baseOptions()))
            guard !ids.isEmpty else { return }
            let kind = QueueKind.album(album.localIdentifier)
            members[kind] = ids
            albums.append(
                SweepQueue(
                    kind: kind, title: album.localizedTitle ?? "Untitled", symbol: "rectangle.stack",
                    section: .albums, count: ids.count))
        }
        albums.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let builtIn: [(QueueKind, String, String, QueueSection)] = [
            (.screenshots, "Screenshots", "camera.viewfinder", .cleanup),
            (.screenRecordings, "Screen Recordings", "record.circle", .cleanup),
            (.videos, "Videos", "video", .library),
            (.livePhotos, "Live Photos", "livephoto", .library),
            (.all, "All Photos & Videos", "photo.on.rectangle.angled", .library),
        ]
        var library: [SweepQueue] = []
        for (kind, title, symbol, section) in builtIn {
            let ids = identifiers(in: fetch(kind))
            guard !ids.isEmpty || kind == .all else { continue }
            members[kind] = ids
            library.append(SweepQueue(kind: kind, title: title, symbol: symbol, section: section, count: ids.count))
        }
        return LibraryIndex(queues: library + albums, members: members)
    }

    /// Looks items up by ID, in the order given. IDs that no longer exist are skipped.
    static func assets(withIDs ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
        var found: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in found[asset.localIdentifier] = asset }
        return ids.compactMap { found[$0] }
    }
}

/// Which app saved an item into the library. PhotoKit has no public way to ask, so this reads
/// a value Apple does not document. Every step is checked first, and when it is missing the
/// app simply offers no per-app queues.
enum ImportSource {
    private static let propertySet = "PHAssetPropertySetCuration"
    private static let propertiesSelector = NSSelectorFromString("curationProperties")
    private static let bundleSelector = NSSelectorFromString("importedByBundleIdentifier")
    private static let nameSelector = NSSelectorFromString("importedByDisplayName")
    private static let prefetchSelector = NSSelectorFromString("setFetchPropertySets:")

    static let isAvailable = PHAsset.instancesRespond(to: propertiesSelector)

    /// Asks for the value to be loaded along with each item, instead of one lookup per item later.
    static func prefetch(on options: PHFetchOptions) {
        guard isAvailable, options.responds(to: prefetchSelector) else { return }
        options.setValue([propertySet], forKey: "fetchPropertySets")
    }

    static func read(_ asset: PHAsset) -> (bundleID: String, appName: String)? {
        guard isAvailable,
            let properties = asset.value(forKey: "curationProperties") as? NSObject,
            properties.responds(to: bundleSelector),
            let bundleID = properties.value(forKey: "importedByBundleIdentifier") as? String,
            !bundleID.isEmpty
        else { return nil }
        var appName = ""
        if properties.responds(to: nameSelector) {
            appName = properties.value(forKey: "importedByDisplayName") as? String ?? ""
        }
        return (bundleID, appName)
    }
}

/// Looks through the whole library for the things most worth clearing out: items stored more
/// than once, very large videos, and whatever other apps saved in bulk.
enum CleanupScanner {
    struct Result {
        /// The queues the scan found something for, in sidebar order.
        var queues: [SweepQueue]
        var members: [QueueKind: [String]]
        var duplicateGroups: [DuplicateGroup]
        /// File sizes measured during this scan that were not already known.
        var measured: [String: Int64]
        var scannedCount: Int
        var lookAlikeCount: Int
        var sourcesAvailable: Bool
    }

    /// Returns nil if `isCancelled` turned true part-way. `progress` gets 0...1.
    /// Only reads from the library.
    static func scan(
        knownSizes: [String: Int64],
        kept: Set<String> = [],
        marked: Set<String> = [],
        isCancelled: @escaping () -> Bool = { false },
        progress: @escaping (Double) -> Void = { _ in }
    ) -> Result? {
        let all = PhotoLibrary.fetch(.all, withSources: true)
        let total = max(all.count, 1)
        var assets: [String: PHAsset] = [:]
        var items: [DuplicateCandidate] = []
        var videoIDs: [String] = []
        var sources: [ItemSource] = []
        assets.reserveCapacity(all.count)
        items.reserveCapacity(all.count)
        var cancelled = false

        // Pass 1 is cheap: these values are already loaded with each item.
        all.enumerateObjects { asset, index, stop in
            if index % 500 == 0 {
                if isCancelled() {
                    cancelled = true
                    stop.pointee = true
                    return
                }
                progress(0.3 * Double(index) / Double(total))
            }
            let id = asset.localIdentifier
            assets[id] = asset
            if asset.mediaType == .video { videoIDs.append(id) }
            if let source = ImportSource.read(asset) {
                sources.append(ItemSource(id: id, bundleID: source.bundleID, appName: source.appName))
            }
            items.append(
                DuplicateCandidate(
                    id: id,
                    mediaType: asset.mediaType.rawValue,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    creationSecond: asset.creationDate.map { Int64($0.timeIntervalSinceReferenceDate.rounded(.down)) },
                    durationMillis: Int64((asset.duration * 1000).rounded()),
                    isFavorite: asset.isFavorite))
        }
        if cancelled { return nil }

        // Pass 2 measures file sizes, but only where they matter: items that already look alike,
        // and videos.
        let candidates = DuplicateFinder.candidates(items)
        var needed = Set(candidates.joined().map(\.id))
        needed.formUnion(videoIDs)
        let toMeasure = needed.filter { knownSizes[$0] == nil }
        var measured: [String: Int64] = [:]
        for (index, id) in toMeasure.enumerated() {
            if index % 50 == 0 {
                if isCancelled() { return nil }
                progress(0.3 + 0.7 * Double(index) / Double(max(toMeasure.count, 1)))
            }
            guard let asset = assets[id] else { continue }
            let bytes = AssetSizer.bytes(for: asset)
            if bytes > 0 { measured[id] = bytes }
        }
        if isCancelled() { return nil }
        let sizes = knownSizes.merging(measured) { $1 }

        var queues: [SweepQueue] = []
        var members: [QueueKind: [String]] = [:]
        func add(_ kind: QueueKind, _ title: String, _ symbol: String, _ ids: [String]) {
            guard !ids.isEmpty else { return }
            members[kind] = ids
            queues.append(SweepQueue(kind: kind, title: title, symbol: symbol, section: .cleanup, count: ids.count))
        }

        let groups = DuplicateFinder.groups(candidates, sizes: sizes, kept: kept, marked: marked)
        add(.duplicates, "Duplicates", "square.on.square", DuplicateFinder.extras(groups))
        add(.largeVideos, "Large Videos", "film", LargeItems.select(videoIDs, sizes: sizes))
        for group in SourceGrouping.groups(sources) {
            add(.savedBy(group.bundleID), "From \(group.appName)", "square.and.arrow.down", group.ids)
        }

        progress(1)
        return Result(
            queues: queues,
            members: members,
            duplicateGroups: groups,
            measured: measured,
            scannedCount: items.count,
            lookAlikeCount: candidates.reduce(0) { $0 + $1.count },
            sourcesAvailable: ImportSource.isAvailable)
    }
}

enum AssetSizer {
    private static let fileSizeSelector = NSSelectorFromString("fileSize")

    /// Bytes this item takes up, summed over all of its files (original, edits, Live Photo video).
    /// Returns 0 when the system does not report a size.
    static func bytes(for asset: PHAsset) -> Int64 {
        var total: Int64 = 0
        for resource in PHAssetResource.assetResources(for: asset)
        where resource.responds(to: fileSizeSelector) {
            if let number = resource.value(forKey: "fileSize") as? NSNumber {
                total += number.int64Value
            }
        }
        return total
    }
}

enum ImagePipeline {
    static let manager = PHCachingImageManager()

    /// One fixed size for every card, so preloading the next cards hits the same cache entries.
    static let cardSize = CGSize(width: 1800, height: 1800)
    static let thumbnailSize = CGSize(width: 360, height: 360)

    /// The last few full-size card images, so a card that moves from "next" to "current" shows instantly.
    static let recentCards: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        return cache
    }()

    static func options(
        delivery: PHImageRequestOptionsDeliveryMode = .opportunistic,
        progress: PHAssetImageProgressHandler? = nil
    ) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = delivery
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true  // originals live in iCloud
        options.progressHandler = progress
        return options
    }

    static func preheat(_ assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        manager.startCachingImages(
            for: assets, targetSize: cardSize, contentMode: .aspectFit, options: options())
    }

    static func stopPreheating() {
        manager.stopCachingImagesForAllAssets()
    }
}

enum Format {
    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        value > 0 ? bytesFormatter.string(fromByteCount: value) : "size unknown"
    }

    static func date(_ value: Date?) -> String {
        value.map(dateFormatter.string(from:)) ?? "no date"
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }
}
