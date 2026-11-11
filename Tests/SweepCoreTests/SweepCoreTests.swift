// All tests live in this one file on purpose. With only the Command Line Tools installed (no Xcode),
// a test target with more than one file fails to find the Swift Testing macro plugin.
import Foundation
import Testing
@testable import SweepCore

@Suite struct SweepDeckTests {
    @Test func startsOnFirstItem() {
        let deck = SweepDeck(ids: ["a", "b", "c"])
        #expect(deck.current == "a")
        #expect(deck.position == 1)
        #expect(deck.total == 3)
        #expect(deck.remaining == 3)
        #expect(!deck.canUndo)
        #expect(!deck.isFinished)
    }

    @Test func decidingAdvancesAndRecordsHistory() {
        var deck = SweepDeck(ids: ["a", "b", "c"])
        let entry = deck.decide(.delete)
        #expect(entry == SweepDeck.Entry(id: "a", decision: .delete))
        #expect(deck.current == "b")
        #expect(deck.position == 2)
        #expect(deck.remaining == 2)
        #expect(deck.canUndo)
    }

    @Test func finishesAfterLastItemAndIgnoresFurtherDecisions() {
        var deck = SweepDeck(ids: ["a", "b"])
        deck.decide(.keep)
        deck.decide(.delete)
        #expect(deck.isFinished)
        #expect(deck.current == nil)
        #expect(deck.position == 2)
        #expect(deck.decide(.keep) == nil)
        #expect(deck.history.count == 2)
    }

    @Test func undoReturnsToPreviousItem() {
        var deck = SweepDeck(ids: ["a", "b", "c"])
        deck.decide(.keep)
        deck.decide(.delete)
        let undone = deck.undo()
        #expect(undone == SweepDeck.Entry(id: "b", decision: .delete))
        #expect(deck.current == "b")
        #expect(deck.undo()?.id == "a")
        #expect(deck.current == "a")
        #expect(deck.undo() == nil)
    }

    @Test func undoWorksFromFinishedState() {
        var deck = SweepDeck(ids: ["a"])
        deck.decide(.delete)
        #expect(deck.isFinished)
        deck.undo()
        #expect(deck.current == "a")
    }

    @Test func upcomingListsItemsAfterCurrent() {
        var deck = SweepDeck(ids: ["a", "b", "c", "d"])
        #expect(deck.upcoming(2) == ["b", "c"])
        #expect(deck.upcoming(10) == ["b", "c", "d"])
        deck.decide(.keep)
        deck.decide(.keep)
        deck.decide(.keep)
        #expect(deck.upcoming(3) == [])
        #expect(deck.upcoming(0) == [])
    }

    @Test func removingItemsKeepsCursorOnTheSameItem() {
        var deck = SweepDeck(ids: ["a", "b", "c", "d", "e"])
        deck.decide(.delete)  // a
        deck.decide(.keep)    // b
        deck.decide(.delete)  // c
        #expect(deck.current == "d")
        deck.remove(["a", "c"])
        #expect(deck.ids == ["b", "d", "e"])
        #expect(deck.current == "d")
        #expect(deck.history.map(\.id) == ["b"])
        #expect(deck.undo()?.id == "b")
        #expect(deck.current == "b")
    }

    @Test func removingUndecidedItemsShrinksTheQueue() {
        var deck = SweepDeck(ids: ["a", "b", "c"])
        deck.remove(["a", "c"])
        #expect(deck.current == "b")
        #expect(deck.total == 1)
    }

    @Test func emptyDeckIsFinished() {
        var deck = SweepDeck()
        #expect(deck.isFinished)
        #expect(deck.current == nil)
        #expect(deck.position == 0)
        #expect(deck.undo() == nil)
    }
}

@Suite struct SweepStoreTests {
    @Test func markingForDeletionTracksSize() {
        var store = SweepStore()
        store.apply(.delete, to: "a", bytes: 1_000)
        store.apply(.delete, to: "b", bytes: 500)
        #expect(store.marked == ["a", "b"])
        #expect(store.totalMarkedBytes == 1_500)
        #expect(store.isMarked("a"))
        #expect(!store.isKept("a"))
    }

