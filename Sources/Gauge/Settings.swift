import AppKit
import ServiceManagement

@MainActor
final class SettingsController: NSObject {
    private var window: NSWindow?
    private var providerBoxes: [NSButton] = []
    private let loginBox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let onProvidersChanged: () -> Void
    private let setLaunchAtLogin: (Bool) -> Void

    init(onProvidersChanged: @escaping () -> Void, setLaunchAtLogin: @escaping (Bool) -> Void) {
        self.onProvidersChanged = onProvidersChanged
        self.setLaunchAtLogin = setLaunchAtLogin
    }

    func show() {
        if window == nil { window = makeWindow() }
        update()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let heading = NSTextField(labelWithString: "Show usage for")
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        providerBoxes = Provider.allCases.enumerated().map { index, provider in
            let box = NSButton(checkboxWithTitle: provider.name, target: self, action: #selector(toggleProvider))
            box.tag = index
            return box
        }
        loginBox.target = self
        loginBox.action = #selector(toggleLogin)
        let stack = NSStackView(views: [heading] + providerBoxes + [loginBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: providerBoxes.last!)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 10),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Gauge Settings"
        window.isReleasedWhenClosed = false
        window.contentView = stack
        window.center()
        return window
    }

    private func update() {
        for (box, provider) in zip(providerBoxes, Provider.allCases) {
            box.state = provider.isEnabled ? .on : .off
        }
        let status = SMAppService.mainApp.status
        loginBox.state = status == .enabled || status == .requiresApproval ? .on : .off
    }

    @objc private func toggleProvider(_ sender: NSButton) {
        let provider = Provider.allCases[sender.tag]
        // Keep at least one provider so the menu bar item stays meaningful.
        if sender.state == .off && Provider.enabled == [provider] {
            sender.state = .on
            return
        }
        provider.isEnabled = sender.state == .on
        onProvidersChanged()
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        setLaunchAtLogin(sender.state == .on)
        update()
    }
}
