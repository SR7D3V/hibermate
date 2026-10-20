import Foundation

/// A release version: "1.2.3", optionally with a "v" prefix and a
/// pre-release suffix ("1.3.0-beta.1"). A pre-release sorts before its release.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    public let preRelease: String?

    /// Strict: digits, dots and an optional [0-9A-Za-z.-] suffix only, so a
    /// parsed version is always safe to put in a URL.
    public init?(_ string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" { s = s.dropFirst() }
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(core.count),
              core.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return nil }
        numbers = core.map { Int($0)! }
        if parts.count == 2 {
            let suffix = parts[1]
            guard !suffix.isEmpty, suffix.count <= 32,
                  suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
            else { return nil }
            preRelease = String(suffix)
        } else {
            preRelease = nil
        }
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (preRelease.map { "-\($0)" } ?? "")
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let count = max(a.numbers.count, b.numbers.count)
        for i in 0..<count {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        switch (a.preRelease, b.preRelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// What a release publishes as `hibermate-update.json` (written by
/// scripts/build-dmg.sh, attached to the GitHub release).
public struct UpdateFeed: Codable, Equatable, Sendable {
    public var version: String
    public var minimumSystemVersion: String?

    public init(version: String, minimumSystemVersion: String? = nil) {
        self.version = version
        self.minimumSystemVersion = minimumSystemVersion
    }
}

public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    /// Always a page on Hibermate's own GitHub releases; never taken from the feed.
    public let releasePage: URL

    public init(version: AppVersion) {
        self.version = version.description
        releasePage = UpdatePolicy.releasePage(for: version)
    }
}

/// The update check is Hibermate's only network request: one anonymous GET of
/// the latest release's feed file, at most once a day, when the user hasn't
/// turned it off. It sends nothing about the Mac and never downloads or
/// installs anything; the UPDATE button only opens the release page.
public enum UpdatePolicy {
    public static let repository = "SR7D3V/hibermate"
    /// GitHub serves the newest *published* release here (not drafts or pre-releases).
    public static let feedURL = URL(string: "https://github.com/\(repository)/releases/latest/download/hibermate-update.json")!
    public static let checkInterval: TimeInterval = 24 * 3600
    /// Feeds are a few dozen bytes; anything much bigger isn't ours.
    public static let maxFeedBytes = 16 * 1024

    public static func releasePage(for version: AppVersion) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")!
    }

    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        // A clock set backwards shouldn't silence checks for good.
        return now.timeIntervalSince(lastCheck) >= checkInterval || lastCheck > now
    }

    /// The update to offer, or nil when the feed is malformed, not newer, or
    /// needs a newer macOS than this Mac runs.
    public static func evaluate(feed data: Data, currentVersion: String,
                                systemVersion: OperatingSystemVersion) -> AvailableUpdate? {
        guard data.count <= maxFeedBytes,
              let feed = try? JSONDecoder().decode(UpdateFeed.self, from: data),
              let latest = AppVersion(feed.version),
              let current = AppVersion(currentVersion),
              current < latest
        else { return nil }
        if let minimum = feed.minimumSystemVersion {
            guard let needed = AppVersion(minimum) else { return nil }
            let mac = AppVersion("\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)")!
            if mac < needed { return nil }
        }
        return AvailableUpdate(version: latest)
    }
}
