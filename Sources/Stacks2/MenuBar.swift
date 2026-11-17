import AppKit

/// The menu bar icon: how someone who has just opened Stacks2 sees that it is
/// running, finds the panel and its hotkey, and quits it.
@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let show = NSMenuItem(title: "Show Stacks2", action: #selector(showPanel), keyEquivalent: " ")
    private let problem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let login = LoginItem()
    private let shortcut: () -> Shortcut
    private let failure: () -> String?
    private let onShow: () -> Void

    /// `failure` is why the store didn't open, or nil once it has.
    init(shortcut: @escaping () -> Shortcut, failure: @escaping () -> String?, show open: @escaping () -> Void) {
        self.shortcut = shortcut
        self.failure = failure
        onShow = open
        super.init()
        let image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: "Stacks2")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        show.target = self
        menu.addItem(show)
        problem.isEnabled = false
        problem.isHidden = true
        menu.addItem(problem)
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let about = NSMenuItem(title: version.map { "Stacks2 \($0)" } ?? "Stacks2", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(login.menuItem)
        menu.addItem(NSMenuItem(title: "Quit Stacks2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    /// The hotkey can change in the panel, and the store can fail after
    /// launch, so both are read each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = shortcut()
        var mask: NSEvent.ModifierFlags = []
        if s.shift { mask.insert(.shift) }
        if s.ctrl { mask.insert(.control) }
        if s.alt { mask.insert(.option) }
        if s.command { mask.insert(.command) }
        show.keyEquivalentModifierMask = mask
        if let why = failure() {
            problem.title = "Clips aren't being saved: \(why)"
            problem.isHidden = false
        } else {
            problem.isHidden = true
        }
    }

    @objc private func showPanel() {
        onShow()
    }
}
