import Foundation

/// The facts about one library item that are cheap to read and enough to suspect a duplicate.
public struct DuplicateCandidate: Equatable, Sendable {
    public let id: String
    public let mediaType: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// When it was taken, in whole seconds. Items with no date are never matched.
    public let creationSecond: Int64?
    /// Video length in milliseconds; 0 for photos.
    public let durationMillis: Int64
    public let isFavorite: Bool

    public init(
        id: String, mediaType: Int, pixelWidth: Int, pixelHeight: Int,
        creationSecond: Int64?, durationMillis: Int64 = 0, isFavorite: Bool = false
    ) {
        self.id = id
        self.mediaType = mediaType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationSecond = creationSecond
        self.durationMillis = durationMillis
        self.isFavorite = isFavorite
    }
}

/// One set of identical items: the copy to keep and the extra copies.
public struct DuplicateGroup: Equatable, Sendable {
    public let keeper: String
    public let extras: [String]

    public init(keeper: String, extras: [String]) {
        self.keeper = keeper
        self.extras = extras
    }
}

/// Finds duplicates in two passes, so the slow part (file sizes) only runs on likely matches.
public enum DuplicateFinder {
    private struct Signature: Hashable {
        let mediaType: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let creationSecond: Int64
        let durationMillis: Int64
    }

    /// First pass: items that share media type, pixel size, creation time and duration.
    /// Only sets of two or more are returned, in the order they first appear.
    public static func candidates(_ items: [DuplicateCandidate]) -> [[DuplicateCandidate]] {
        var order: [Signature] = []
        var sets: [Signature: [DuplicateCandidate]] = [:]
        for item in items {
            guard let second = item.creationSecond else { continue }
            let signature = Signature(
                mediaType: item.mediaType, pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight,
                creationSecond: second, durationMillis: item.durationMillis)
            if sets[signature] == nil { order.append(signature) }
            sets[signature, default: []].append(item)
        }
        return order.compactMap { signature in
            guard let set = sets[signature], set.count > 1 else { return nil }
            return set
        }
    }

    /// Second pass: within each candidate set, items are duplicates only if their file sizes are
    /// known and equal. One copy per group is kept: never one already marked for deletion if an
    /// unmarked copy exists, then a favorite, then one the user chose to keep, then the first seen.
    public static func groups(
        _ candidates: [[DuplicateCandidate]],
        sizes: [String: Int64],
        kept: Set<String> = [],
        marked: Set<String> = []
    ) -> [DuplicateGroup] {
        var result: [DuplicateGroup] = []
        for set in candidates {
            var order: [Int64] = []
            var bySize: [Int64: [DuplicateCandidate]] = [:]
            for item in set {
                guard let size = sizes[item.id], size > 0 else { continue }
                if bySize[size] == nil { order.append(size) }
                bySize[size, default: []].append(item)
            }
            for size in order {
                guard let copies = bySize[size], copies.count > 1 else { continue }
                func rank(_ item: DuplicateCandidate) -> Int {
                    (marked.contains(item.id) ? 0 : 4) + (item.isFavorite ? 2 : 0) + (kept.contains(item.id) ? 1 : 0)
                }
                var keeperIndex = 0
                for index in copies.indices where rank(copies[index]) > rank(copies[keeperIndex]) {
                    keeperIndex = index
                }
                var extras = copies.map(\.id)
                let keeper = extras.remove(at: keeperIndex)
                result.append(DuplicateGroup(keeper: keeper, extras: extras))
            }
        }
        return result
    }

    /// Every extra copy across all groups, in order. These are what a duplicates queue shows.
    public static func extras(_ groups: [DuplicateGroup]) -> [String] {
        groups.flatMap(\.extras)
    }
}
