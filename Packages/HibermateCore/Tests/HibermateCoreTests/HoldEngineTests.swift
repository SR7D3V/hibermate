import Foundation
import Testing
@testable import HibermateCore

/// Drives a `HoldEngine` through time with explicit conditions.
struct Harness {
    var engine = HoldEngine()
    var now: Double = 1_000
    var c = Conditions(holdWanted: false, lidClosed: true)
    var limits = EffectiveLimits.defaults(fanless: false)

    @discardableResult
    mutating func step(_ dt: Double = 0) -> [Effect] {
        now += dt
        return engine.update(now: now, conditions: c, limits: limits)
    }

    /// Advances in small ticks, the way the app's timer does, collecting effects.
    @discardableResult
    mutating func run(for seconds: Double, tick: Double = 5) -> [Effect] {
        var all: [Effect] = []
        var elapsed = 0.0
        while elapsed < seconds {
            let dt = min(tick, seconds - elapsed)
            all += step(dt)
            elapsed += dt
        }
        return all
    }

    mutating func startHolding() {
        c.holdWanted = true
        #expect(step() == [.beginHold])
        #expect(engine.phase == .holding)
    }
}

@Suite("Hold state machine: basic transitions")
struct HoldEngineBasicTests {
    @Test func idleToHoldingWhenWorkStarts() {
        var h = Harness()
        h.startHolding()
        #expect(h.step(5) == [], "no duplicate beginHold while holding")
    }

    @Test func graceThenReleaseAndSleepWhenLidClosed() {
        var h = Harness()
        h.startHolding()
        h.c.holdWanted = false
        #expect(h.step() == [])
        guard case .grace = h.engine.phase else { Issue.record("expected grace"); return }
        #expect(h.run(for: 55) == [])
        let effects = h.run(for: 10)
        #expect(effects == [.endHold(.graceExpired), .sleepNow(.graceExpired)])
        #expect(h.engine.phase == .idle)
    }

    @Test func graceReturnsToHoldingWhenWorkResumes() {
        var h = Harness()
        h.startHolding()
        h.c.holdWanted = false
        h.step()
        h.run(for: 30)
        h.c.holdWanted = true
        #expect(h.step() == [], "resuming from grace doesn't re-toggle the helper")
        #expect(h.engine.phase == .holding)
    }

    @Test func lidOpenAtReleaseDoesNotSleep() {
        var h = Harness()
        h.c.lidClosed = false
        h.startHolding()
        h.c.holdWanted = false
        let effects = h.run(for: 70)
        #expect(effects == [.endHold(.graceExpired)])
    }

    @Test func externalDisplayDoesNotSleep() {
        var h = Harness()
        h.c.externalDisplayConnected = true
        h.startHolding()
        h.c.holdWanted = false
        #expect(h.run(for: 70) == [.endHold(.graceExpired)])
    }

    @Test func otherSleepAssertionDoesNotSleep() {
        var h = Harness()
        h.c.otherSleepAssertions = true
        h.startHolding()
        h.c.holdWanted = false
        #expect(h.run(for: 70) == [.endHold(.graceExpired)])
    }

    @Test func unknownSensorsNeverSleep() {
        for mutate in [{ (c: inout Conditions) in c.lidClosed = nil },
                       { (c: inout Conditions) in c.externalDisplayConnected = nil },
                       { (c: inout Conditions) in c.otherSleepAssertions = nil }] {
            var h = Harness()
            mutate(&h.c)
            h.startHolding()
            h.c.holdWanted = false
            #expect(h.run(for: 70) == [.endHold(.graceExpired)])
        }
    }

    @Test func updatesAreIdempotent() {
        var h = Harness()
        h.startHolding()
        for _ in 0..<5 { #expect(h.step() == []) }
        h.c.holdWanted = false
        h.run(for: 70)
        for _ in 0..<5 { #expect(h.step() == []) }
    }
}

@Suite("Hardware safety: thermal")
struct ThermalSafetyTests {
    @Test func criticalForcesSleepEvenWithOtherAssertions() {
        var h = Harness()
        h.c.otherSleepAssertions = true
        h.startHolding()
        h.c.thermal = .critical
        #expect(h.step() == [.endHold(.thermalCritical), .sleepNow(.thermalCritical),
                             .notifySafetyRelease(.thermalCritical, slept: true)])
    }

    @Test func criticalWithExternalDisplayReleasesWithoutSleep() {
        var h = Harness()
        h.c.externalDisplayConnected = true
        h.startHolding()
        h.c.thermal = .critical
        #expect(h.step() == [.endHold(.thermalCritical), .notifySafetyRelease(.thermalCritical, slept: false)])
    }

