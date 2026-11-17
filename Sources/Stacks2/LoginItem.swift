import AppKit
import ServiceManagement

/// Open at Login, as a menu item with a check mark. It is turned on once, the
/// first time Stacks2 runs as an .app; after that it is the user's choice, and
/// System Settings › General › Login Items shows the same switch.
@MainActor
final class LoginItem: NSObject, NSMenuItemValidation {
    let menuItem = NSMenuItem(title: "Open at Login", action: #selector(toggle), keyEquivalent: "")
    private var service: SMAppService { .mainApp }

    override init() {
        super.init()
        menuItem.target = self
        let defaults = UserDefaults.standard
        if Bundle.main.bundleURL.pathExtension == "app", !defaults.bool(forKey: "openAtLoginSet") {
            defaults.set(true, forKey: "openAtLoginSet")
            try? service.register()
        }
    }

    /// Read when the menu opens, so a change made in System Settings shows.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.state = service.status == .enabled ? .on : .off
        return Bundle.main.bundleURL.pathExtension == "app"
    }

    @objc private func toggle() {
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {}
        // Turned off in System Settings: only the user can turn it back on there.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
