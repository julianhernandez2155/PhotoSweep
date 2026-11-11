import Foundation

/// Picks out the items big enough to be worth a look on their own.
public enum LargeItems {
    /// 100 MB.
    public static let defaultMinimumBytes: Int64 = 100_000_000

    /// The items whose known size is at least `minimumBytes`, in the order given.
    /// Items with no known size are left out.
    public static func select(
        _ ids: [String], sizes: [String: Int64], minimumBytes: Int64 = defaultMinimumBytes
    ) -> [String] {
        ids.filter { (sizes[$0] ?? 0) >= minimumBytes }
    }
}

/// Which app saved an item into the library.
public struct ItemSource: Equatable, Sendable {
    public let id: String
    public let bundleID: String
    public let appName: String

    public init(id: String, bundleID: String, appName: String) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
    }
}

/// Everything one app saved.
public struct SourceGroup: Equatable, Sendable {
    public let bundleID: String
    public let appName: String
    public let ids: [String]

    public init(bundleID: String, appName: String, ids: [String]) {
        self.bundleID = bundleID
        self.appName = appName
        self.ids = ids
    }
}

/// Groups items by the app that saved them, to offer "From Snapchat"-style queues.
public enum SourceGrouping {
    /// Apps with at least `minimumCount` items, biggest first, at most `limit` of them.
    /// Apple's own apps are skipped by default: "saved by the Camera" is most of any library.
    public static func groups(
        _ items: [ItemSource],
        minimumCount: Int = 20,
        limit: Int = 6,
        ignoringBundlePrefixes: [String] = ["com.apple."]
    ) -> [SourceGroup] {
        var idsByBundle: [String: [String]] = [:]
        var nameCounts: [String: [String: Int]] = [:]
        for item in items {
            let bundle = item.bundleID
            guard !bundle.isEmpty, !ignoringBundlePrefixes.contains(where: bundle.hasPrefix) else { continue }
            idsByBundle[bundle, default: []].append(item.id)
            if !item.appName.isEmpty { nameCounts[bundle, default: [:]][item.appName, default: 0] += 1 }
        }
        let groups: [SourceGroup] = idsByBundle.compactMap { bundle, ids in
            guard ids.count >= minimumCount else { return nil }
            // An app can be recorded under more than one name over the years; use the usual one.
            let usualName = nameCounts[bundle]?.max { a, b in
                a.value == b.value ? a.key > b.key : a.value < b.value
            }?.key
            let fallback = bundle.split(separator: ".").last.map { String($0).capitalized } ?? bundle
            return SourceGroup(bundleID: bundle, appName: usualName ?? fallback, ids: ids)
        }
        let sorted = groups.sorted { a, b in
            a.ids.count == b.ids.count ? a.appName < b.appName : a.ids.count > b.ids.count
        }
        return Array(sorted.prefix(max(limit, 0)))
    }
}
