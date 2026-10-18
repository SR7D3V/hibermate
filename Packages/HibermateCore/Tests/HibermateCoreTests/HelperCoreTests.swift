import Foundation
import Testing
@testable import HibermateCore

/// Stands in for `pmset disablesleep`. Never touches the real system.
final class FakeSleepControl: SleepDisabledControl {
    var value: Bool
    var writes: [Bool] = []
    var failWrites = false

    init(_ value: Bool) { self.value = value }

    func read() throws -> Bool { value }

    func write(_ disabled: Bool) throws {
        if failWrites { throw HelperError.settingFailed }
        writes.append(disabled)
        value = disabled
    }
}

final class FakeStateStore: HelperStateStore {
    var state: HelperHoldState?
    var failSave = false

    func load() -> HelperHoldState? { state }

    func save(_ s: HelperHoldState) throws {
        if failSave { throw HelperError.stateNotPersisted }
        state = s
    }

    func clear() throws { state = nil }
}

final class FakeClock {
    var now: TimeInterval = 0
}

@Suite("Privileged helper core")
struct HelperCoreTests {
    func make(_ initial: Bool) -> (HelperCore, FakeSleepControl, FakeStateStore, FakeClock) {
        let control = FakeSleepControl(initial)
        let store = FakeStateStore()
        let clock = FakeClock()
        return (HelperCore(control: control, store: store, clock: { clock.now }), control, store, clock)
    }

    @Test func holdAndRestore() throws {
        let (core, control, store, _) = make(false)
        try core.setSleepDisabled(true)
        #expect(control.value == true)
        #expect(store.state?.originalSleepDisabled == false)
        try core.setSleepDisabled(false)
        #expect(control.value == false)
        #expect(store.state == nil)
    }

    @Test func userAlreadyHadSleepDisabledIsNeverReset() throws {
        let (core, control, _, clock) = make(true)
        try core.setSleepDisabled(true)
        #expect(control.writes.isEmpty)
        try core.setSleepDisabled(false)
        core.connectionInvalidated()
        clock.now = 10_000
        core.tick()
        #expect(control.value == true)
        #expect(!control.writes.contains(false), "never wrote 0 over the user's 1")
    }

    @Test func restoreWithoutHoldNeverTouchesSetting() throws {
        let (core, control, _, _) = make(true)
        try core.setSleepDisabled(false)
        core.restore()
        core.terminate()
        core.reconcileOnStart()
        #expect(control.writes.isEmpty)
    }

    @Test func deadManSwitchRestoresAfterTwoMinutesWithoutHeartbeat() throws {
        let (core, control, _, clock) = make(false)
        try core.setSleepDisabled(true)
        for _ in 0..<10 {
            clock.now += 30
            core.heartbeat()
            core.tick()
        }
        #expect(control.value == true, "heartbeats keep it held")
        // App crashes: no more heartbeats.
        clock.now += 119
        core.tick()
        #expect(control.value == true)
        clock.now += 2
        core.tick()
        #expect(control.value == false)
        #expect(!core.holdActive)
    }

    @Test func connectionDropRestoresImmediately() throws {
        let (core, control, _, _) = make(false)
        try core.setSleepDisabled(true)
        core.connectionInvalidated()
        #expect(control.value == false)
    }

    @Test func sigtermRestores() throws {
        let (core, control, _, _) = make(false)
        try core.setSleepDisabled(true)
        core.terminate()
        #expect(control.value == false)
    }

    @Test func rebootMidHoldIsReconciledOnStart() throws {
        let control = FakeSleepControl(false)
        let store = FakeStateStore()
        let clock = FakeClock()
        try HelperCore(control: control, store: store, clock: { clock.now }).setSleepDisabled(true)
        // A new helper process after a reboot; the setting persisted as 1.
        let fresh = HelperCore(control: control, store: store, clock: { clock.now })
        fresh.reconcileOnStart()
        #expect(control.value == false)
        #expect(store.state == nil)
    }

    @Test func originalIsSavedBeforeChanging() throws {
        let (core, control, store, _) = make(false)
        store.failSave = true
        #expect(throws: HelperError.stateNotPersisted) { try core.setSleepDisabled(true) }
        #expect(control.value == false, "nothing changed when state couldn't be saved")
    }

