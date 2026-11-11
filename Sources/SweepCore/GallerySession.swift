import Foundation

/// The changes made by clicking around a gallery of one queue, with undo.
///
/// Swiping decides items in order, so undo there is "step back one card". In a gallery any item
/// can be clicked at any time, so each action remembers what the items were before it.
public struct GallerySession: Equatable, Sendable {
    private struct Step: Equatable, Sendable {
        let id: String
        let before: Decision?
    }

    private var actions: [[Step]] = []
    /// The decision an item had before it was marked here, so un-marking can put it back.
    private var beforeMark: [String: Decision] = [:]

    /// True once anything was changed, even if it was undone again.
    public private(set) var hasChanges = false

    public init() {}

    public var canUndo: Bool { !actions.isEmpty }

    /// A click: puts the item on the delete list, or takes it back off.
    /// Taking it off returns it to what it was before: kept, or undecided.
    public mutating func toggleMark(_ id: String, in store: inout SweepStore, bytes: Int64? = nil) {
        let before = store.decision(for: id)
        if before == .delete {
            store.restore(beforeMark[id], for: id)
        } else {
            beforeMark[id] = before
            store.apply(.delete, to: id, bytes: bytes)
        }
        actions.append([Step(id: id, before: before)])
        hasChanges = true
    }

    /// Keeps every item in `ids` that has no decision yet, as one action.
    /// Items already kept or marked are left alone. Returns the items that were kept.
    @discardableResult
    public mutating func keepUndecided(_ ids: [String], in store: inout SweepStore) -> [String] {
        let decided = store.kept.union(store.marked)
        let undecided = ids.filter { !decided.contains($0) }
        guard !undecided.isEmpty else { return [] }
        store.keepAll(undecided)
        actions.append(undecided.map { Step(id: $0, before: nil) })
        hasChanges = true
        return undecided
    }

    /// Takes back the last action. Returns the items whose decision changed.
    /// `bytes` supplies the size for an item that goes back onto the delete list.
    @discardableResult
    public mutating func undo(in store: inout SweepStore, bytes: (String) -> Int64? = { _ in nil }) -> [String] {
        guard let steps = actions.popLast() else { return [] }
        store.clearDecisions(for: Set(steps.filter { $0.before == nil }.map(\.id)))
        for step in steps {
            guard let before = step.before else { continue }
            store.restore(before, for: step.id, bytes: before == .delete ? bytes(step.id) : nil)
        }
        return steps.map(\.id)
    }
}
