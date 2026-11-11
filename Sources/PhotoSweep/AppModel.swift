import AppKit
import Combine
import Photos
import SweepCore

/// Input that the deck view animates before it becomes a decision.
enum DeckAction {
    case swipe(Decision)
    case scroll(CGFloat)
    case scrollEnded
}

struct DeletionSummary: Identifiable {
    let id = UUID()
    let count: Int
    let bytes: Int64
}

final class AppModel: ObservableObject {
    @Published var auth: PHAuthorizationStatus
    @Published private(set) var queues: [SweepQueue] = []
    @Published var selected: QueueKind? {
        didSet { if oldValue != selected { reloadDeck() } }
    }
    @Published var sort: SortOrder = .newest {
        didSet { if oldValue != sort { reloadDeck() } }
    }
    @Published private(set) var deck = SweepDeck()
    @Published private(set) var store: SweepStore
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    /// 0...1 while file sizes are being measured for the "Largest" sort.
    @Published private(set) var sizingProgress: Double?
    @Published var showReview = false
    @Published private(set) var isDeleting = false
    @Published var deletionSummary: DeletionSummary?
    @Published var errorMessage: String?
    @Published var muted = true {
        didSet { activeVideo?.setMuted(muted) }
    }
    /// Whether the sidebar shows everything in each queue or only what is left to swipe.
    @Published var countMode: CountMode {
        didSet { UserDefaults.standard.set(countMode.rawValue, forKey: Self.countModeKey) }
    }
    /// Per-queue totals and "left to swipe" counts, kept current as decisions are made.
    @Published private(set) var tally = QueueTally<QueueKind>()
    /// 0...1 during the first duplicate scan after launch; nil otherwise.
    @Published private(set) var duplicateScanProgress: Double?
    @Published var confirmMarkAll = false

    /// Key presses and trackpad swipes, forwarded to the deck view so it can animate them.
    let actions = PassthroughSubject<DeckAction, Never>()
    weak var activeVideo: VideoController?

    private static let countModeKey = "countMode"

    private var assets: [String: PHAsset] = [:]
    /// Queues read from the library. `queues` is these plus the Duplicates queue when it has items.
    private var libraryQueues: [SweepQueue] = []
    private var duplicateIDs: [String] = []
    private var hasScannedDuplicates = false
    private var scanToken = LoadToken()
    private var refreshGeneration = 0
    private var sizes: [String: Int64]
    private var sizesDirty = false
    private var loadToken = LoadToken()
    private var saveWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var libraryObserver: LibraryObserver?
    private var libraryChangeWork: DispatchWorkItem?
    private var horizontalScroll: Bool?
    private var scrollAccumulated = CGSize.zero

    private let stateFile: JSONFile<SweepStore>
    private let sizesFile: JSONFile<[String: Int64]>

    init() {
        let folder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoSweep", isDirectory: true)
        stateFile = JSONFile(url: folder.appendingPathComponent("state.json"))
        sizesFile = JSONFile(url: folder.appendingPathComponent("sizes.json"))
        store = stateFile.load(default: SweepStore())
        sizes = sizesFile.load(default: [:])
        auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        countMode = UserDefaults.standard.string(forKey: Self.countModeKey).flatMap(CountMode.init) ?? .all
    }

    // MARK: - Access

    var isAuthorized: Bool { auth == .authorized }