    @Test func repeatedHoldKeepsFirstOriginal() throws {
        let (core, control, store, _) = make(false)
        try core.setSleepDisabled(true)
        try core.setSleepDisabled(true)
        #expect(store.state?.originalSleepDisabled == false)
        #expect(control.writes == [true])
    }

    @Test func failedRestoreIsRetriedOnTick() throws {
        let (core, control, store, _) = make(false)
        try core.setSleepDisabled(true)
        control.failWrites = true
        core.restore()
        #expect(store.state != nil, "kept so it can retry")
        control.failWrites = false
        core.tick()
        #expect(control.value == false)
        #expect(store.state == nil)
    }

    @Test func heartbeatWithoutHoldDoesNothing() {
        let (core, control, _, _) = make(false)
        core.heartbeat()
        core.tick()
        #expect(control.writes.isEmpty)
    }
}

@Suite("Helper sleeps a lid-closed Mac when the app is lost")
struct HelperAppLossSleepTests {
    final class World {
        var lid: Bool? = true
        var sleeps = 0
    }

    func make(_ world: World) -> (HelperCore, FakeSleepControl, FakeClock) {
        let control = FakeSleepControl(false)
        let clock = FakeClock()
        let core = HelperCore(control: control, store: FakeStateStore(), clock: { clock.now },
                              appLoss: .init(lidClosed: { world.lid }, sleep: { world.sleeps += 1 }))
        return (core, control, clock)
    }

    @Test func crashWithLidClosedRestoresThenSleeps() throws {
        let w = World()
        let (core, control, _) = make(w)
        try core.setSleepDisabled(true)
        core.heartbeat(externalDisplayConnected: false)
        core.connectionInvalidated()
        #expect(control.value == false, "restored first")
        #expect(w.sleeps == 1)
    }

    @Test func deadManWithLidClosedSleeps() throws {
        let w = World()
        let (core, control, clock) = make(w)
        try core.setSleepDisabled(true)
        core.heartbeat(externalDisplayConnected: false)
        clock.now += 121
        core.tick()
        #expect(control.value == false)
        #expect(w.sleeps == 1, "the display report was 121 s old, still within 180 s")
    }

    @Test func lidOpenOrUnknownNeverSleeps() throws {
        for lid in [false, nil] as [Bool?] {
            let w = World()
            w.lid = lid
            let (core, _, _) = make(w)
            try core.setSleepDisabled(true)
            core.heartbeat(externalDisplayConnected: false)
            core.connectionInvalidated()
            #expect(w.sleeps == 0)
        }
    }

    @Test func externalDisplayOrNoReportNeverSleeps() throws {
        let w = World()
        let (core, _, _) = make(w)
        try core.setSleepDisabled(true)
        core.connectionInvalidated() // never received a display report
        #expect(w.sleeps == 0)

        let w2 = World()
        let (core2, _, _) = make(w2)
        try core2.setSleepDisabled(true)
        core2.heartbeat(externalDisplayConnected: true)
        core2.connectionInvalidated()
        #expect(w2.sleeps == 0, "clamshell with an external display is a desktop in use")
    }

    @Test func staleDisplayReportNeverSleeps() throws {
        let w = World()
        let (core, _, clock) = make(w)
        try core.setSleepDisabled(true)
        core.heartbeat(externalDisplayConnected: false)
        clock.now += 200
        core.connectionInvalidated()
        #expect(w.sleeps == 0)
    }

    @Test func normalQuitAndSigtermNeverSleep() throws {
        let w = World()
        let (core, _, _) = make(w)
        try core.setSleepDisabled(true)
        core.heartbeat(externalDisplayConnected: false)
        try core.setSleepDisabled(false) // the app quits cleanly and releases first
        core.connectionInvalidated()      // then its connection closes
        #expect(w.sleeps == 0)

        try core.setSleepDisabled(true)
        core.heartbeat(externalDisplayConnected: false)
        core.terminate() // uninstall or shutdown
        #expect(w.sleeps == 0)
    }

    @Test func failedRestoreDoesNotSleepUntilItSucceeds() throws {
        let w = World()
        let (core, control, _) = make(w)
        try core.setSleepDisabled(true)
        core.heartbeat(externalDisplayConnected: false)
        control.failWrites = true
        core.connectionInvalidated()
        #expect(w.sleeps == 0, "never sleep while SleepDisabled is still set")
        control.failWrites = false
        core.tick()
        #expect(control.value == false)
        #expect(w.sleeps == 1)
    }
}
