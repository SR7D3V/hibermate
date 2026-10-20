import Foundation
import Testing
@testable import HibermateCore

@Suite("Update check: versions, feed, schedule")
struct UpdateCheckTests {
    let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)

    func feed(_ json: String) -> Data { Data(json.utf8) }

    @Test func versionsCompare() {
        #expect(AppVersion("0.1.0")! < AppVersion("0.2.0")!)
        #expect(AppVersion("0.9.0")! < AppVersion("0.10.0")!)
        #expect(AppVersion("v1.0")! == AppVersion("1.0.0")!)
        #expect(AppVersion("1.0.0-beta.2")! < AppVersion("1.0.0")!)
        #expect(AppVersion("1.0.0-beta.2")! < AppVersion("1.0.0-beta.10")!)
        #expect(!(AppVersion("1.0.0")! < AppVersion("1.0.0")!))
    }

    @Test func malformedVersionsAreRejected() {
        for bad in ["", "v", "1..0", "1.0.0-", "1.a.0", "1.0/../x", "1.0.0-beta?x=1", "1.0.0 2", "١.٢.٣", "1.2.3.4.5"] {
            #expect(AppVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func newerReleaseIsOffered() {
        let update = UpdatePolicy.evaluate(feed: feed(#"{"version":"0.2.0"}"#), currentVersion: "0.1.0", systemVersion: sonoma)
        #expect(update?.version == "0.2.0")
        #expect(update?.releasePage.absoluteString == "https://github.com/SR7D3V/hibermate/releases/tag/v0.2.0")
    }

    @Test func sameOrOlderIsNotOffered() {
        #expect(UpdatePolicy.evaluate(feed: feed(#"{"version":"0.1.0"}"#), currentVersion: "0.1.0", systemVersion: sonoma) == nil)
        #expect(UpdatePolicy.evaluate(feed: feed(#"{"version":"0.0.9"}"#), currentVersion: "0.1.0", systemVersion: sonoma) == nil)
    }

    @Test func badFeedsAreIgnored() {
        for json in ["", "not json", "{}", #"{"version":"evil/../x"}"#, #"{"version":"0.2.0","minimumSystemVersion":"x"}"#] {
            #expect(UpdatePolicy.evaluate(feed: feed(json), currentVersion: "0.1.0", systemVersion: sonoma) == nil, "\(json)")
        }
        let huge = Data(repeating: 0x20, count: UpdatePolicy.maxFeedBytes + 1)
        #expect(UpdatePolicy.evaluate(feed: huge, currentVersion: "0.1.0", systemVersion: sonoma) == nil)
    }

    @Test func extraFeedFieldsAreTolerated() {
        let json = #"{"version":"0.3.0","minimumSystemVersion":"14.0","notes":"x"}"#
        #expect(UpdatePolicy.evaluate(feed: feed(json), currentVersion: "0.1.0", systemVersion: sonoma)?.version == "0.3.0")
    }

    @Test func releaseNeedingNewerMacOSIsNotOffered() {
        let json = #"{"version":"0.2.0","minimumSystemVersion":"15.0"}"#
        #expect(UpdatePolicy.evaluate(feed: feed(json), currentVersion: "0.1.0", systemVersion: sonoma) == nil)
    }

    @Test func checksAtMostDaily() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(UpdatePolicy.isDue(lastCheck: nil, now: now))
        #expect(!UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(7 * 24 * 3600), now: now))
    }
}
