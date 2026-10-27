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

    private func tick() {
        let pasteboard = NSPasteboard.general
        let current = pasteboard.changeCount
        guard current != changeCount else { return }
        let body = Self.record(pasteboard, change: current)
        changeCount = pasteboard.changeCount
        guard let body, let socket = store.socketPath(), !socket.isEmpty else { return }
        let req = XsRequest(
            id: "",
            cmd: "append",
            topic: "pb.recv",
            metaJSON: "{}",
            body: body,
            hash: ""
        )
        Task.detached {
            let json = XsHTTP.call(socket: socket, req: req)
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
