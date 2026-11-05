import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let menu = NSMenu()
    private let client = UsageClient()
    private let estimates = EstimateStore()
    private var snapshot = loadJSON("usage-v1.json", as: UsageSnapshot.self)
    private var estimate = Estimate()
    private var errorMessage: String?
    private var refreshing = false
    private var retryAt = Date.distantPast
    private var failures = 0
    private var timer: Timer?
    private var countdownTimer: Timer?
    private var sleeping = false
    private var menuOpen = false
    private var limitViews: [LimitView] = []
    private let width: CGFloat = 292
    private var iconKey = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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
        // Register once, respecting subsequent changes in System Settings or this menu.
        if !UserDefaults.standard.bool(forKey: "didConfigureLogin") {
            do {
                if SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
                UserDefaults.standard.set(true, forKey: "didConfigureLogin")
            } catch { errorMessage = "Could not enable Launch at Login: \(error.localizedDescription)" }
        }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        rebuildMenu()
        refresh()
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
    @objc private func openUsage() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            } else { try SMAppService.mainApp.register() }
            UserDefaults.standard.set(true, forKey: "didConfigureLogin")
        } catch { errorMessage = "Launch at Login: \(error.localizedDescription)" }
    }

    private func refresh(force: Bool = false) {
        guard !refreshing, !sleeping, Date() >= retryAt else { return }
        if !force, let snapshot, errorMessage == nil, Date().timeIntervalSince(snapshot.fetchedAt) < 55 { return }
        refreshing = true
        if menuOpen { rebuildMenu() }
        Task {
            async let newEstimate = estimates.refresh()
            do {
                let next = try await client.fetch()
                snapshot = next
                saveJSON(next, name: "usage-v1.json")
                errorMessage = nil
                failures = 0
                retryAt = .distantPast
            } catch {
                failures = min(failures + 1, 6)
                let delay = max((error as? GaugeError)?.retryAfter ?? 60, min(1800, 30 * pow(2, Double(failures))))
                retryAt = Date().addingTimeInterval(delay)
                errorMessage = (error as? GaugeError)?.message ?? "Could not refresh usage. Check your connection."
            }
            estimate = await newEstimate
            refreshing = false
            updateIcon()
            if menuOpen { rebuildMenu() }
        }
    }

    private func updateIcon() {
        let percent = snapshot?.windows.first?.percent
        let stale = errorMessage != nil || snapshot == nil
        let key = "\(percent ?? -1)-\(stale)"
        if key != iconKey {
            status.button?.image = statusImage(percent: percent, stale: stale)
            iconKey = key
        }
        status.button?.toolTip = snapshot.map { data in
            "Codex · " + data.windows.map { "\($0.label): \(Int($0.percent))%" }.joined(separator: " · ")
        } ?? "Codex usage unavailable"
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
        let plan = snapshot?.plan.map { " · \($0.capitalized)" } ?? ""
        item("Codex\(plan)").isEnabled = false
        menu.addItem(.separator())
        if let snapshot {
            for window in snapshot.windows {
                let view = LimitView(window: window, width: width)
                limitViews.append(view)
                let row = NSMenuItem()
                row.view = view
                menu.addItem(row)
            }
            if let credits = snapshot.credits { item(credits).isEnabled = false }
        } else { item(refreshing ? "Loading usage…" : "Usage unavailable").isEnabled = false }
        menu.addItem(.separator())
        let statistics = NSMenuItem()
        statistics.view = EstimateView(estimate: estimate, width: width)
        menu.addItem(statistics)
        menu.addItem(.separator())
        item("Open Codex Usage…", action: #selector(openUsage))
        let refreshItem = item(refreshing ? "Refreshing…" : "Refresh", action: #selector(manualRefresh))
        refreshItem.isEnabled = !refreshing && Date() >= retryAt
        if let errorMessage {
            let warning = item(snapshot == nil ? "Usage update failed" : "Using saved usage · Update failed")
            warning.isEnabled = false
            warning.toolTip = errorMessage
            if let snapshot {
                let updated = item("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                updated.isEnabled = false
            }
        }
        if let warning = estimate.warning {
            let warningItem = item("Statistics may be incomplete")
            warningItem.isEnabled = false
            warningItem.toolTip = warning
        }
        menu.addItem(.separator())
        let login = item("Launch at Login", action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if SMAppService.mainApp.status == .requiresApproval { login.title = "Launch at Login · Approval needed" }
        item("Quit Gauge", action: #selector(quit))
    }
}

@main
struct Gauge {
    static func main() async {
        if CommandLine.arguments.contains("--diagnose") {
            // Read-only integration check. Never print credentials or session contents.
            do {
                let snapshot = try await UsageClient().fetch()
                print("Usage: \(snapshot.windows.map { "\($0.label)=\(Int($0.percent))%" }.joined(separator: ", "))")
            } catch { print("Usage: \(error.localizedDescription)") }
            let result = await EstimateStore().refresh()
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
