import Foundation

/// One safety release, kept so the user can see later why a hold ended.
/// Stores only the time, the reason, and whether the Mac was put to sleep.
public struct SafetyReleaseRecord: Codable, Equatable, Sendable, Identifiable {
    public var date: Date
    public var reason: ReleaseReason
    public var slept: Bool
    /// Whether the user has seen it, through a notification or the "While you
    /// were away" alert.
    public var acknowledged: Bool

    public var id: Date { date }

    public init(date: Date, reason: ReleaseReason, slept: Bool, acknowledged: Bool = false) {
        self.date = date
        self.reason = reason
        self.slept = slept
        self.acknowledged = acknowledged
    }

    public var summary: String { reason.notificationBody(slept: slept) }
}

/// The most recent safety releases, newest first, in
/// `~/Library/Application Support/Hibermate/safety-releases.json`.
public struct SafetyReleaseHistory: Sendable {
    public static let capacity = 20
    public private(set) var records: [SafetyReleaseRecord] = []
    public let file: URL?

    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder.iso.decode([SafetyReleaseRecord].self, from: data) {
            records = Array(decoded.prefix(Self.capacity))
        }
    }

    public mutating func add(_ record: SafetyReleaseRecord) {
        records.insert(record, at: 0)
        if records.count > Self.capacity { records.removeLast(records.count - Self.capacity) }
        save()
    }

    /// Releases the user hasn't been told about yet, oldest first.
    public var unacknowledged: [SafetyReleaseRecord] {
        records.filter { !$0.acknowledged }.reversed()
    }

    public mutating func acknowledgeAll() {
        guard records.contains(where: { !$0.acknowledged }) else { return }
        for i in records.indices { records[i].acknowledged = true }
        save()
    }

    private func save() {
        guard let file, let data = try? JSONEncoder.iso.encode(records) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? AtomicFile.write(data, to: file)
    }
}

extension HibermatePaths {
    public var safetyReleasesFile: URL { supportDirectory.appendingPathComponent("safety-releases.json") }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
