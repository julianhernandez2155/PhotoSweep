import Foundation

/// What the user has decided so far, across every queue and across launches.
public struct SweepStore: Codable, Equatable, Sendable {
    /// Items the user chose to keep. They are left out of every queue from then on.
    public private(set) var kept: Set<String>
    /// Items waiting to be deleted, in the order they were marked.
    public private(set) var marked: [String]
    /// Byte size of each marked item, when it is known.
    public private(set) var markedBytes: [String: Int64]
    /// Running totals for everything deleted through the app.
    public private(set) var deletedCount: Int
    public private(set) var freedBytes: Int64

    public init() {
        kept = []
        marked = []
        markedBytes = [:]
        deletedCount = 0
        freedBytes = 0
    }

    private enum CodingKeys: String, CodingKey {
        case kept, marked, markedBytes, deletedCount, freedBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kept = try c.decodeIfPresent(Set<String>.self, forKey: .kept) ?? []
        marked = try c.decodeIfPresent([String].self, forKey: .marked) ?? []
        markedBytes = try c.decodeIfPresent([String: Int64].self, forKey: .markedBytes) ?? [:]
        deletedCount = try c.decodeIfPresent(Int.self, forKey: .deletedCount) ?? 0
        freedBytes = try c.decodeIfPresent(Int64.self, forKey: .freedBytes) ?? 0
    }

    public var totalMarkedBytes: Int64 {
        marked.reduce(0) { $0 + (markedBytes[$1] ?? 0) }
    }

    public func isMarked(_ id: String) -> Bool { marked.contains(id) }
    public func isKept(_ id: String) -> Bool { kept.contains(id) }

    /// The decision on an item, or nil if it has none yet.
    public func decision(for id: String) -> Decision? {
        if kept.contains(id) { return .keep }
        return marked.contains(id) ? .delete : nil
    }

    /// Puts an item back the way it was before a swipe: its earlier decision, or none.
    /// Used by undo when the swipe replaced a decision made before.
    public mutating func restore(_ earlier: Decision?, for id: String, bytes: Int64? = nil) {
        if let earlier {
            apply(earlier, to: id, bytes: bytes)
        } else {
            clearDecision(for: id)
        }
    }

    /// Records a decision. Deciding again on the same item replaces the earlier decision.
    public mutating func apply(_ decision: Decision, to id: String, bytes: Int64? = nil) {
        switch decision {
        case .keep:
            removeFromMarked([id])
            kept.insert(id)
        case .delete:
            kept.remove(id)
            if !marked.contains(id) { marked.append(id) }
            if let bytes { markedBytes[id] = bytes }
        }
    }

    /// Forgets any decision on an item, so it shows up in queues again. Used by undo.
    public mutating func clearDecision(for id: String) {
        kept.remove(id)
        removeFromMarked([id])
    }

    /// Takes an item out of the delete list and keeps it instead.
    public mutating func unmark(_ id: String) {
        apply(.keep, to: id)
    }

    /// Fills in a size for a marked item that was marked before its size was known.
    public mutating func setBytes(_ bytes: Int64, forMarked id: String) {
        guard marked.contains(id) else { return }
        markedBytes[id] = bytes
    }

    /// Fills in sizes for many marked items at once. Items that are not marked are ignored.
    public mutating func setBytes(_ sizes: [String: Int64]) {
        guard !sizes.isEmpty else { return }
        let current = Set(marked)
        for (id, bytes) in sizes where current.contains(id) { markedBytes[id] = bytes }
    }

    /// Marks many items for deletion in one step, replacing any earlier decision on them.
    /// Built for thousands of items, where marking one at a time would be slow.
    public mutating func markAll(_ ids: [String], bytes: [String: Int64] = [:]) {
        var current = Set(marked)
        for id in ids {
            kept.remove(id)
            if current.insert(id).inserted { marked.append(id) }
            if let size = bytes[id] { markedBytes[id] = size }
        }
    }

    /// Keeps many items in one step, replacing any earlier decision on them.
    public mutating func keepAll(_ ids: [String]) {
        removeFromMarked(Set(ids).intersection(marked))
        kept.formUnion(ids)
    }

    /// Forgets the decisions on many items at once.
    public mutating func clearDecisions(for ids: Set<String>) {
        kept.subtract(ids)
        removeFromMarked(ids)
    }

    /// Call after the library confirms these items were deleted. Moves them into the totals.
    public mutating func recordDeletion(of ids: [String]) {
        let present = Set(marked).intersection(ids)
        guard !present.isEmpty else { return }
        deletedCount += present.count
        freedBytes += present.reduce(Int64(0)) { $0 + (markedBytes[$1] ?? 0) }
        removeFromMarked(present)
    }

    /// Drops marked items that are gone from the library without counting them as freed.
    public mutating func dropMarked(_ ids: Set<String>) {
        removeFromMarked(ids)
    }

    /// Clears every keep and delete decision. Lifetime totals stay.
    public mutating func resetProgress() {
        kept = []
        marked = []
        markedBytes = [:]
    }

    /// The items from `ids` that still need a decision, in the same order.
    public func pending(_ ids: [String]) -> [String] {
        let decided = kept.union(marked)
        return ids.filter { !decided.contains($0) }
    }

    private mutating func removeFromMarked(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        marked.removeAll { ids.contains($0) }
        for id in ids { markedBytes[id] = nil }
    }
}

public enum SizeOrdering {
    /// Largest first. Items with no known size go last. Ties keep their incoming order.
    public static func largestFirst(_ ids: [String], sizes: [String: Int64]) -> [String] {
        ids.enumerated()
            .sorted { a, b in
                let sa = sizes[a.element] ?? -1
                let sb = sizes[b.element] ?? -1
                return sa == sb ? a.offset < b.offset : sa > sb
            }
            .map(\.element)
    }
}