    func requestAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                self?.auth = status
                self?.start()
            }
        }
    }

    /// Loads the sidebar and opens the first queue. Safe to call more than once.
    func start() {
        guard isAuthorized else { return }
        installMonitors()
        observeLibrary()
        refreshQueues()
    }

    /// The Refresh button: re-reads albums and counts from Photos and reloads the open queue,
    /// so anything added or removed outside the app shows up.
    func refresh() {
        guard isAuthorized, !isRefreshing else { return }
        isRefreshing = true
        let before = selected
        refreshQueues { [weak self] in
            guard let self else { return }
            self.isRefreshing = false
            // If the open album was removed, refreshQueues already moved to another queue and loaded it.
            if self.selected == before { self.reloadDeck() }
        }
    }

    /// Keeps the sidebar current on its own whenever the Photos library changes.
    private func observeLibrary() {
        guard libraryObserver == nil else { return }
        let observer = LibraryObserver { [weak self] in
            DispatchQueue.main.async { self?.libraryDidChange() }
        }
        PHPhotoLibrary.shared().register(observer)
        libraryObserver = observer
    }

    /// Changes often arrive in bursts, so wait for a quiet second before re-counting.
    /// Only the sidebar is updated; the card you are looking at is left alone.
    private func libraryDidChange() {
        libraryChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshQueues() }
        libraryChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func refreshQueues(then completion: (() -> Void)? = nil) {
        refreshGeneration += 1
        let generation = refreshGeneration
        let decided = decidedIDs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Reading every queue's items is the slow part, so the counts are built here too.
            let index = PhotoLibrary.index()
            let tally = QueueTally(members: index.members, decided: decided)
            DispatchQueue.main.async {
                guard let self else { return }
                // A newer refresh is already on its way; let that one publish.
                if generation == self.refreshGeneration {
                    var tally = tally
                    tally.setMembers(self.duplicateIDs, for: .duplicates)
                    tally.syncDecided(self.decidedIDs)  // catch swipes made while this was running
                    self.tally = tally
                    self.libraryQueues = index.queues
                    self.publishQueues()
                    self.scanForDuplicates()
                }
                completion?()
            }
        }
    }

    private var decidedIDs: Set<String> { store.kept.union(store.marked) }

    /// Rebuilds the sidebar list: the library's queues, plus Duplicates at the top of Library
    /// when the last scan found any.
    private func publishQueues() {
        var list = libraryQueues
        if !duplicateIDs.isEmpty {
            let position = list.firstIndex { $0.section == .library } ?? list.count
            list.insert(.duplicates(count: duplicateIDs.count), at: position)
        }
        queues = list
        // Open the first queue at launch, or move off a queue that no longer exists.
        if !list.contains(where: { $0.kind == selected }) {
            selected = list.first?.kind
        }
    }

    // MARK: - Duplicates

    /// Looks for duplicates in the background. File sizes it has to measure are cached, so only
    /// the first scan is slow.
    private func scanForDuplicates() {
        scanToken.cancel()
        let token = LoadToken()
        scanToken = token
        if !hasScannedDuplicates { duplicateScanProgress = 0 }
        let knownSizes = sizes
        let kept = store.kept
        let marked = Set(store.marked)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var lastReported = 0.0
            let result = DuplicateScanner.scan(
                knownSizes: knownSizes, kept: kept, marked: marked,
                isCancelled: { token.isCancelled },
                progress: { fraction in
                    guard fraction - lastReported >= 0.02 else { return }
                    lastReported = fraction
                    DispatchQueue.main.async {
                        guard let self, !token.isCancelled, self.duplicateScanProgress != nil else { return }
                        self.duplicateScanProgress = fraction
                    }
                })
            guard let result else { return }
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                if !result.measured.isEmpty {
                    self.sizes.merge(result.measured) { $1 }
                    self.sizesDirty = true
                    self.scheduleSave()
                }
                let changed = result.extras != self.duplicateIDs
                self.duplicateIDs = result.extras
                self.hasScannedDuplicates = true
                self.duplicateScanProgress = nil
                guard changed else { return }
                self.tally.setMembers(result.extras, for: .duplicates)
                let wasOpen = self.selected == .duplicates
                self.publishQueues()
                // If the Duplicates queue is still the open one, show its new contents.
                if wasOpen, self.selected == .duplicates { self.reloadDeck() }
            }
        }
    }

    // MARK: - Deck

    var selectedQueue: SweepQueue? { queues.first { $0.kind == selected } }
    var currentAsset: PHAsset? { deck.current.flatMap { assets[$0] } }
    var nextAsset: PHAsset? { deck.upcoming(1).first.flatMap { assets[$0] } }

    func reloadDeck() {
        loadToken.cancel()
        let token = LoadToken()
        loadToken = token
        ImagePipeline.stopPreheating()
        VideoPool.shared.reset()
        sizingProgress = nil

        guard let kind = selected, isAuthorized else {
            deck = SweepDeck()
            assets = [:]
            isLoading = false
            return
        }
        isLoading = true
        let sort = self.sort
        let decided = decidedIDs
        let knownSizes = sizes
        let duplicateIDs = self.duplicateIDs

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var list: [PHAsset] = []
            PhotoLibrary.fetch(kind, sort: sort, duplicateIDs: duplicateIDs).enumerateObjects { asset, _, _ in
                if !decided.contains(asset.localIdentifier) { list.append(asset) }
            }
            var byID: [String: PHAsset] = [:]
            for asset in list { byID[asset.localIdentifier] = asset }
            var ids = list.map(\.localIdentifier)
            var measured: [String: Int64] = [:]

            if sort == .largest {
                for (index, asset) in list.enumerated() {
                    if token.isCancelled { return }
                    if knownSizes[asset.localIdentifier] == nil {
                        measured[asset.localIdentifier] = AssetSizer.bytes(for: asset)
                    }
                    if index % 100 == 0 {
                        let fraction = Double(index) / Double(max(list.count, 1))
                        DispatchQueue.main.async {
                            if !token.isCancelled { self?.sizingProgress = fraction }
                        }
                    }
                }
                ids = SizeOrdering.largestFirst(ids, sizes: knownSizes.merging(measured) { $1 })
            }

            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                if !measured.isEmpty {
                    self.sizes.merge(measured) { $1 }
                    self.sizesDirty = true
                    self.scheduleSave()
                }
                self.assets = byID
                self.deck = SweepDeck(ids: ids)
                self.sizingProgress = nil
                self.isLoading = false
                self.preheat()
            }
        }
    }

    func decide(_ decision: Decision) {
        guard let id = deck.current else { return }
        store.apply(decision, to: id, bytes: decision == .delete ? size(forID: id) : nil)
        deck.decide(decision)
        tally.setDecided(id, true)
        scheduleSave()
        preheat()
    }

    /// Takes back the last action: one swipe, or everything a "Mark All Remaining" added.
    func undo() {
        let undone = deck.undoLast().map(\.id)
        guard !undone.isEmpty else { return }
        if undone.count == 1 {
            store.clearDecision(for: undone[0])
        } else {
            store.clearDecisions(for: Set(undone))
        }
        tally.setDecided(undone, false)
        scheduleSave()
        preheat()
    }

    /// Puts every item still waiting in the open queue on the delete list. Nothing is deleted:
    /// the review sheet and the macOS confirmation still stand between this and the library.
    func markAllRemaining() {
        let ids = deck.remainingIDs
        guard !ids.isEmpty, !isLoading else { return }
        var known: [String: Int64] = [:]
        var unsized: [PHAsset] = []
        for id in ids {
            if let bytes = sizes[id] {
                known[id] = bytes
            } else if let asset = assets[id] {
                unsized.append(asset)
            }
        }
        store.markAll(ids, bytes: known)
        deck.decideRemaining(.delete)
        tally.setDecided(ids, true)
        saveNow()
        preheat()
        measure(unsized)
    }

    /// Measures file sizes in the background and fills them in on the delete list, so marking
    /// thousands of items at once does not freeze the window.
    private func measure(_ unsized: [PHAsset]) {
        guard !unsized.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var batch: [String: Int64] = [:]
            for (index, asset) in unsized.enumerated() {
                let bytes = AssetSizer.bytes(for: asset)
                if bytes > 0 { batch[asset.localIdentifier] = bytes }
                guard batch.count >= 200 || index == unsized.count - 1, !batch.isEmpty else { continue }
                let measured = batch
                batch = [:]
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.sizes.merge(measured) { $1 }
                    self.sizesDirty = true
                    self.store.setBytes(measured)
                    self.scheduleSave()
                }
            }
        }
    }

    /// Byte size for an item in the current queue, measured once and then cached.
    func size(forID id: String) -> Int64 {
        if let known = sizes[id] { return known }
        guard let asset = assets[id] else { return 0 }
        return size(for: asset)
    }

    func size(for asset: PHAsset) -> Int64 {
        if let known = sizes[asset.localIdentifier] { return known }
        let bytes = AssetSizer.bytes(for: asset)
        if bytes > 0 {
            sizes[asset.localIdentifier] = bytes
            sizesDirty = true
        }
        return bytes
    }

    /// Gets the next cards ready: images for the next three, and players for videos among the next two.
    private func preheat() {
        ImagePipeline.preheat(deck.upcoming(3).compactMap { assets[$0] })
        let videos = deck.upcoming(2).compactMap { assets[$0] }.filter { $0.mediaType == .video }
        VideoPool.shared.prepare(upcoming: videos, keeping: deck.current)
    }

    // MARK: - Review and delete

    /// The marked items that still exist. Ones that vanished from the library are dropped.
    func markedAssets() -> [PHAsset] {
        let found = PhotoLibrary.assets(withIDs: store.marked)
        let missing = Set(store.marked).subtracting(found.map(\.localIdentifier))
        if !missing.isEmpty {
            store.dropMarked(missing)
            tally.setDecided(missing, false)
            scheduleSave()
        }
        return found
    }

    func unmark(_ id: String) {
        store.unmark(id)
        scheduleSave()
    }

    /// Asks Photos to delete everything marked. macOS shows its own confirmation first,
    /// and deleted items go to Recently Deleted.
    func deleteMarked() {
        let targets = markedAssets()
        guard !targets.isEmpty, !isDeleting else { return }
        let ids = targets.map(\.localIdentifier)
        let bytes = store.totalMarkedBytes
        isDeleting = true
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(targets as NSArray)
        } completionHandler: { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDeleting = false
                if success {
                    self.store.recordDeletion(of: ids)
                    self.deck.remove(Set(ids))
                    for id in ids { self.assets[id] = nil }
                    self.saveNow()
                    self.preheat()
                    self.showReview = false
                    // Let the review sheet finish closing before the reminder appears.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.deletionSummary = DeletionSummary(count: ids.count, bytes: bytes)
                    }
                    self.refreshQueues()
                } else if let error, (error as NSError).code != PHPhotosError.userCancelled.rawValue {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func resetProgress() {
        store.resetProgress()
        tally.syncDecided([])
        saveNow()
        reloadDeck()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        do {
            try stateFile.save(store)
            if sizesDirty {
                try sizesFile.save(sizes)
                sizesDirty = false
            }
        } catch {
            errorMessage = "Couldn't save your progress: \(error.localizedDescription)"
        }
    }

    // MARK: - Keyboard and trackpad

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] in
            self?.handleKey($0) ?? $0
        }) { monitors.append(keys) }
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] in
            self?.handleScroll($0) ?? $0
        }) { monitors.append(scroll) }
    }

    /// Deck shortcuts only apply to the main window while nothing is layered over it.
    private func deckHasFocus(_ event: NSEvent) -> Bool {
        guard isAuthorized, !showReview, let window = event.window else { return false }
        return window.sheets.isEmpty && window.sheetParent == nil && !(window is NSPanel)
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard deckHasFocus(event) else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else { return event }
        switch event.keyCode {
        case 123:  // left arrow
            if !event.isARepeat { actions.send(.swipe(.delete)) }
        case 124:  // right arrow
            if !event.isARepeat { actions.send(.swipe(.keep)) }
        case 126:  // up arrow
            if !event.isARepeat { undo() }
        case 49:  // space
            activeVideo?.togglePlay()
        case 46:  // M
            muted.toggle()
        default:
            return event
        }
        return nil
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard deckHasFocus(event), event.hasPreciseScrollingDeltas else { return event }
        // Swallow the coasting that follows a swipe we already handled.
        if !event.momentumPhase.isEmpty {
            return horizontalScroll == true ? nil : event
        }
        if event.phase.contains(.began) {
            horizontalScroll = nil
            scrollAccumulated = .zero
        }
        if event.phase.contains(.began) || event.phase.contains(.changed) {
            if horizontalScroll == nil {
                scrollAccumulated.width += event.scrollingDeltaX
                scrollAccumulated.height += event.scrollingDeltaY
                let (dx, dy) = (abs(scrollAccumulated.width), abs(scrollAccumulated.height))
                if dx + dy > 6 {
                    horizontalScroll = dx > dy * 1.5
                    if horizontalScroll == true { actions.send(.scroll(scrollAccumulated.width)) }
                }
                return horizontalScroll == true ? nil : event
            }
            if horizontalScroll == true {
                actions.send(.scroll(event.scrollingDeltaX))
                return nil
            }
            return event
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            if horizontalScroll == true {
                actions.send(.scrollEnded)
                return nil
            }
        }
        return event
    }
}

/// Forwards "the Photos library changed" to a closure.
final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}

/// Lets a background load notice that a newer one has replaced it.
final class LoadToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
