import AppKit
import Foundation

/// Polls the general pasteboard and appends each change as a `pb.recv` frame.
/// The body matches `x-macos-pasteboard`: change count, frontmost app, and every
/// pasteboard type as base64. An xs actor turns that frame into a clip.
@MainActor
final class PasteboardWatch {
    private var timer: Timer?
    private var changeCount: Int
    private let store: XsStore

    init(store: XsStore) {
        self.store = store
        changeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Markers apps put on what they copy (nspasteboard.org). A concealed copy
    /// (a password) is recorded as an ephemeral frame, with the record in its
    /// meta: it is never stored, and only live followers (the clipboard actor,
    /// the panel) see it. A transient copy is not recorded at all.
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Stacks2 copying a concealed clip back: that change is not recorded
    /// again, since the clip is already in the panel.
    func skip(_ change: Int) {
        changeCount = change
    }

    private func tick() {
        let pasteboard = NSPasteboard.general
        let current = pasteboard.changeCount
        guard current != changeCount else { return }
        changeCount = current
        let types = Set((pasteboard.pasteboardItems ?? []).flatMap(\.types))
        if types.contains(Self.transient) { return }
        let concealed = types.contains(Self.concealed)
        guard let body = Self.record(pasteboard, change: current), store.isOpen else { return }
        var meta = "{}"
        var stored = body
        if concealed,
           let record = try? JSONSerialization.jsonObject(with: Data(body.utf8)),
           let data = try? JSONSerialization.data(withJSONObject: ["concealed": true, "record": record]),
           let text = String(data: data, encoding: .utf8) {
            meta = text
            stored = ""
        } else if concealed {
            return
        }
        let req = XsRequest(
            id: "",
            cmd: "append",
            topic: "pb.recv",
            metaJSON: meta,
            body: stored,
            hash: "",
            query: concealed ? "ttl=ephemeral" : ""
        )
        Task.detached {
            let json = Xs.call(req)
            if json.contains("\"error\"") {
                NSLog("stacks2 pasteboard: \(json)")
            }
        }
    }

    /// Same record `x-macos-pasteboard` writes as one JSON line.
    private static func record(_ pasteboard: NSPasteboard, change: Int) -> String? {
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        var types: [String: String] = [:]
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                if let data = pasteboard.data(forType: type) {
                    types[type.rawValue] = data.base64EncodedString()
                }
            }
        }
        let row: [String: Any] = [
            "change": change,
            "source": source,
            "types": types,
        ]
        guard
            JSONSerialization.isValidJSONObject(row),
            let data = try? JSONSerialization.data(withJSONObject: row),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}
