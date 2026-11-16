import AppKit
import Carbon
import WebKit

@MainActor
private let appDelegate = AppDelegate()

@main
enum Stacks2 {
    static func main() {
        let app = NSApplication.shared
        // An accessory app, as cablehead/stacks is (no Dock icon): the panel
        // shows over the app in front without taking activation from it.
        app.setActivationPolicy(.accessory)
        app.mainMenu = Stacks2.menu()
        app.delegate = appDelegate
        app.run()
    }

    /// A menu that is never shown (an accessory app has no menu bar), for its
    /// key equivalents: Cmd+C, Cmd+V, Cmd+X, Cmd+A, Cmd+Z in the panel's text
    /// fields, and Cmd+Q to quit.
    static func menu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu(title: "Stacks2")
        app.addItem(withTitle: "Quit Stacks2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Stacks2", action: nil, keyEquivalent: "").submenu = app
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return main
    }
}

struct Shortcut: Codable {
    var shift = true
    var ctrl = true
    var alt = false
    var command = false

    private static let defaultsKey = "shortcut"

    /// The shortcut chosen last time, or the default when none was saved.
    static func load() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(Shortcut.self, from: data) else {
            return Shortcut()
        }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Shortcut.defaultsKey)
        }
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Notification.Name {
    static let stacksHotkey = Notification.Name("stacksHotkey")
}