    @Test func markingTwiceDoesNotDuplicate() {
        var store = SweepStore()
        store.apply(.delete, to: "a", bytes: 10)
        store.apply(.delete, to: "a", bytes: 10)
        #expect(store.marked == ["a"])
        #expect(store.totalMarkedBytes == 10)
    }

    @Test func changingDecisionReplacesTheOldOne() {
        var store = SweepStore()
        store.apply(.delete, to: "a", bytes: 10)
        store.apply(.keep, to: "a")
        #expect(store.marked.isEmpty)
        #expect(store.totalMarkedBytes == 0)
        #expect(store.isKept("a"))
        store.apply(.delete, to: "a", bytes: 10)
        #expect(!store.isKept("a"))
        #expect(store.marked == ["a"])
    }

    @Test func clearDecisionMakesItemPendingAgain() {
        var store = SweepStore()
        store.apply(.keep, to: "a")
        store.apply(.delete, to: "b", bytes: 5)
        store.clearDecision(for: "a")
        store.clearDecision(for: "b")
        #expect(store.pending(["a", "b"]) == ["a", "b"])
        #expect(store.totalMarkedBytes == 0)
    }

    @Test func unmarkKeepsTheItem() {
        var store = SweepStore()
        store.apply(.delete, to: "a", bytes: 5)
        store.unmark("a")
        #expect(store.marked.isEmpty)
        #expect(store.isKept("a"))
    }

    @Test func pendingLeavesOutKeptAndMarkedInOrder() {
        var store = SweepStore()
        store.apply(.keep, to: "b")
        store.apply(.delete, to: "d", bytes: 1)
        #expect(store.pending(["a", "b", "c", "d", "e"]) == ["a", "c", "e"])
    }

    @Test func recordDeletionMovesItemsIntoTotals() {
        var store = SweepStore()
        store.apply(.delete, to: "a", bytes: 100)
        store.apply(.delete, to: "b", bytes: 200)
        store.apply(.delete, to: "c", bytes: 300)
        store.recordDeletion(of: ["a", "c", "not-marked"])
        #expect(store.marked == ["b"])
        #expect(store.deletedCount == 2)
        #expect(store.freedBytes == 400)
        #expect(store.totalMarkedBytes == 200)
    }

    @Test func dropMarkedDoesNotCountAsFreed() {
        var store = SweepStore()
        store.apply(.delete, to: "a", bytes: 100)
        store.dropMarked(["a"])
        #expect(store.marked.isEmpty)
        #expect(store.deletedCount == 0)
        #expect(store.freedBytes == 0)
    }

    @Test func setBytesOnlyAppliesToMarkedItems() {
        var store = SweepStore()
        store.apply(.delete, to: "a")
        #expect(store.totalMarkedBytes == 0)
        store.setBytes(42, forMarked: "a")
        store.setBytes(99, forMarked: "ghost")
        #expect(store.totalMarkedBytes == 42)
        #expect(store.markedBytes["ghost"] == nil)
    }

    @Test func resetProgressKeepsLifetimeTotals() {
        var store = SweepStore()
        store.apply(.keep, to: "k")
        store.apply(.delete, to: "a", bytes: 100)
        store.recordDeletion(of: ["a"])
        store.apply(.delete, to: "b", bytes: 50)
        store.resetProgress()
        #expect(store.kept.isEmpty)
        #expect(store.marked.isEmpty)
        #expect(store.totalMarkedBytes == 0)
        #expect(store.deletedCount == 1)
        #expect(store.freedBytes == 100)
    }
}

