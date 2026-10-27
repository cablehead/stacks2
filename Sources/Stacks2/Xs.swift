import Foundation

/// Talks to `xs serve` over its Unix socket. The web view never opens that
/// socket itself; it posts log / append / cas through the stacks message handler.
final class XsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: String?
    private var process: Process?
    private var ownsProcess = false
    private var failure: String?

    let storeURL: URL
    private let binary: URL?

    init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Stacks2", isDirectory: true)
        storeURL = base.appendingPathComponent("store", isDirectory: true)
        binary = Self.locateBinary()
    }

    func socketPath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return socket
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
        let sock = storeURL.appendingPathComponent("sock").path
        if FileManager.default.fileExists(atPath: sock), XsHTTP.version(socket: sock) {
            setSocket(sock, owns: nil)
            return
        }
        guard let binary else {
            setFailure("xs binary not found")
            return
        }
        let logURL = storeURL.deletingLastPathComponent().appendingPathComponent("xs-serve.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let err = FileHandle(forWritingAtPath: logURL.path)
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["serve", storeURL.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            setFailure("xs failed to start: \(error.localizedDescription)")
            return
        }
        lock.lock()
        process = proc
        ownsProcess = true
        lock.unlock()

        for _ in 0..<40 {
            if XsHTTP.version(socket: sock) {
                setSocket(sock, owns: nil)
                return
            }
            if !proc.isRunning {
                if XsHTTP.version(socket: sock) {
                    lock.lock()
                    ownsProcess = false
                    socket = sock
                    failure = nil
                    lock.unlock()
                    return
                }
                let note = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                setFailure(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "xs serve exited"
                    : note.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        setFailure("xs did not answer on its socket")
    }

    func stop() {
        lock.lock()
        let proc = ownsProcess ? process : nil
        ownsProcess = false
        lock.unlock()
        proc?.terminate()
    }

    private func setSocket(_ path: String, owns: Bool?) {
        lock.lock()
        socket = path
        failure = nil
        if let owns { ownsProcess = owns }
        lock.unlock()
    }

    private func setFailure(_ message: String) {
        lock.lock()
        failure = message
        socket = nil
        lock.unlock()
        NSLog("stacks2 xs: \(message)")
    }

    private static func locateBinary() -> URL? {
        let fixed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("git/stacks2/.bin/xs")
        if FileManager.default.isExecutableFile(atPath: fixed.path) { return fixed }
        let pipe = Pipe()
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["xs"]
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        guard (try? which.run()) != nil else { return nil }
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
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

enum XsHTTP {
    static func version(socket: String) -> Bool {
        let (code, data, _) = request(socket: socket, args: ["http://localhost/version"], timeout: "2")
        guard code == 200, let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("version")
    }

    static func call(socket: String, req: XsRequest) -> String {
        switch req.cmd {
        case "log":
            let (code, data, err) = request(socket: socket, args: ["http://localhost/"])
            guard code == 200 else { return XsJSON.object(["error": httpError(code, data, err)]) }
            return ndjson(data)
        case "cas":
            let (code, data, err) = request(socket: socket, args: ["http://localhost/cas/\(req.hash)"])
            guard code == 200 else { return XsJSON.object(["error": httpError(code, data, err)]) }
            if let text = String(data: data, encoding: .utf8) {
                return XsJSON.object(["text": text])
            }
            return XsJSON.object(["b64": data.base64EncodedString()])
        case "append":
            return append(socket: socket, topic: req.topic, metaJSON: req.metaJSON, body: req.body)
        default:
            return XsJSON.object(["error": "unknown cmd"])
        }
    }

    static func post(socket: String, topic: String, query: String? = nil, metaJSON: String = "{}", body: Data) -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacks2-body-\(UUID().uuidString)")
        do {
            try body.write(to: file)
        } catch {
            return XsJSON.object(["error": error.localizedDescription])
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let b64 = Data(metaJSON.utf8).base64EncodedString()
        var url = "http://localhost/append/\(topic)"
        if let query, !query.isEmpty { url += "?\(query)" }
        let (code, data, err) = request(socket: socket, args: [
            "-X", "POST",
            "-H", "xs-meta: \(b64)",
            "--data-binary", "@\(file.path)",
            url,
        ])
        guard code == 200 else { return XsJSON.object(["error": httpError(code, data, err)]) }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data),
            let out = try? JSONSerialization.data(withJSONObject: obj),
            let text = String(data: out, encoding: .utf8)
        else { return XsJSON.object(["error": "xs append returned unreadable JSON"]) }
        return text
    }

    private static func append(socket: String, topic: String, metaJSON: String, body: String) -> String {
        post(socket: socket, topic: topic, metaJSON: metaJSON, body: Data(body.utf8))
    }

    private static func ndjson(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? ""
        var items: [Any] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let row = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: row)
            else { continue }
            items.append(obj)
        }
        guard
            let out = try? JSONSerialization.data(withJSONObject: items),
            let json = String(data: out, encoding: .utf8)
        else { return XsJSON.object(["error": "could not read the log"]) }
        return json
    }

    private static func httpError(_ code: Int, _ data: Data, _ err: String) -> String {
        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !body.isEmpty { return body }
        if !err.isEmpty { return err }
        return "xs HTTP \(code)"
    }

    private static func request(socket: String, args: [String], timeout: String = "20") -> (Int, Data, String) {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacks2-xs-\(UUID().uuidString)")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = [
            "-sS", "--globoff", "--max-time", timeout, "--unix-socket", socket, "--path-as-is",
            "-o", out.path, "-w", "%{http_code}",
        ] + args
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        do {
            try proc.run()
        } catch {
            return (0, Data(), error.localizedDescription)
        }
        let codeData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let code = Int(String(data: codeData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        let body = (try? Data(contentsOf: out)) ?? Data()
        try? FileManager.default.removeItem(at: out)
        let err = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (code, body, err)
    }
}
