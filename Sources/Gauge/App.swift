import AppKit
import ServiceManagement

private struct Feed {
    var snapshot: UsageSnapshot?
    var errorMessage: String?
    var retryAt = Date.distantPast
    var failures = 0
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let menu = NSMenu()
    private let client = UsageClient()
    private let estimates = EstimateStore()
    private var feeds = Dictionary(uniqueKeysWithValues: Provider.allCases.map {
        ($0, Feed(snapshot: loadJSON($0.cacheName, as: UsageSnapshot.self)))
    })
    private var estimate = loadJSON("estimate-v2.json", as: Estimate.self)
    private var estimateRefreshedAt = Date.distantPast
    private var loginError: String?
    private var refreshing = false
    private var timer: Timer?
    private var countdownTimer: Timer?
    private var sleeping = false
    private var menuOpen = false
    private var limitViews: [LimitView] = []
    private let width: CGFloat = 292
    private var iconKey = ""
    private lazy var settings = SettingsController(
        onProvidersChanged: { [weak self] in self?.providersChanged() },
        setLaunchAtLogin: { [weak self] in self?.setLaunchAtLogin($0) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = width
        rebuildMenu()
        updateIcon()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 10
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        configureLogin()
        refresh()
    }

    private func configureLogin() {
        let service = SMAppService.mainApp
        let defaults = UserDefaults.standard
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let registeredPath = defaults.string(forKey: "loginRegistrationPath")
        if service.status == .enabled || service.status == .requiresApproval {
            defaults.set(path, forKey: "loginRegistrationPath")
            if service.status == .requiresApproval {
                loginError = "Approve Gauge in System Settings → General → Login Items."
            }
            return
        }
        // Register a new installation location, but respect a later user disable.
        // The old didConfigureLogin flag cannot prove that registration succeeded.
        if service.status == .notRegistered && registeredPath == path { return }
        do {
            try service.register()
            if service.status == .enabled || service.status == .requiresApproval {
                defaults.set(path, forKey: "loginRegistrationPath")
            }
            if service.status != .enabled {
                loginError = "Check Gauge in System Settings → General → Login Items."
            }
        } catch {
            loginError = "Could not enable Launch at Login: \(error.localizedDescription)"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
            loginError = service.status == .requiresApproval
                ? "Approve Gauge in System Settings → General → Login Items." : nil
        } catch {
            loginError = "Could not change Launch at Login: \(error.localizedDescription)"
        }
        // Remember this location so configureLogin respects the choice on next launch.
        UserDefaults.standard.set(Bundle.main.bundleURL.standardizedFileURL.path, forKey: "loginRegistrationPath")
    }

    private func providersChanged() {
        estimateRefreshedAt = .distantPast
        updateIcon()
        if menuOpen { rebuildMenu() }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        rebuildMenu()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.limitViews.forEach { $0.updateCountdown() } }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    @objc private func willSleep() { sleeping = true }
    @objc private func didWake() { sleeping = false; refresh() }
    @objc private func manualRefresh() { refresh(force: true) }
    @objc private func openSettings() { settings.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func refresh(force: Bool = false) {
        guard !refreshing, !sleeping else { return }
        let now = Date()
        let providers = Provider.enabled
        let due = providers.filter { provider in
            let feed = feeds[provider]!
            let isStale = feed.snapshot.map { now.timeIntervalSince($0.fetchedAt) >= provider.refreshInterval - 5 } ?? true
            return now >= feed.retryAt && (force || feed.errorMessage != nil || isStale)
        }
        let refreshEstimate = force || now.timeIntervalSince(estimateRefreshedAt) >= 55
        guard !due.isEmpty || refreshEstimate else { return }
        refreshing = true
        if menuOpen { rebuildMenu() }
        let client = client
        Task {
            async let newEstimate = estimates.refresh(providers: providers)
            await withTaskGroup(of: (Provider, Result<UsageSnapshot, Error>).self) { group in
                for provider in due {
                    group.addTask {
                        do { return (provider, .success(try await client.fetch(provider))) }
                        catch { return (provider, .failure(error)) }
                    }
                }
                for await (provider, result) in group { apply(result, to: provider) }
            }
            let result = await newEstimate
            estimate = result
            estimateRefreshedAt = Date()
            saveJSON(result, name: "estimate-v2.json")
            refreshing = false
            updateIcon()
            if menuOpen { rebuildMenu() }
        }
    }

    private func apply(_ result: Result<UsageSnapshot, Error>, to provider: Provider) {
        var feed = feeds[provider]!
        switch result {
        case .success(let next):
            feed.snapshot = next
            saveJSON(next, name: provider.cacheName)
            feed.errorMessage = nil
            feed.failures = 0
            feed.retryAt = .distantPast
        case .failure(let error):
            feed.failures = min(feed.failures + 1, 6)
            let delay = max((error as? GaugeError)?.retryAfter ?? 60, min(1800, 30 * pow(2, Double(feed.failures))))
            feed.retryAt = Date().addingTimeInterval(delay)
            feed.errorMessage = (error as? GaugeError)?.message ?? "Could not refresh usage. Check your connection."
        }
        feeds[provider] = feed
    }

    private func updateIcon() {
        let rings = Provider.enabled.map { provider in
            let feed = feeds[provider]!
            return StatusRing(provider: provider, percent: feed.snapshot?.windows.first?.percent,
                              stale: feed.errorMessage != nil || feed.snapshot == nil)
        }
        let key = rings.map { "\($0.provider)-\($0.percent ?? -1)-\($0.stale)" }.joined(separator: ",")
        if key != iconKey {
            status.button?.image = statusImage(rings: rings)
            iconKey = key
        }
    }

    @discardableResult
    private func item(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }
    private func rebuildMenu() {
        menu.removeAllItems()
        limitViews = []
        let providers = Provider.enabled
        for provider in providers {
            let feed = feeds[provider]!
            let plan = feed.snapshot?.plan.map { " · \($0.capitalized)" } ?? ""
            let header = NSMenuItem()
            header.view = HeaderView(title: "\(provider.name)\(plan)", provider: provider, width: width)
            menu.addItem(header)
            if let snapshot = feed.snapshot {
                for window in snapshot.windows {
                    let view = LimitView(window: window, color: provider.color, width: width)
                    limitViews.append(view)
                    let row = NSMenuItem()
                    row.view = view
                    menu.addItem(row)
                }
                if let credits = snapshot.credits { item(credits).isEnabled = false }
            } else { item(refreshing ? "Loading usage…" : "Usage unavailable").isEnabled = false }
            if let errorMessage = feed.errorMessage {
                let warning = item(feed.snapshot == nil ? "Usage update failed" : "Using saved usage · Update failed")
                warning.isEnabled = false
                warning.toolTip = errorMessage
                if let snapshot = feed.snapshot {
                    let updated = item("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    updated.isEnabled = false
                }
            }
            menu.addItem(.separator())
        }
        if let estimate {
            let statistics = NSMenuItem()
            statistics.view = EstimateView(estimate: estimate, providers: providers, width: width)
            menu.addItem(statistics)
        } else {
            item("Loading local statistics…").isEnabled = false
        }
        menu.addItem(.separator())
        let refreshItem = item(refreshing ? "Refreshing…" : "Refresh", action: #selector(manualRefresh))
        refreshItem.isEnabled = !refreshing
        item("Settings…", action: #selector(openSettings)).keyEquivalent = ","
        if let warning = estimate?.warning {
            let warningItem = item("Statistics may be incomplete")
            warningItem.isEnabled = false
            warningItem.toolTip = warning
        }
        if let loginError {
            let warning = item("Launch at Login needs attention")
            warning.isEnabled = false
            warning.toolTip = loginError
        }
        menu.addItem(.separator())
        item("Quit Gauge", action: #selector(quit))
    }
}

@main
struct Gauge {
    static func main() async {
        if CommandLine.arguments.contains("--login-status") {
            let status: String
            switch SMAppService.mainApp.status {
            case .notRegistered: status = "not registered"
            case .enabled: status = "enabled"
            case .requiresApproval: status = "requires approval"
            case .notFound: status = "not found"
            @unknown default: status = "unknown"
            }
            print("Launch at login: \(status)")
            print("App: \(Bundle.main.bundleURL.path)")
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            // Read-only integration check. Never print credentials or session contents.
            for provider in Provider.allCases {
                do {
                    let snapshot = try await UsageClient().fetch(provider)
                    print("\(provider.name): \(snapshot.windows.map { "\($0.label)=\(Int($0.percent))%" }.joined(separator: ", "))")
                } catch { print("\(provider.name): \(error.localizedDescription)") }
            }
            let result = await EstimateStore().refresh(providers: Provider.allCases)
            saveJSON(result, name: "estimate-v2.json")
            for (provider, days) in result.dailyCosts.sorted(by: { $0.key < $1.key }) {
                print("Daily \(provider): \(days.map { String(format: "%.2f", $0) }.joined(separator: " "))")
            }
            print("Estimates: today=\(result.today.costText)/\(result.today.tokenText), 7d=\(result.week.costText)/\(result.week.tokenText), 30d=\(result.month.costText)/\(result.month.tokenText)")
            if let warning = result.warning { print(warning) }
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