@Suite struct DeckAndStoreTogetherTests {
    /// The flow the app runs: decide, undo, decide differently, across a relaunch.
    @Test func undoThenRedecideAcrossRelaunch() {
        let library = ["a", "b", "c", "d"]
        var store = SweepStore()
        var deck = SweepDeck(ids: store.pending(library))

        func decide(_ d: Decision) {
            if let entry = deck.decide(d) { store.apply(d, to: entry.id, bytes: 10) }
        }
        decide(.delete)  // a
        decide(.delete)  // b
        if let undone = deck.undo() { store.clearDecision(for: undone.id) }
        #expect(deck.current == "b")
        decide(.keep)    // b, changed mind

        #expect(store.marked == ["a"])
        #expect(store.isKept("b"))

        // Next launch: only undecided items come back.
        let relaunched = SweepDeck(ids: store.pending(library))
        #expect(relaunched.ids == ["c", "d"])
    }
}

@Suite struct SizeOrderingTests {
    @Test func largestFirstWithUnknownsLastAndStableTies() {
        let ordered = SizeOrdering.largestFirst(
            ["small", "unknown", "big", "tieA", "tieB"],
            sizes: ["small": 1, "big": 900, "tieA": 50, "tieB": 50])
        #expect(ordered == ["big", "tieA", "tieB", "small", "unknown"])
    }
}

@Suite struct JSONFileTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("photosweep-tests-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
    }

    @Test func roundTripsAStore() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = SweepStore()
        store.apply(.keep, to: "k")
        store.apply(.delete, to: "a", bytes: 123)
        store.apply(.delete, to: "b", bytes: 7)
        store.recordDeletion(of: ["b"])

        let file = JSONFile<SweepStore>(url: url)
        try file.save(store)
        #expect(file.load(default: SweepStore()) == store)
    }

    @Test func missingFileGivesDefault() {
        let file = JSONFile<SweepStore>(url: tempURL())
        #expect(file.load(default: SweepStore()) == SweepStore())
    }

    @Test func corruptFileIsMovedAsideNotOverwritten() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)

        let file = JSONFile<SweepStore>(url: url)
        #expect(file.load(default: SweepStore()) == SweepStore())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let aside = url.appendingPathExtension("corrupt")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{ not json")
    }

    @Test func olderFileWithMissingFieldsStillLoads() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"kept":["k"]}"#.utf8).write(to: url)

        let store = JSONFile<SweepStore>(url: url).load(default: SweepStore())
        #expect(store.isKept("k"))
        #expect(store.marked.isEmpty)
        #expect(store.freedBytes == 0)
    }
}

@Suite struct QueueTallyTests {
    private func sample(decided: Set<String> = []) -> QueueTally<String> {
        QueueTally(
            members: ["all": ["a", "b", "c", "d"], "videos": ["c", "d"], "album": ["a", "c"]],
            decided: decided)
    }

    @Test func totalsCountEveryItemAndLeftSkipsDecidedOnes() {
        let tally = sample(decided: ["a", "c"])
        #expect(tally.total("all") == 4)
        #expect(tally.left("all") == 2)
        #expect(tally.left("videos") == 1)
        #expect(tally.left("album") == 0)
        #expect(tally.count("album", mode: .all) == 2)
        #expect(tally.count("album", mode: .left) == 0)
    }

    @Test func aSwipeUpdatesEveryQueueThatHoldsTheItem() {
        var tally = sample()
        tally.setDecided("c", true)
        #expect(tally.left("all") == 3)
        #expect(tally.left("videos") == 1)
        #expect(tally.left("album") == 1)
        tally.setDecided("b", true)
        #expect(tally.left("all") == 2)
        #expect(tally.left("videos") == 1)
    }

    @Test func undoPutsTheItemBack() {
        var tally = sample(decided: ["c"])
        tally.setDecided("c", false)
        #expect(tally.left("all") == 4)
        #expect(tally.left("videos") == 2)
        #expect(!tally.isDecided("c"))
    }

    @Test func decidingTheSameItemTwiceCountsOnce() {
        var tally = sample()
        tally.setDecided("a", true)
        tally.setDecided("a", true)
        #expect(tally.left("all") == 3)
        tally.setDecided("a", false)
        tally.setDecided("a", false)
        #expect(tally.left("all") == 4)
    }

