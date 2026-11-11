import AppKit
import Photos
import SweepCore

/// `PhotoSweep --selftest <path>` checks the read-only half of the app against the real library
/// and writes what it found as JSON. It never changes the library and never touches saved progress.
enum SelfTest {
    struct FirstItem: Codable {
        var mediaType: String
        var imageLoaded: Bool
        var imagePixelWidth: Int
        var imagePixelHeight: Int
        var fileSizeBytes: Int64
    }

    struct QueueReport: Codable {
        var title: String
        var section: String
        var count: Int
        var firstItem: FirstItem?
        var passed: Bool
    }

    struct ScannedQueueReport: Codable {
        var title: String
        var count: Int
        var allStillInLibrary: Bool
    }

    /// The cleanup scan passes by finishing with consistent results. Finding nothing is normal,
    /// so unlike the other queues its queues are not required to hold anything.
    struct CleanupScanReport: Codable {
        var itemsScanned: Int
        var lookAlikeItems: Int
        var duplicateGroups: Int
        var savedByAppAvailable: Bool
        var queues: [ScannedQueueReport]
        var seconds: Double
        var passed: Bool
    }

    /// Checks the sidebar counts against the library, and times the work a swipe has to do.
    struct CountsReport: Codable {
        var buildSeconds: Double
        var totalsMatchLibrary: Bool
        var leftEqualsTotalWithNoDecisions: Bool
        var swipesTimed: Int
        var microsecondsPerSwipe: Double
        var passed: Bool
    }

    struct Report: Codable {
        var authorization: String
        var authorized: Bool
        var queueCount: Int
        var queues: [QueueReport]
        var counts: CountsReport?
        var cleanupScan: CleanupScanReport?
        var allPassed: Bool
        var finishedAt: String
    }

    static var requestedReportPath: String? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--selftest"), flag + 1 < arguments.count else {
            return nil
        }
        return arguments[flag + 1]
    }

    static func run(reportPath: String) {
        // Asking is what makes macOS show its permission prompt the first time.
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.global(qos: .userInitiated).async {
                var reports: [QueueReport] = []
                var counts: CountsReport?
                var cleanupScan: CleanupScanReport?
                if status == .authorized {
                    let clock = ContinuousClock()
                    var index = LibraryIndex(queues: [], members: [:])
                    var tally = QueueTally<QueueKind>()
                    let buildTime = clock.measure {
                        index = PhotoLibrary.index()
                        tally = QueueTally(members: index.members)
                    }
                    for queue in index.queues {
                        reports.append(check(queue))
                    }
                    counts = checkCounts(index: index, tally: tally, buildSeconds: seconds(buildTime))
                    cleanupScan = checkCleanupScan()
                }
                let report = Report(
                    authorization: name(of: status),
                    authorized: status == .authorized,
                    queueCount: reports.count,
                    queues: reports,
                    counts: counts,
                    cleanupScan: cleanupScan,
                    allPassed: status == .authorized && !reports.isEmpty && reports.allSatisfy(\.passed)
                        && counts?.passed == true && cleanupScan?.passed == true,
                    finishedAt: ISO8601DateFormatter().string(from: Date()))
                write(report, to: reportPath)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    private static func check(_ queue: SweepQueue) -> QueueReport {
        let result = PhotoLibrary.fetch(queue.kind)
        var report = QueueReport(
            title: queue.title, section: queue.section.rawValue, count: result.count,
            firstItem: nil, passed: false)
        guard let asset = result.firstObject else { return report }

        let image = loadImage(asset)
        let pixels = image?.representations.first
        let item = FirstItem(
            mediaType: asset.mediaType == .video ? "video" : "image",
            imageLoaded: image != nil,
            imagePixelWidth: pixels?.pixelsWide ?? 0,
            imagePixelHeight: pixels?.pixelsHigh ?? 0,
            fileSizeBytes: AssetSizer.bytes(for: asset))
        report.firstItem = item
        report.passed = result.count > 0 && item.imageLoaded && item.fileSizeBytes > 0
        return report
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Works on a copy of the counts in memory. No decision is saved anywhere.
    private static func checkCounts(
        index: LibraryIndex, tally: QueueTally<QueueKind>, buildSeconds: Double
    ) -> CountsReport {
        let totalsMatch = index.queues.allSatisfy { tally.total($0.kind) == PhotoLibrary.fetch($0.kind).count }
        let leftMatches = index.queues.allSatisfy { tally.left($0.kind) == tally.total($0.kind) }

        var scratch = tally
        let sample = Array((index.members[.all] ?? []).prefix(2_000))
        let elapsed = ContinuousClock().measure {
            for id in sample { scratch.setDecided(id, true) }
        }
        let leftFollowed = scratch.left(.all) == tally.total(.all) - sample.count
        let perSwipe = sample.isEmpty ? 0 : seconds(elapsed) * 1_000_000 / Double(sample.count)
        return CountsReport(
            buildSeconds: buildSeconds,
            totalsMatchLibrary: totalsMatch,
            leftEqualsTotalWithNoDecisions: leftMatches,
            swipesTimed: sample.count,
            microsecondsPerSwipe: perSwipe,
            passed: totalsMatch && leftMatches && leftFollowed)
    }

    /// Runs the same scan the app does, starting with no cached sizes.
    private static func checkCleanupScan() -> CleanupScanReport {
        var result: CleanupScanner.Result?
        let elapsed = ContinuousClock().measure {
            result = CleanupScanner.scan(knownSizes: [:])
        }
        guard let result else {
            return CleanupScanReport(
                itemsScanned: 0, lookAlikeItems: 0, duplicateGroups: 0, savedByAppAvailable: false,
                queues: [], seconds: seconds(elapsed), passed: false)
        }
        let queues = result.queues.map { queue -> ScannedQueueReport in
            let ids = result.members[queue.kind] ?? []
            let found = PhotoLibrary.fetch(queue.kind, scannedIDs: ids).count
            return ScannedQueueReport(title: queue.title, count: ids.count, allStillInLibrary: found == ids.count)
        }
        // No extra copy may also be the copy that is being kept.
        let keepers = Set(result.duplicateGroups.map(\.keeper))
        let keepersSafe = keepers.isDisjoint(with: result.members[.duplicates] ?? [])
        return CleanupScanReport(
            itemsScanned: result.scannedCount,
            lookAlikeItems: result.lookAlikeCount,
            duplicateGroups: result.duplicateGroups.count,
            savedByAppAvailable: result.sourcesAvailable,
            queues: queues,
            seconds: seconds(elapsed),
            passed: keepersSafe && queues.allSatisfy(\.allStillInLibrary))
    }

    /// Loads the final (not degraded) image through the same pipeline the cards use.
    private static func loadImage(_ asset: PHAsset) -> NSImage? {
        let done = DispatchSemaphore(value: 0)
        var loaded: NSImage?
        let options = ImagePipeline.options(delivery: .highQualityFormat)
        ImagePipeline.manager.requestImage(
            for: asset, targetSize: ImagePipeline.cardSize, contentMode: .aspectFit, options: options
        ) { image, _ in
            loaded = image
            done.signal()
        }
        _ = done.wait(timeout: .now() + 120)
        return loaded
    }

    private static func name(of status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private static func write(_ report: Report, to path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
