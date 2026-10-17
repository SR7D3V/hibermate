import Foundation
import Testing
@testable import HibermateCore

@Suite("Settings can only be tightened (except max hold, 15 min–12 h)")
struct SafetyLimitsTests {
    @Test func defaults() {
        let fans = EffectiveLimits.defaults(fanless: false)
        #expect(fans.maxHold == 4 * 3600)
        #expect(fans.batteryThreshold == 20)
        #expect(fans.fairTimeout == 600)
        #expect(fans.gracePeriod == 60)
        #expect(fans.permissionWait == 300)
        #expect(fans.staleWindow == 900)
        #expect(EffectiveLimits.defaults(fanless: true).fairTimeout == 300)
    }

    @Test func loosenedValuesAreClamped() {
        var s = UserSettings()
        s.batteryThreshold = 5
        s.fairTimeout = 3600
        s.permissionWait = 3600
        s.staleWindow = 7200
        s.gracePeriod = 3600
        s.maxHold = 24 * 3600
        let l = s.effectiveLimits(fanless: false)
        #expect(l.batteryThreshold == 20)
        #expect(l.fairTimeout == 600)
        #expect(l.permissionWait == 300)
        #expect(l.staleWindow == 900)
        #expect(l.gracePeriod == 300)
        #expect(l.maxHold == 12 * 3600)
    }

    @Test func fanlessFairTimeoutCannotBeRaisedToFanDefault() {
        var s = UserSettings()
        s.fairTimeout = 600
        #expect(s.effectiveLimits(fanless: true).fairTimeout == 300)
    }

    @Test func tightenedValuesAreKept() {
        var s = UserSettings()
        s.batteryThreshold = 40
        s.fairTimeout = 120
        s.permissionWait = 90
        s.staleWindow = 600
        s.maxHold = 3600
        let l = s.effectiveLimits(fanless: false)
        #expect(l.batteryThreshold == 40)
        #expect(l.fairTimeout == 120)
        #expect(l.permissionWait == 90)
        #expect(l.staleWindow == 600)
        #expect(l.maxHold == 3600)
    }

    @Test func maxHoldIsAdjustableBothWaysWithinRange() {
        var s = UserSettings()
        s.maxHold = 8 * 3600
        #expect(s.effectiveLimits(fanless: false).maxHold == 8 * 3600)
        s.maxHold = 60
        #expect(s.effectiveLimits(fanless: false).maxHold == 15 * 60)
    }

    @Test func graceHasAFloorForQueuedPrompts() {
        var s = UserSettings()
        s.gracePeriod = 1
        #expect(s.effectiveLimits(fanless: false).gracePeriod == 30)
    }

    @Test func nonFiniteValuesFallBackToDefaults() {
        var s = UserSettings()
        s.maxHold = .infinity
        s.gracePeriod = .nan
        s.fairTimeout = -.infinity
        let l = s.effectiveLimits(fanless: true)
        #expect(l.maxHold == SafetyLimits.maxHoldDefault)
        #expect(l.gracePeriod == SafetyLimits.graceDefault)
        #expect(l.fairTimeout == 300)
    }

    @Test func corruptOrPartialSettingsFileDecodesToDefaults() throws {
        let partial = Data(#"{"maxHold": "lots", "batteryThreshold": 30, "unknown": true}"#.utf8)
        let s = try JSONDecoder().decode(UserSettings.self, from: partial)
        #expect(s.maxHold == SafetyLimits.maxHoldDefault)
        #expect(s.batteryThreshold == 30)
        #expect(s.processWatching == false)
    }
}

@Suite("Fanless model detection")
struct ModelCoolingTests {
    @Test(arguments: ["MacBookAir10,1", "Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13",
                      "Mac16,12", "Mac16,13", "Mac17,3", "Mac17,4", "MacBook10,1"])
    func fanless(id: String) {
        #expect(ModelCooling.isFanless(id))
    }

    @Test(arguments: ["MacBookPro18,3", "Mac14,7", "Mac15,3", "Mac16,1", "Mac17,2", "Mac17,9",
                      "MacBookPro16,1", "MacBookPro11,1", "MacBookAir9,1", "MacBookAir7,2"])
    func hasFans(id: String) {
        #expect(!ModelCooling.isFanless(id))
    }

    @Test(arguments: ["Mac99,1", "", "garbage", "MacBookAir11,1"])
    func unknownCountsAsFanless(id: String) {
        #expect(ModelCooling.isFanless(id))
    }

    @Test func nilCountsAsFanless() {
        #expect(ModelCooling.isFanless(nil))
    }

    @Test func listsDoNotOverlap() {
        #expect(ModelCooling.fanless.isDisjoint(with: ModelCooling.appleSiliconWithFans))
    }
}
