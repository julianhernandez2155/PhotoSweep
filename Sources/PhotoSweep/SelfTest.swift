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

    /// The duplicate scan passes by finishing. Finding nothing is a normal result, so unlike
    /// the other queues it is not required to hold anything.
    struct DuplicatesReport: Codable {
        var itemsScanned: Int
        var lookAlikeItems: Int
        var groups: Int
        var extraCopies: Int
        var extraCopiesBytes: Int64
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
        var duplicates: DuplicatesReport?
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
                var duplicates: DuplicatesReport?
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
                    duplicates = checkDuplicates()
                }
                let report = Report(
                    authorization: name(of: status),
                    authorized: status == .authorized,
                    queueCount: reports.count,
                    queues: reports,
                    counts: counts,
                    duplicates: duplicates,
                    allPassed: status == .authorized && !reports.isEmpty && reports.allSatisfy(\.passed)
                        && counts?.passed == true && duplicates?.passed == true,
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
    private static func checkDuplicates() -> DuplicatesReport {
        var result: DuplicateScanner.Result?
        let elapsed = ContinuousClock().measure {
            result = DuplicateScanner.scan(knownSizes: [:])
        }
        guard let result else {
            return DuplicatesReport(
                itemsScanned: 0, lookAlikeItems: 0, groups: 0, extraCopies: 0, extraCopiesBytes: 0,
                seconds: seconds(elapsed), passed: false)
        }
        // Every extra copy must still be in the library, and none may be the copy being kept.
        let keepers = Set(result.groups.map(\.keeper))
        let found = PhotoLibrary.fetch(.duplicates, duplicateIDs: result.extras).count
        let consistent = found == result.extras.count && keepers.isDisjoint(with: result.extras)
        return DuplicatesReport(
            itemsScanned: result.scannedCount,
            lookAlikeItems: result.candidateCount,
            groups: result.groups.count,
            extraCopies: result.extras.count,
            extraCopiesBytes: result.extras.reduce(0) { $0 + (result.measured[$1] ?? 0) },
            seconds: seconds(elapsed),
            passed: consistent)
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
