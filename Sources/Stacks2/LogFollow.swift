import CXs
import Foundation

/// Follows the xs log and hands each new stack or clip frame to the page.
/// The web view cannot call xs itself.
final class LogFollow: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (id: UInt64, sink: Sink)?

    /// One follow's lines, until it is stopped. Released by xs's closing call.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var live = true
        let onLine: @Sendable (String) -> Void

        init(_ onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

        func end() {
            lock.lock()
            live = false
            lock.unlock()
        }

        func deliver(_ line: String) {
            lock.lock()
            let still = live
            lock.unlock()
            if still && LogFollow.forPage(line) { onLine(line) }
        }
    }

    func stop() {
        lock.lock()
        let old = current
        current = nil
        lock.unlock()
        if let old {
            old.sink.end()
            xs_follow_stop(old.id)
        }
    }

    func start(after: String, onLine: @escaping @Sendable (String) -> Void) {
        stop()
        let sink = Sink(onLine)
        let ctx = Unmanaged.passRetained(sink).toOpaque()
        let query = after.isEmpty ? "" : "after=\(after)"
        let id = xs_follow(query, { ctx, json in
            guard let ctx else { return }
            let sink = Unmanaged<Sink>.fromOpaque(ctx)
            guard let json else {
                sink.release()
                return
            }
            sink.takeUnretainedValue().deliver(String(cString: json))
        }, ctx)
        guard id != 0 else {
            NSLog("stacks2 follow: xs is not running")
            return
        }
        lock.lock()
        current = (id, sink)
        lock.unlock()
    }

    /// The page only folds stack and clip frames, and the text the ocr actor
    /// read in each image. Raw pasteboard frames stay out.
    fileprivate static func forPage(_ line: String) -> Bool {
        guard
            let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let topic = obj["topic"] as? String
        else { return false }
        return topic.hasPrefix("stack.") || topic.hasPrefix("clip.") || topic.hasPrefix("ocr.")
    }
}
