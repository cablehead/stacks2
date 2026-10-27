import Foundation

/// Tails the xs log over the store socket and hands each new stack or clip
/// frame to the page. The web view cannot open the Unix socket itself.
final class LogFollow: @unchecked Sendable {
    private let lock = NSLock()
    private var proc: Process?
    private var generation = 0

    func stop() {
        lock.lock()
        generation += 1
        let proc = self.proc
        self.proc = nil
        lock.unlock()
        proc?.terminate()
    }

    func start(socket: String, after: String, onLine: @escaping @Sendable (String) -> Void) {
        stop()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var url = "http://localhost/?follow=true"
        if !after.isEmpty {
            url += "&after=\(after)"
        }
        proc.arguments = ["-sS", "-N", "--globoff", "--path-as-is", "--unix-socket", socket, url]
        proc.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe
        do {
            try proc.run()
        } catch {
            NSLog("stacks2 follow: \(error.localizedDescription)")
            return
        }
        lock.lock()
        generation += 1
        let gen = generation
        self.proc = proc
        lock.unlock()
        let handle = pipe.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            var buf = Data()
            while true {
                self.lock.lock()
                let current = self.generation
                self.lock.unlock()
                if current != gen { break }
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buf.append(chunk)
                while let nl = buf.firstIndex(of: 0x0A) {
                    let lineData = buf.subdata(in: 0..<nl)
                    buf.removeSubrange(0...nl)
                    guard
                        let line = String(data: lineData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        !line.isEmpty,
                        Self.forPage(line)
                    else { continue }
                    self.lock.lock()
                    let still = self.generation == gen
                    self.lock.unlock()
                    if still { onLine(line) }
                }
            }
        }
    }

    /// The page only folds stack and clip frames. Raw pasteboard frames stay out.
    private static func forPage(_ line: String) -> Bool {
        guard
            let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let topic = obj["topic"] as? String
        else { return false }
        return topic.hasPrefix("stack.") || topic.hasPrefix("clip.")
    }
}
