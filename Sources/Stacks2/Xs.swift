import CXs
import Foundation

/// The xs store, in this process: xs is linked in (xs-ffi/), so Stacks2 calls
/// it directly. xs still serves the store's socket, for the xs command. The
/// web view never calls xs itself; it posts log / append / cas through the
/// stacks message handler.
final class XsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var failure: String?

    let storeURL: URL

    init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Stacks2", isDirectory: true)
        storeURL = base.appendingPathComponent("store", isDirectory: true)
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func failureMessage() -> String {
        lock.lock()
        defer { lock.unlock() }
        return failure ?? "xs is not running"
    }

    func start() {
        do {
            try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        } catch {
            setFailure("could not create the store: \(error.localizedDescription)")
            return
        }
        if let err = xs_open(storeURL.path) {
            setFailure(String(cString: err))
            xs_free_string(err)
            return
        }
        lock.lock()
        open = true
        failure = nil
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let was = open
        open = false
        lock.unlock()
        if was { xs_close() }
    }

    private func setFailure(_ message: String) {
        lock.lock()
        failure = message
        open = false
        lock.unlock()
        NSLog("stacks2 xs: \(message)")
    }
}

struct XsRequest: Sendable {
    var id: String
    var cmd: String
    var topic: String
    var metaJSON: String
    var body: String
    var hash: String
}

enum XsJSON {
    static func object(_ fields: [String: String]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: fields),
            let text = String(data: data, encoding: .utf8)
        else { return "{\"error\":\"encode failed\"}" }
        return text
    }

    static func jsString(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let text = String(data: data, encoding: .utf8),
            text.count >= 2
        else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }
}

/// Calls into the linked-in xs. Each returns JSON, `{"error": ...}` on failure.
enum Xs {
    static func call(_ req: XsRequest) -> String {
        switch req.cmd {
        case "log":
            return take(xs_read(""))
        case "cas":
            var len = 0
            var err: UnsafeMutablePointer<CChar>?
            guard let bytes = xs_cas(req.hash, &len, &err) else {
                return XsJSON.object(["error": err.map { take($0) } ?? "xs cas failed"])
            }
            let data = Data(bytes: bytes, count: len)
            xs_free_bytes(bytes, len)
            if let text = String(data: data, encoding: .utf8) {
                return XsJSON.object(["text": text])
            }
            return XsJSON.object(["b64": data.base64EncodedString()])
        case "append":
            return append(topic: req.topic, metaJSON: req.metaJSON, body: Data(req.body.utf8))
        default:
            return XsJSON.object(["error": "unknown cmd"])
        }
    }

    /// Appends to `topic`, `body` into the CAS. `query` takes a TTL:
    /// `ttl=last:1`. Returns the new frame.
    static func append(topic: String, query: String = "", metaJSON: String = "{}", body: Data) -> String {
        body.withUnsafeBytes { raw in
            take(xs_append(topic, query, metaJSON,
                           raw.bindMemory(to: UInt8.self).baseAddress, raw.count))
        }
    }

    private static func take(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
        guard let ptr else { return XsJSON.object(["error": "xs returned nothing"]) }
        defer { xs_free_string(ptr) }
        return String(cString: ptr)
    }
}
