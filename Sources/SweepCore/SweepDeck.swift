import Foundation

public enum Decision: String, Codable, Sendable {
    case keep
    case delete
}

/// An ordered run of item IDs with a cursor. Everything before the cursor has been decided,
/// and `history` holds those decisions in order, so undo is just popping the last one.
public struct SweepDeck: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let decision: Decision

        public init(id: String, decision: Decision) {
            self.id = id
            self.decision = decision
        }
    }

    public private(set) var ids: [String]
    public private(set) var history: [Entry] = []
    /// How many decisions at the end of `history` came from one "decide everything left" action.
    /// That action always finishes the deck, so the batch is always the newest part of the history.
    public private(set) var batchCount = 0

    public init(ids: [String] = []) {
        self.ids = ids
    }

    /// The current item and everything after it.
    public var remainingIDs: [String] { Array(ids[min(cursor, ids.count)...]) }

    /// Index of the item currently on top. Equals the number of decisions made.
    public var cursor: Int { history.count }
    public var total: Int { ids.count }
    public var remaining: Int { ids.count - cursor }
    public var isFinished: Bool { cursor >= ids.count }
    public var canUndo: Bool { !history.isEmpty }

    /// 1-based position of the current item, clamped to the total once finished.
    public var position: Int { min(cursor + 1, ids.count) }

    public var current: String? { isFinished ? nil : ids[cursor] }

    /// The items after the current one, nearest first.
    public func upcoming(_ count: Int) -> [String] {
        let start = cursor + 1
        guard count > 0, start < ids.count else { return [] }
        return Array(ids[start..<min(start + count, ids.count)])
    }

    /// Records a decision for the current item and advances. Returns nil when the deck is finished.
    @discardableResult
    public mutating func decide(_ decision: Decision) -> Entry? {
        guard let id = current else { return nil }
        let entry = Entry(id: id, decision: decision)
        history.append(entry)
        return entry
    }

    /// Gives every remaining item the same decision in one step, finishing the deck.
    /// Returns the new decisions; `undoLast()` takes them all back together.
    @discardableResult
    public mutating func decideRemaining(_ decision: Decision) -> [Entry] {
        let entries = ids[min(cursor, ids.count)...].map { Entry(id: $0, decision: decision) }
        guard !entries.isEmpty else { return [] }
        history.append(contentsOf: entries)
        batchCount = entries.count
        return entries
    }

    /// Steps back one item and returns the decision that was undone.
    @discardableResult
    public mutating func undo() -> Entry? {
        guard let entry = history.popLast() else { return nil }
        if batchCount > 0 { batchCount -= 1 }
        return entry
    }

    /// Undoes the last action: one decision, or a whole `decideRemaining` batch at once.
    /// Returns what was undone, oldest first.
    @discardableResult
    public mutating func undoLast() -> [Entry] {
        guard batchCount > 0 else { return undo().map { [$0] } ?? [] }
        let start = history.count - batchCount
        let undone = Array(history[start...])
        history.removeSubrange(start...)
        batchCount = 0
        return undone
    }

    /// Drops items that no longer exist (for example after they were deleted from the library).
    public mutating func remove(_ removed: Set<String>) {
        guard !removed.isEmpty else { return }
        let batchStart = history.count - batchCount
        batchCount -= history[batchStart...].reduce(0) { $0 + (removed.contains($1.id) ? 1 : 0) }
        history.removeAll { removed.contains($0.id) }
        ids.removeAll { removed.contains($0) }
    }
}
