import Foundation

/// Reads and writes one Codable value as a JSON file.
public struct JSONFile<Value: Codable> {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Returns the stored value, or `fallback` when the file is missing.
    /// A file that cannot be decoded is moved aside to `<name>.corrupt` so it is never silently overwritten.
    public func load(default fallback: Value) -> Value {
        guard let data = try? Data(contentsOf: url) else { return fallback }
        if let value = try? JSONDecoder().decode(Value.self, from: data) {
            return value
        }
        let aside = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return fallback
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }
}