final class Hotkey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(_ shortcut: Shortcut) {
        if handler == nil {
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, _ -> OSStatus in
                    NotificationCenter.default.post(name: .stacksHotkey, object: nil)
                    return noErr
                },
                1,
                &spec,
                nil,
                &handler
            )
        }
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        var modifiers: UInt32 = 0
        if shortcut.shift { modifiers |= UInt32(shiftKey) }
        if shortcut.ctrl { modifiers |= UInt32(controlKey) }
        if shortcut.alt { modifiers |= UInt32(optionKey) }
        if shortcut.command { modifiers |= UInt32(cmdKey) }
        let hotKeyID = EventHotKeyID(signature: 0x53544B32, id: 1)
        RegisterEventHotKey(49, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let handler = SchemeHandler()
    let bridge = Bridge()
    let hotkey = Hotkey()
    let xs = XsStore()
    private var pasteboard: PasteboardWatch?
    private var follow: LogFollow?
    /// SIGTERM quits as Cmd+Q does, so xs stops cleanly (xs.stopping, flush).
    private var terminate: DispatchSourceSignal?
    var shortcut = Shortcut.load()
    var window: NSWindow?
    var webView: WKWebView?
    var hatch: Hatch?
    var menuBar: MenuBar?
    var outsideClicks: Any?
    /// The app in front when the panel was shown.
    var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        terminate = term
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: "stacks")
        config.userContentController.add(bridge, name: "stacks")
        // The panel's shortcut toggles start from the saved shortcut.
        config.userContentController.addUserScript(WKUserScript(
            source: "window.stacksShortcut = \(shortcut.json);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView

        let window = StacksPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        // Off: Stacks2 never becomes the active app, and a panel that hides
        // on deactivate would never be drawn. Clicks outside hide it instead.
        window.hidesOnDeactivate = false
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                guard let panel = appDelegate.window, panel.isVisible else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    panel.orderOut(nil)
                    appDelegate.tellPage("__panelHidden")
                }
            }
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: 7)
        window.isMovableByWindowBackground = true
        // Transient: closed in Mission Control, as Spotlight is.
        window.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = webView
        window.center()
        self.window = window
        bridge.window = window

        let hatch = Hatch(webView: webView)
        hatch.start()
        self.hatch = hatch

        NotificationCenter.default.addObserver(forName: .stacksHotkey, object: nil, queue: .main) { _ in
            Task { @MainActor in
                appDelegate.togglePanel()
            }
        }
        hotkey.register(shortcut)

        let store = xs
        menuBar = MenuBar(
            shortcut: { appDelegate.shortcut },
            failure: { store.isOpen ? nil : store.failureMessage() },
            show: { appDelegate.showPanel() }
        )
        Task.detached {
            store.start()
            if store.isOpen {
                ClipboardActor.register()
            }
            await MainActor.run {
                let watch = PasteboardWatch(store: store)
                appDelegate.pasteboard = watch
                watch.start()
                // Start hidden: a restart must not put the panel over what
                // you're typing into. The hotkey shows it.
                appDelegate.webView?.load(URLRequest(url: URL(string: "stacks://local/")!))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        follow?.stop()
        pasteboard?.stop()
        xs.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showPanel() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        // tauri-nspanel's show: order front regardless of which app is
        // active, then make the panel key. Stacks2 is never activated.
        if let webView { window?.makeFirstResponder(webView) }
        window?.orderFrontRegardless()
        window?.makeKey()
        tellPage("__panelShown")
    }

    /// Call a page hook with no arguments, if the page has it.
    func tellPage(_ hook: String) {
        webView?.evaluateJavaScript("window.\(hook) && window.\(hook)()", completionHandler: nil)
    }

    /// Hide the panel and give focus back to the app that was in front.
    func hidePanel() {
        window?.orderOut(nil)
        tellPage("__panelHidden")
        // Only if Stacks2 did become active (launched, say): hand it back.
        if NSApp.isActive, let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
    }

    func togglePanel() {
        if window?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    /// Open an image clip in Preview. Preview opens files only, so the PNG is
    /// written once to ~/Library/Caches/Stacks2/preview/, named by its hash
    /// (the same clip reuses its file), and the panel hides as Preview comes
    /// to the front.
    func openInPreview(_ png: Data, hash: String) {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stacks2/preview", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = hash.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let name = safe.isEmpty ? UUID().uuidString : String(String.UnicodeScalarView(safe).prefix(24))
        let url = dir.appendingPathComponent("\(name).png")
        if !fm.fileExists(atPath: url.path) {
            do { try png.write(to: url, options: .atomic) } catch { NSSound.beep(); return }
        }
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        hidePanel()
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: config) { _, error in
            if let error { NSLog("stacks2: open in Preview failed: \(error)") }
        }
    }

    /// The bytes of a `data:image/png;base64,...` URL, as the panel holds an image clip.
    static func pngData(fromDataURL url: String) -> Data? {
        guard url.hasPrefix("data:image/png;base64,"),
              let comma = url.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    func handle(_ body: [String: Any]) {
        switch body["cmd"] as? String {
        case "hide":
            hidePanel()
        case "show":
            showPanel()
        case "copy":
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let image = body["image"] as? String, let png = Self.pngData(fromDataURL: image) {
                pasteboard.setData(png, forType: .png)
            } else {
                pasteboard.setString(body["text"] as? String ?? "", forType: .string)
            }
            // A concealed clip goes back marked concealed, so other clipboard
            // tools skip it too, and isn't recorded again here.
            if body["concealed"] as? Bool == true {
                pasteboard.setData(Data(), forType: PasteboardWatch.concealed)
                self.pasteboard?.skip(pasteboard.changeCount)
            }
            if (body["hide"] as? Bool) != false {
                hidePanel()
            }
        case "open":
            // As with an image: the panel hides as the browser comes forward.
            if let raw = body["url"] as? String, let url = URL(string: raw) {
                hidePanel()
                NSWorkspace.shared.open(url)
            }
        case "openImage":
            if let image = body["image"] as? String, let png = Self.pngData(fromDataURL: image) {
                openInPreview(png, hash: body["hash"] as? String ?? "")
            }
        case "saveImage":
            // A marked-up image from the panel's editor, saved into its clip
            // as the PNG's bytes (the page can only append text).
            // A concealed clip's markup stays ephemeral, the image in its meta.
            if let image = body["image"] as? String, let png = Self.pngData(fromDataURL: image),
               let id = body["id"] as? String, !id.isEmpty, xs.isOpen {
                let concealed = body["concealed"] as? Bool == true
                let meta = concealed
                    ? (try? JSONSerialization.data(withJSONObject: ["id": id, "concealed": true, "image": image]))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    : XsJSON.object(["id": id])
                Task.detached {
                    let json = concealed
                        ? Xs.append(topic: "clip.update", query: "ttl=ephemeral", metaJSON: meta, body: Data())
                        : Xs.append(topic: "clip.update", metaJSON: meta, body: png)
                    if json.contains("\"error\"") { NSLog("stacks2 saveImage: \(json)") }
                }
            }
        case "follow":
            let after = body["after"] as? String ?? ""
            guard xs.isOpen else { return }
            if follow == nil { follow = LogFollow() }
            follow?.start(after: after) { line in
                Task { @MainActor in
                    appDelegate.deliver(line)
                }
            }
        case "resetWindow":
            window?.setContentSize(NSSize(width: 1000, height: 600))
            window?.center()
            showPanel()
        case "shortcut":
            shortcut.shift = body["shift"] as? Bool ?? false
            shortcut.ctrl = body["ctrl"] as? Bool ?? false
            shortcut.alt = body["alt"] as? Bool ?? false
            shortcut.command = body["command"] as? Bool ?? false
            shortcut.save()
            hotkey.register(shortcut)
        case "log", "append", "cas":
            let id = body["id"] as? String ?? ""
            var metaJSON = "{}"
            if let meta = body["meta"], JSONSerialization.isValidJSONObject(meta),
               let data = try? JSONSerialization.data(withJSONObject: meta),
               let text = String(data: data, encoding: .utf8) {
                metaJSON = text
            }
            let req = XsRequest(
                id: id,
                cmd: body["cmd"] as? String ?? "",
                topic: body["topic"] as? String ?? "",
                metaJSON: metaJSON,
                body: body["body"] as? String ?? "",
                hash: body["hash"] as? String ?? "",
                query: (body["ttl"] as? String).map { "ttl=\($0)" } ?? ""
            )
            let open = xs.isOpen
            let why = xs.failureMessage()
            Task.detached {
                let json = open
                    ? Xs.call(req)
                    : XsJSON.object(["error": why])
                await MainActor.run {
                    appDelegate.finish(id: id, json: json)
                }
            }
        default:
            break
        }
    }

    func finish(id: String, json: String) {
        let script = "window.__xsDone(\(XsJSON.jsString(id)), \(json))"
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    func deliver(_ line: String) {
        guard let webView else { return }
        let hidden = window?.isVisible != true
        let script = "window.__xsLive && window.__xsLive(\(XsJSON.jsString(line)), \(hidden ? "true" : "false"))"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

enum ClipboardActor {
    static func register() {
        guard
            let file = Bundle.module.url(forResource: "clipboard", withExtension: "nu"),
            let data = try? Data(contentsOf: file)
        else {
            NSLog("stacks2: clipboard actor script missing")
            return
        }
        let json = Xs.append(
            topic: "xs.actor.clipboard.create",
            query: "ttl=last:1",
            body: data
        )
        if json.contains("\"error\"") {
            NSLog("stacks2 clipboard actor: \(json)")
        }
    }
}

/// macOS gives Ctrl-N / Ctrl-P (and Ctrl-H / Ctrl-L) to the focused text field
/// as emacs cursor commands. The panel uses those chords to move, so they are
/// turned into page key events before the field sees them.
final class StacksPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let script = panelChordScript(event), let web = contentView as? WKWebView {
            web.evaluateJavaScript(script, completionHandler: nil)
            return
        }
        super.sendEvent(event)
    }

    /// The web view's accessibility hit test returns nothing, so HoverWin's
    /// pointer lookup falls through this panel and moves the window behind it.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        let bounds = MainActor.assumeIsolated { frame }
        return bounds.contains(point) ? self : nil
    }
}

private func panelChordScript(_ event: NSEvent) -> String? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let mods = flags.intersection([.shift, .control, .option, .command])
    if mods == .command, event.keyCode == 29 || event.keyCode == 82 {
        return keyScript(key: "0", code: "Digit0", ctrl: false, shift: false, alt: false, meta: true)
    }
    return controlChordScript(event)
}

