import Foundation

/// Which number a queue shows in the sidebar.
public enum CountMode: String, CaseIterable, Sendable {
    /// Everything in the queue.
    case all
    /// Only the items that have no keep or delete decision yet.
    case left
}

/// Counts, for every queue, how many items it holds and how many still need a decision.
///
/// Building it walks every queue once, which is slow enough to do off the main thread for a big
/// library. After that, recording a decision only touches the queues that contain that one item,
/// so the counts can follow every swipe without any re-counting.
public struct QueueTally<Key: Hashable & Sendable>: Sendable {
    private var membersByQueue: [Key: [String]] = [:]
    private var queuesByItem: [String: [Key]] = [:]
    private var decidedCounts: [Key: Int] = [:]
    private var decided: Set<String> = []

    public init() {}

    /// `members` lists the item IDs in each queue. An item may be in any number of queues.
    public init(members: [Key: [String]], decided: Set<String> = []) {
        self.decided = decided
        for (key, ids) in members { insert(ids, for: key) }
    }

    /// How many items the queue holds.
    public func total(_ key: Key) -> Int {
        membersByQueue[key]?.count ?? 0
    }

    /// How many items in the queue have no decision yet.
    public func left(_ key: Key) -> Int {
        total(key) - (decidedCounts[key] ?? 0)
    }

    public func count(_ key: Key, mode: CountMode) -> Int {
        mode == .all ? total(key) : left(key)
    }

    public func isDecided(_ id: String) -> Bool {
        decided.contains(id)
    }

    /// Records that an item now has a decision, or no longer has one.
    public mutating func setDecided(_ id: String, _ isDecided: Bool) {
        if isDecided {
            guard decided.insert(id).inserted else { return }
        } else {
            guard decided.remove(id) != nil else { return }
        }
        guard let keys = queuesByItem[id] else { return }
        for key in keys { decidedCounts[key, default: 0] += isDecided ? 1 : -1 }
    }

    public mutating func setDecided<S: Sequence>(_ ids: S, _ isDecided: Bool) where S.Element == String {
        for id in ids { setDecided(id, isDecided) }
    }

    /// Brings the tally in line with the full set of decided items, changing only what differs.
    public mutating func syncDecided(_ current: Set<String>) {
        for id in decided.subtracting(current) { setDecided(id, false) }
        for id in current.subtracting(decided) { setDecided(id, true) }
    }

    /// Adds a queue, or replaces its contents. An empty list removes it.
    public mutating func setMembers(_ ids: [String], for key: Key) {
        if let old = membersByQueue.removeValue(forKey: key) {
            for id in old {
                guard var keys = queuesByItem[id] else { continue }
                keys.removeAll { $0 == key }
                queuesByItem[id] = keys.isEmpty ? nil : keys
            }
            decidedCounts[key] = nil
        }
        if !ids.isEmpty { insert(ids, for: key) }
    }

    private mutating func insert(_ ids: [String], for key: Key) {
        var seen = Set<String>()
        seen.reserveCapacity(ids.count)
        var unique: [String] = []
        unique.reserveCapacity(ids.count)
        var decidedHere = 0
        for id in ids where seen.insert(id).inserted {
            unique.append(id)
            queuesByItem[id, default: []].append(key)
            if decided.contains(id) { decidedHere += 1 }
        }
        membersByQueue[key] = unique
        decidedCounts[key] = decidedHere
    }
}