    @Test func criticalWithLidOpenReleasesWithoutSleep() {
        var h = Harness()
        h.c.lidClosed = false
        h.startHolding()
        h.c.thermal = .critical
        #expect(h.step() == [.endHold(.thermalCritical), .notifySafetyRelease(.thermalCritical, slept: false)])
    }

    @Test func seriousForcesImmediateReleaseRespectingAssertions() {
        var h = Harness()
        h.startHolding()
        h.c.thermal = .serious
        #expect(h.step() == [.endHold(.thermalSerious), .sleepNow(.thermalSerious),
                             .notifySafetyRelease(.thermalSerious, slept: true)])

        var h2 = Harness()
        h2.c.otherSleepAssertions = true
        h2.startHolding()
        h2.c.thermal = .serious
        #expect(h2.step() == [.endHold(.thermalSerious), .notifySafetyRelease(.thermalSerious, slept: false)])
    }

    @Test func seriousDuringGraceAlsoReleases() {
        var h = Harness()
        h.startHolding()
        h.c.holdWanted = false
        h.step()
        h.c.thermal = .serious
        #expect(h.step(1).first == .endHold(.thermalSerious))
    }

    @Test(arguments: [(false, 600.0), (true, 300.0)])
    func sustainedFairTimeoutDependsOnFans(fanless: Bool, timeout: Double) {
        var h = Harness()
        h.limits = .defaults(fanless: fanless)
        h.startHolding()
        h.c.thermal = .fair
        #expect(h.run(for: timeout - 5, tick: 5) == [])
        let effects = h.run(for: 10, tick: 5)
        #expect(effects.first == .endHold(.thermalSustainedFair))
        #expect(effects.contains(.notifySafetyRelease(.thermalSustainedFair, slept: true)))
    }

    @Test func fairTimerResetsWhenItCoolsDown() {
        var h = Harness()
        h.startHolding()
        h.c.thermal = .fair
        h.run(for: 500)
        h.c.thermal = .nominal
        h.step(5)
        h.c.thermal = .fair
        #expect(h.run(for: 500) == [], "timer restarted after cooling")
    }

    @Test func fairWithLidOpenDoesNotTimeOut() {
        var h = Harness()
        h.c.lidClosed = false
        h.startHolding()
        h.c.thermal = .fair
        #expect(h.run(for: 1200) == [])
    }

    @Test func fairWithUnknownLidCountsAsClosed() {
        var h = Harness()
        h.c.lidClosed = nil
        h.startHolding()
        h.c.thermal = .fair
        #expect(h.run(for: 700).first == .endHold(.thermalSustainedFair))
    }

    @Test(arguments: [ThermalLevel.serious, .critical])
    func neverStartsUnderHighThermal(level: ThermalLevel) {
        var h = Harness()
        h.c.thermal = level
        h.c.holdWanted = true
        #expect(h.run(for: 60) == [])
        #expect(h.engine.phase == .idle)
    }

    @Test func mayStartWhenFair() {
        var h = Harness()
        h.c.thermal = .fair
        h.c.holdWanted = true
        #expect(h.step() == [.beginHold])
    }

    @Test func neverResumesAfterThermalRelease() {
        var h = Harness()
        h.startHolding()
        h.c.thermal = .serious
        h.step()
        h.c.thermal = .nominal
        #expect(h.run(for: 600) == [], "latched: lid is still closed")
        #expect(h.engine.latchedReason == .thermalSerious)
    }
}

@Suite("Hardware safety: battery, Low Power Mode, max hold")
struct PowerSafetyTests {
    @Test func batteryCrossingThresholdReleases() {
        var h = Harness()
        h.c.power = .battery(percent: 40)
        h.startHolding()
        h.c.power = .battery(percent: 21)
        #expect(h.step() == [])
        h.c.power = .battery(percent: 20)
        #expect(h.step() == [.endHold(.batteryLow), .sleepNow(.batteryLow), .notifySafetyRelease(.batteryLow, slept: true)])
    }

    @Test func neverStartsAtOrBelowThreshold() {
        var h = Harness()
        h.c.power = .battery(percent: 20)
        h.c.holdWanted = true
        #expect(h.step() == [])
    }

    @Test func unknownPowerIsFailSafe() {
        var h = Harness()
        h.c.power = .unknown
        h.c.holdWanted = true
        #expect(h.step() == [])
        h.c.power = .ac
        h.startHolding()
        h.c.power = .unknown
        #expect(h.step().first == .endHold(.powerUnknown))
    }

