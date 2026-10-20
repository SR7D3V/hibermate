import Foundation
import HibermateCore

/// Hibermate's only network access: fetches the latest release's
/// `hibermate-update.json` from GitHub, at most once a day (or when the user
/// clicks Check Now). No cookies, no cache, no identifiers beyond what any
/// HTTPS request carries. It never downloads or installs the app.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case failed
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastCheck: Date?

    private let currentVersion: String
    private let session: URLSession
    private var timer: Timer?
    /// Set by the controller: whether the user allows checks.
    var enabled: () -> Bool = { false }
    private static let lastCheckKey = "lastUpdateCheck"
    private static let lastFoundKey = "lastUpdateFound"

    init() {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        // Show a release found earlier right away, if it's still newer than this build.
        if let found = UserDefaults.standard.string(forKey: Self.lastFoundKey).flatMap(AppVersion.init),
           let current = AppVersion(currentVersion), current < found {
            status = .available(AvailableUpdate(version: found))
        }
    }

    var availableUpdate: AvailableUpdate? {
        if case .available(let update) = status { return update }
        return nil
    }

    /// Checks shortly after launch, then looks once an hour whether a day has passed.
    func start(enabled: @escaping () -> Bool) {
        self.enabled = enabled
        Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer?.tolerance = 300
    }

    func checkIfDue() {
        guard enabled(), UpdatePolicy.isDue(lastCheck: lastCheck, now: Date()) else { return }
        checkNow()
    }

    /// Turning the setting off forgets anything found, so the indicator goes away.
    func settingChanged() {
        if enabled() {
            checkIfDue()
        } else if status != .checking {
            status = .idle
            UserDefaults.standard.removeObject(forKey: Self.lastFoundKey)
        }
    }

    func checkNow() {
        guard status != .checking else { return }
        let previous = status
        status = .checking
        var request = URLRequest(url: UpdatePolicy.feedURL)
        request.setValue("Hibermate", forHTTPHeaderField: "User-Agent")
        Task {
            let result: Status
            do {
                let (data, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    if let update = UpdatePolicy.evaluate(feed: data, currentVersion: currentVersion,
                                                          systemVersion: ProcessInfo.processInfo.operatingSystemVersion) {
                        result = .available(update)
                    } else {
                        result = .upToDate
                    }
                } else if code == 404 {
                    // No published release carries a feed yet.
                    result = .upToDate
                } else {
                    result = .failed
                }
            } catch {
                result = .failed
            }
            finish(result, previous: previous)
        }
    }

    private func finish(_ result: Status, previous: Status) {
        let now = Date()
        lastCheck = now
        UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
        switch result {
        case .available(let update):
            UserDefaults.standard.set(update.version, forKey: Self.lastFoundKey)
            status = result
            appLog.notice("Update available: \(update.version, privacy: .public)")
        case .upToDate:
            UserDefaults.standard.removeObject(forKey: Self.lastFoundKey)
            status = result
        default:
            // Offline or GitHub hiccup: keep showing an update found earlier.
            if case .available = previous { status = previous } else { status = .failed }
            appLog.notice("Update check failed")
        }
        if !enabled() { settingChanged() }
    }
}