private func controlChordScript(_ event: NSEvent) -> String? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.control) else { return nil }
    let key: String
    let code: String
    switch event.keyCode {
    case 45: key = "n"; code = "KeyN"
    case 35: key = "p"; code = "KeyP"
    case 4: key = "h"; code = "KeyH"
    case 37: key = "l"; code = "KeyL"
    default: return nil
    }
    return keyScript(
        key: key,
        code: code,
        ctrl: true,
        shift: flags.contains(.shift),
        alt: flags.contains(.option),
        meta: flags.contains(.command)
    )
}

private func keyScript(key: String, code: String, ctrl: Bool, shift: Bool, alt: Bool, meta: Bool) -> String {
    let b: (Bool) -> String = { $0 ? "true" : "false" }
    return """
    (document.activeElement||document).dispatchEvent(new KeyboardEvent("keydown",{\
    key:"\(key)",code:"\(code)",ctrlKey:\(b(ctrl)),shiftKey:\(b(shift)),altKey:\(b(alt)),metaKey:\(b(meta)),\
    bubbles:true,cancelable:true}))
    """
}

final class Bridge: NSObject, WKScriptMessageHandler {
    weak var window: NSWindow?
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let body = message.body as? [String: Any] ?? [:]
        Task { @MainActor in
            appDelegate.handle(body)
        }
    }
}

@MainActor
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        guard url?.path == "/" || url?.path == "" || url?.path == nil else {
            fail(urlSchemeTask, status: 404)
            return
        }
        guard
            let file = Bundle.module.url(forResource: "panel", withExtension: "html"),
            let data = try? Data(contentsOf: file)
        else {
            fail(urlSchemeTask, status: 500)
            return
        }
        let response = HTTPURLResponse(
            url: url ?? URL(string: "stacks://local/")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": String(data.count),
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func fail(_ task: any WKURLSchemeTask, status: Int) {
        let response = HTTPURLResponse(
            url: task.request.url ?? URL(string: "stacks://local/")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "0"]
        )!
        task.didReceive(response)
        task.didFinish()
    }
}