    @Test func decisionsOnItemsOutsideEveryQueueChangeNothing() {
        var tally = sample()
        tally.setDecided("gone", true)
        #expect(tally.left("all") == 4)
        #expect(tally.isDecided("gone"))
    }

    @Test func unknownQueueCountsAsEmpty() {
        let tally = sample()
        #expect(tally.total("nope") == 0)
        #expect(tally.left("nope") == 0)
    }

    @Test func syncMatchesAFullSetOfDecisions() {
        var tally = sample(decided: ["a", "b"])
        tally.syncDecided(["b", "d"])
        #expect(tally.left("all") == 2)
        #expect(tally.left("videos") == 1)
        #expect(tally.left("album") == 2)
        tally.syncDecided([])
        #expect(tally.left("all") == 4)
    }

    @Test func aQueueCanBeAddedReplacedAndRemovedLater() {
        var tally = sample(decided: ["a"])
        tally.setMembers(["a", "b"], for: "duplicates")
        #expect(tally.total("duplicates") == 2)
        #expect(tally.left("duplicates") == 1)

        tally.setMembers(["b", "d"], for: "duplicates")
        #expect(tally.left("duplicates") == 2)
        tally.setDecided("a", false)  // no longer in duplicates, so its count must not move
        #expect(tally.left("duplicates") == 2)
        tally.setDecided("d", true)
        #expect(tally.left("duplicates") == 1)

        tally.setMembers([], for: "duplicates")
        #expect(tally.total("duplicates") == 0)
        #expect(tally.left("duplicates") == 0)
        #expect(tally.left("all") == 3)
    }

    @Test func anItemListedTwiceInAQueueCountsOnce() {
        var tally = QueueTally(members: ["q": ["a", "a", "b"]])
        #expect(tally.total("q") == 2)
        tally.setDecided("a", true)
        #expect(tally.left("q") == 1)
    }

    @Test func staysFastOnALibraryOf32000Items() {
        let ids = (0..<32_000).map { "item-\($0)" }
        var members: [String: [String]] = ["all": ids]
        for queue in 0..<40 {
            members["album-\(queue)"] = ids.enumerated().filter { $0.offset % 40 == queue }.map(\.element)
        }
        var tally = QueueTally(members: members)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for id in ids.prefix(5_000) { tally.setDecided(id, true) }
        }
        #expect(tally.left("all") == 27_000)
        #expect(tally.left("album-0") == 800 - 125)
        // 5,000 swipes' worth of updates. Even a slow test machine finishes far inside this.
        #expect(elapsed < .seconds(1))
    }
}

@Suite struct DuplicateFinderTests {
    private func photo(
        _ id: String, at second: Int64? = 100, width: Int = 4032, height: Int = 3024, favorite: Bool = false
    ) -> DuplicateCandidate {
        DuplicateCandidate(
            id: id, mediaType: 1, pixelWidth: width, pixelHeight: height,
            creationSecond: second, isFavorite: favorite)
    }

    private func video(_ id: String, at second: Int64 = 100, millis: Int64) -> DuplicateCandidate {
        DuplicateCandidate(
            id: id, mediaType: 2, pixelWidth: 1920, pixelHeight: 1080,
            creationSecond: second, durationMillis: millis)
    }

    @Test func candidatesNeedMatchingTypeSizeDateAndDuration() {
        let items = [
            photo("a"), photo("b"),  // match
            photo("c", at: 101),  // different second
            photo("d", width: 3024, height: 4032),  // rotated dimensions
            video("v1", millis: 5_000), video("v2", millis: 5_000),  // match
            video("v3", millis: 5_001),  // different length
        ]
        let sets = DuplicateFinder.candidates(items).map { $0.map(\.id) }
        #expect(sets == [["a", "b"], ["v1", "v2"]])
    }

    @Test func aPhotoAndAVideoNeverMatch() {
        let still = DuplicateCandidate(id: "p", mediaType: 1, pixelWidth: 1920, pixelHeight: 1080, creationSecond: 5)
        let clip = DuplicateCandidate(id: "v", mediaType: 2, pixelWidth: 1920, pixelHeight: 1080, creationSecond: 5)
        #expect(DuplicateFinder.candidates([still, clip]).isEmpty)
    }

