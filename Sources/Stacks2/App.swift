import AppKit
import Carbon
import WebKit

@MainActor
private let appDelegate = AppDelegate()

@main
enum Stacks2 {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = appDelegate
        app.run()
    }
}

struct Shortcut {
    var shift = true
    var ctrl = true
    var alt = false
    var command = false
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
    var shortcut = Shortcut()
    var window: NSWindow?
    var webView: WKWebView?
    var hatch: Hatch?
    var outsideClicks: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: "stacks")
        config.userContentController.add(bridge, name: "stacks")

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
        window.hidesOnDeactivate = true
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                guard let panel = appDelegate.window, panel.isVisible else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    panel.orderOut(nil)
                }
            }
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
        Task.detached {
            store.start()
            if let socket = store.socketPath(), !socket.isEmpty {
                ClipboardActor.register(socket: socket)
            }
            await MainActor.run {
                let watch = PasteboardWatch(store: store)
                appDelegate.pasteboard = watch
                watch.start()
                appDelegate.webView?.load(URLRequest(url: URL(string: "stacks://local/")!))
                appDelegate.showPanel()
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
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let webView { window?.makeFirstResponder(webView) }
    }

    func togglePanel() {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            showPanel()
        }
    }

    func handle(_ body: [String: Any]) {
        switch body["cmd"] as? String {
        case "hide":
            window?.orderOut(nil)
        case "show":
            showPanel()
        case "copy":
            let text = body["text"] as? String ?? ""
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if (body["hide"] as? Bool) != false {
                window?.orderOut(nil)
            }
        case "open":
            if let raw = body["url"] as? String, let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        case "follow":
            let after = body["after"] as? String ?? ""
            guard let socket = xs.socketPath(), !socket.isEmpty else { return }
            if follow == nil { follow = LogFollow() }
            follow?.start(socket: socket, after: after) { line in
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
                hash: body["hash"] as? String ?? ""
            )
            let socket = xs.socketPath() ?? ""
            let why = xs.failureMessage()
            Task.detached {
                let json = socket.isEmpty
                    ? XsJSON.object(["error": why])
                    : XsHTTP.call(socket: socket, req: req)
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
    static func register(socket: String) {
        guard
            let file = Bundle.module.url(forResource: "clipboard", withExtension: "nu"),
            let data = try? Data(contentsOf: file)
        else {
            NSLog("stacks2: clipboard actor script missing")
            return
        }
        let json = XsHTTP.post(
            socket: socket,
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