    @Test func higherUserThresholdIsHonored() {
        var h = Harness()
        var s = UserSettings()
        s.batteryThreshold = 50
        h.limits = s.effectiveLimits(fanless: false)
        h.c.power = .battery(percent: 60)
        h.startHolding()
        h.c.power = .battery(percent: 50)
        #expect(h.step().first == .endHold(.batteryLow))
    }

    @Test func lowPowerModeCapsHoldAt30Minutes() {
        var h = Harness()
        h.c.lowPowerMode = true
        h.startHolding()
        #expect(h.run(for: 1795) == [])
        #expect(h.run(for: 10).first == .endHold(.lowPowerModeLimit))
    }

    @Test func lowPowerModeUsesShorterMaxHold() {
        var h = Harness()
        var s = UserSettings()
        s.maxHold = 15 * 60
        h.limits = s.effectiveLimits(fanless: false)
        h.c.lowPowerMode = true
        h.startHolding()
        #expect(h.run(for: 15 * 60 + 5).first == .endHold(.lowPowerModeLimit))
    }

    @Test func defaultMaxHoldIsFourHours() {
        var h = Harness()
        h.startHolding()
        #expect(h.run(for: 4 * 3600 - 10, tick: 60) == [])
        #expect(h.run(for: 20).first == .endHold(.maxHoldReached))
    }

    @Test func maxHoldCountsTimeInGrace() {
        var h = Harness()
        var s = UserSettings()
        s.maxHold = 15 * 60
        h.limits = s.effectiveLimits(fanless: false)
        h.startHolding()
        // Alternate idle/working so the hold keeps bouncing through grace.
        var released = false
        for i in 0..<40 {
            h.c.holdWanted = i % 2 == 0
            if h.step(30).contains(.endHold(.maxHoldReached)) { released = true; break }
        }
        #expect(released)
    }

    @Test func twelveHourHardCeilingCannotBeExceeded() {
        var h = Harness()
        var s = UserSettings()
        s.maxHold = 100 * 3600
        h.limits = s.effectiveLimits(fanless: false)
        #expect(h.limits.maxHold == 12 * 3600)
        h.startHolding()
        #expect(h.run(for: 12 * 3600 - 60, tick: 60) == [])
        #expect(h.run(for: 120, tick: 60).first == .endHold(.maxHoldReached))

        // Even limits built by hand past the ceiling are capped by the engine.
        var h2 = Harness()
        h2.limits.maxHold = 48 * 3600
        h2.startHolding()
        #expect(h2.run(for: 12 * 3600 + 60, tick: 60).contains(.endHold(.maxHoldReached)))
    }

    @Test func timeRemainingReflectsCap() {
        var h = Harness()
        h.startHolding()
        h.run(for: 3600)
        #expect(h.engine.timeRemaining(now: h.now, conditions: h.c, limits: h.limits) == TimeInterval(3 * 3600))
        h.c.lowPowerMode = true
        #expect(h.engine.timeRemaining(now: h.now, conditions: h.c, limits: h.limits) == 0)
    }
}

@Suite("Re-arm latch after a safety release")
struct LatchTests {
    @Test func requiresLidOpenThermalOkAndBattery() {
        var h = Harness()
        h.c.power = .battery(percent: 50)
        h.startHolding()
        h.c.power = .battery(percent: 19)
        h.step()
        #expect(h.engine.latchedReason == .batteryLow)

        // Battery recovers but lid still closed.
        h.c.power = .battery(percent: 60)
        #expect(h.run(for: 60) == [])
        // Lid opened, but battery only at threshold + 4.
        h.c.power = .battery(percent: 24)
        h.c.lidClosed = false
        #expect(h.step(5) == [])
        // Battery at threshold + 5 re-arms.
        h.c.power = .battery(percent: 25)
        #expect(h.step(5) == [.beginHold])
    }

    @Test func acCountsAsBatteryRecovered() {
        var h = Harness()
        h.startHolding()
        h.c.thermal = .serious
        h.step()
        h.c.thermal = .fair
        h.c.lidClosed = false
        #expect(h.step(5) == [.beginHold])
    }

    @Test func lidOpenedEarlierStillCountsOnceThermalRecovers() {
        var h = Harness()
        h.startHolding()
        h.c.thermal = .critical
        h.step()
        h.c.lidClosed = false
        #expect(h.step(5) == [], "still critical")
        h.c.lidClosed = true
        h.c.thermal = .nominal
        #expect(h.step(5) == [.beginHold], "lid was opened after the release")
    }