    @Test func itemsWithNoDateAreNeverMatched() {
        #expect(DuplicateFinder.candidates([photo("a", at: nil), photo("b", at: nil)]).isEmpty)
    }

    @Test func fileSizeConfirmsOrRejectsACandidateSet() {
        let sets = DuplicateFinder.candidates([photo("a"), photo("b"), photo("c")])
        let groups = DuplicateFinder.groups(sets, sizes: ["a": 500, "b": 500, "c": 777])
        #expect(groups == [DuplicateGroup(keeper: "a", extras: ["b"])])
    }

    @Test func unknownSizesAreNeverTreatedAsDuplicates() {
        let sets = DuplicateFinder.candidates([photo("a"), photo("b"), photo("c")])
        #expect(DuplicateFinder.groups(sets, sizes: [:]).isEmpty)
        #expect(DuplicateFinder.groups(sets, sizes: ["a": 0, "b": 0, "c": 0]).isEmpty)
        #expect(DuplicateFinder.groups(sets, sizes: ["a": 500]).isEmpty)
    }

    @Test func oneCandidateSetCanHoldTwoSeparateGroups() {
        // A burst within the same second: two different shots, each imported twice.
        let sets = DuplicateFinder.candidates([photo("a"), photo("b"), photo("c"), photo("d")])
        let groups = DuplicateFinder.groups(sets, sizes: ["a": 500, "b": 900, "c": 500, "d": 900])
        #expect(groups == [
            DuplicateGroup(keeper: "a", extras: ["c"]),
            DuplicateGroup(keeper: "b", extras: ["d"]),
        ])
    }

    @Test func threeCopiesKeepOneAndListTwoExtras() {
        let sets = DuplicateFinder.candidates([photo("a"), photo("b"), photo("c")])
        let groups = DuplicateFinder.groups(sets, sizes: ["a": 500, "b": 500, "c": 500])
        #expect(groups == [DuplicateGroup(keeper: "a", extras: ["b", "c"])])
        #expect(DuplicateFinder.extras(groups) == ["b", "c"])
    }

    @Test func aFavoriteIsTheOneKept() {
        let sets = DuplicateFinder.candidates([photo("a"), photo("b", favorite: true), photo("c")])
        let groups = DuplicateFinder.groups(sets, sizes: ["a": 500, "b": 500, "c": 500])
        #expect(groups == [DuplicateGroup(keeper: "b", extras: ["a", "c"])])
    }

    @Test func aCopyTheUserAlreadyKeptIsPreferredOverAnUndecidedOne() {
        let sets = DuplicateFinder.candidates([photo("a"), photo("b")])
        let groups = DuplicateFinder.groups(sets, sizes: ["a": 500, "b": 500], kept: ["b"])
        #expect(groups == [DuplicateGroup(keeper: "b", extras: ["a"])])
    }

    @Test func aCopyAlreadyMarkedForDeletionIsNeverChosenAsTheKeeper() {
        // Otherwise the queue would offer the only surviving copy for deletion too.
        let sets = DuplicateFinder.candidates([photo("a", favorite: true), photo("b")])
        let groups = DuplicateFinder.groups(sets, sizes: ["a": 500, "b": 500], marked: ["a"])
        #expect(groups == [DuplicateGroup(keeper: "b", extras: ["a"])])
    }

    @Test func whenEveryCopyIsMarkedTheUsualOrderStillApplies() {
        let sets = DuplicateFinder.candidates([photo("a"), photo("b", favorite: true)])
        let groups = DuplicateFinder.groups(sets, sizes: ["a": 500, "b": 500], marked: ["a", "b"])
        #expect(groups == [DuplicateGroup(keeper: "b", extras: ["a"])])
    }

    @Test func groupsComeOutInTheOrderTheyWereFirstSeen() {
        let items = [photo("n1", at: 300), photo("o1", at: 100), photo("n2", at: 300), photo("o2", at: 100)]
        let sets = DuplicateFinder.candidates(items)
        let groups = DuplicateFinder.groups(sets, sizes: ["n1": 1, "n2": 1, "o1": 2, "o2": 2])
        #expect(groups.map(\.keeper) == ["n1", "o1"])
    }
}

@Suite struct MarkAllRemainingTests {
    @Test func decideRemainingFinishesTheDeckFromTheCurrentItem() {
        var deck = SweepDeck(ids: ["a", "b", "c", "d"])
        deck.decide(.keep)
        #expect(deck.remainingIDs == ["b", "c", "d"])
        let entries = deck.decideRemaining(.delete)
        #expect(entries.map(\.id) == ["b", "c", "d"])
        #expect(entries.allSatisfy { $0.decision == .delete })
        #expect(deck.isFinished)
        #expect(deck.remainingIDs.isEmpty)
    }

    @Test func undoLastTakesBackTheWholeBatchThenSingleSwipes() {
        var deck = SweepDeck(ids: ["a", "b", "c", "d"])
        deck.decide(.keep)
        deck.decideRemaining(.delete)
        #expect(deck.undoLast().map(\.id) == ["b", "c", "d"])
        #expect(deck.current == "b")
        #expect(deck.undoLast().map(\.id) == ["a"])
        #expect(deck.current == "a")
        #expect(deck.undoLast().isEmpty)
    }

    @Test func decideRemainingOnAFinishedDeckDoesNothing() {
        var deck = SweepDeck(ids: ["a"])
        deck.decide(.keep)
        #expect(deck.decideRemaining(.delete).isEmpty)
        #expect(deck.undoLast().map(\.id) == ["a"])
    }

    @Test func removingDeletedItemsShrinksTheBatch() {
        var deck = SweepDeck(ids: ["a", "b", "c", "d"])
        deck.decide(.keep)
        deck.decideRemaining(.delete)
        deck.remove(["b", "d"])
        #expect(deck.isFinished)
        #expect(deck.undoLast().map(\.id) == ["c"])
        #expect(deck.undoLast().map(\.id) == ["a"])
    }

    @Test func singleUndoInsideABatchStillLeavesTheRestUndoableTogether() {
        var deck = SweepDeck(ids: ["a", "b", "c"])
        deck.decideRemaining(.delete)
        #expect(deck.undo()?.id == "c")
        #expect(deck.undoLast().map(\.id) == ["a", "b"])
    }

    @Test func markAllAddsToTheDeleteListWithoutDuplicates() {
        var store = SweepStore()
        store.apply(.keep, to: "a")
        store.apply(.delete, to: "b", bytes: 10)
        store.markAll(["a", "b", "c"], bytes: ["a": 5, "c": 7])
        #expect(store.marked == ["b", "a", "c"])
        #expect(store.kept.isEmpty)
        #expect(store.totalMarkedBytes == 22)
    }

    @Test func clearDecisionsUndoesABatch() {
        var store = SweepStore()
        store.apply(.keep, to: "k")
        store.markAll(["a", "b", "c"], bytes: ["a": 5])
        store.clearDecisions(for: ["a", "b", "c"])
        #expect(store.marked.isEmpty)
        #expect(store.markedBytes.isEmpty)
        #expect(store.kept == ["k"])
    }

    @Test func sizesCanBeFilledInAfterwardsForMarkedItemsOnly() {
        var store = SweepStore()
        store.markAll(["a", "b"])
        store.setBytes(["a": 100, "b": 200, "not-marked": 999])
        #expect(store.totalMarkedBytes == 300)
        #expect(store.markedBytes["not-marked"] == nil)
    }

    @Test func markingThirtyThousandItemsIsQuick() {
        var store = SweepStore()
        let ids = (0..<30_000).map { "item-\($0)" }
        let elapsed = ContinuousClock().measure { store.markAll(ids) }
        #expect(store.marked.count == 30_000)
        #expect(elapsed < .seconds(2))
    }
}