    @Test func maxHoldCannotChainWithLidClosed() {
        var h = Harness()
        var s = UserSettings()
        s.maxHold = 15 * 60
        h.limits = s.effectiveLimits(fanless: false)
        h.startHolding()
        h.run(for: 15 * 60 + 10)
        #expect(h.engine.latchedReason == .maxHoldReached)
        #expect(h.run(for: 3600, tick: 60) == [], "a new prompt can't start another window")
    }

    @Test func normalReleasesDoNotLatch() {
        var h = Harness()
        h.startHolding()
        h.c.holdWanted = false
        h.run(for: 70)
        #expect(h.engine.latchedReason == nil)
        h.c.holdWanted = true
        #expect(h.step() == [.beginHold])
    }
}

@Suite("Fail safe, user commands")
struct FailSafeTests {
    @Test func helperNotReadyMeansNoHold() {
        var h = Harness()
        h.c.helperReady = false
        h.c.holdWanted = true
        #expect(h.run(for: 60) == [])
    }

    @Test func wrongAppLocationMeansNoHold() {
        var h = Harness()
        h.c.appLocationOK = false
        h.c.holdWanted = true
        #expect(h.run(for: 60) == [])
    }

    @Test func helperLostMidHoldReleasesWithoutSleep() {
        var h = Harness()
        h.startHolding()
        h.c.helperReady = false
        #expect(h.step() == [.endHold(.helperUnavailable)])
    }

    @Test func helperFailedCommand() {
        var h = Harness()
        h.startHolding()
        #expect(h.engine.handle(.helperFailed, now: h.now, conditions: h.c) == [.endHold(.helperUnavailable)])
    }

    @Test func releaseNowDoesNotSleepAndWaitsForIdle() {
        var h = Harness()
        h.startHolding()
        #expect(h.engine.handle(.releaseNow, now: h.now, conditions: h.c) == [.endHold(.userReleased)])
        #expect(h.run(for: 60) == [], "same work still running: don't re-hold")
        h.c.holdWanted = false
        h.step(5)
        h.c.holdWanted = true
        #expect(h.step(5) == [.beginHold], "new work may hold again")
    }

    @Test func pauseBlocksUntilExpiry() {
        var h = Harness()
        h.startHolding()
        #expect(h.engine.handle(.pause(until: h.now + 3600), now: h.now, conditions: h.c) == [.endHold(.paused)])
        #expect(h.run(for: 3590, tick: 60) == [])
        #expect(h.run(for: 20) == [.beginHold])
    }

    @Test func quitReleasesCleanlyWithoutSleep() {
        var h = Harness()
        h.startHolding()
        #expect(h.engine.handle(.quit, now: h.now, conditions: h.c) == [.endHold(.quitting)])
        #expect(h.engine.handle(.quit, now: h.now, conditions: h.c) == [], "idempotent")
    }
}

@Suite("Why a hold can't start")
struct StartBlockerTests {
    @Test func reportsEachBlocker() {
        var h = Harness()
        let limits = h.limits
        h.c.holdWanted = true
        #expect(h.engine.startBlocker(h.c, limits: limits) == nil)
        h.c.power = .battery(percent: 19)
        #expect(h.engine.startBlocker(h.c, limits: limits) == .batteryLow(percent: 19, threshold: 20))
        #expect(h.step() == [], "and no hold starts")
        h.c.power = .ac
        h.c.thermal = .serious
        #expect(h.engine.startBlocker(h.c, limits: limits) == .tooHot(.serious))
        h.c.thermal = .nominal
        h.c.helperReady = false
        #expect(h.engine.startBlocker(h.c, limits: limits) == .setupIncomplete)
        h.c.helperReady = true
        h.c.power = .unknown
        #expect(h.engine.startBlocker(h.c, limits: limits) == .powerUnknown)
    }

    @Test func latchAndPauseAreReported() {
        var h = Harness()
        h.startHolding()
        h.c.thermal = .critical
        h.step()
        h.c.thermal = .nominal
        #expect(h.engine.startBlocker(h.c, limits: h.limits) == .latched(.thermalCritical))
        var p = Harness()
        _ = p.engine.handle(.pause(until: p.now + 60), now: p.now, conditions: p.c)
        #expect(p.engine.startBlocker(p.c, limits: p.limits) == .paused)
    }

    @Test func explanationsArePlain() {
        #expect(StartBlocker.batteryLow(percent: 19, threshold: 20).explanation.contains("19%"))
    }
}
