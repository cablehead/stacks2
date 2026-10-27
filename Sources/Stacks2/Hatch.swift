import Foundation
import Network
import WebKit

/// Loopback HTTP hatch. POST /eval with a JavaScript body. The response is the
/// value the web view returned, as text.
final class Hatch: @unchecked Sendable {
    static let portFile = "/tmp/stacks2.hatch.port"

    private let webView: WKWebView
    private var listener: NWListener?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port {
                    try? String(port.rawValue).write(toFile: Self.portFile, atomically: true, encoding: .utf8)
                }
            }
            listener.start(queue: .global())
            self.listener = listener
        } catch {
            NSLog("hatch failed to listen: \(error.localizedDescription)")
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        let buffer = Buffer()
        read(connection, into: buffer)
    }

    private func read(_ connection: NWConnection, into buffer: Buffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data { buffer.data.append(data) }
            if error != nil || isComplete || buffer.isComplete {
                self?.answer(connection, request: buffer.data)
                return
            }
            self?.read(connection, into: buffer)
        }
    }

    private func answer(_ connection: NWConnection, request: Data) {
        let script = httpBody(request)
        Task {
            let text = await self.evaluate(script)
            let payload = Data(text.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            var bytes = Data(header.utf8)
            bytes.append(payload)
            connection.send(content: bytes, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func evaluate(_ script: String) async -> String {
        await evaluateOnMain(script)
    }

    @MainActor
    private func evaluateOnMain(_ script: String) async -> String {
        do {
            let value = try await webView.evaluateJavaScript(script)
            return stringify(value)
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }
}

private final class Buffer: @unchecked Sendable {
    var data = Data()

    var isComplete: Bool { httpRequestComplete(data) }
}

private func httpRequestComplete(_ data: Data) -> Bool {
    guard let text = String(data: data, encoding: .utf8),
          let headerEnd = text.range(of: "\r\n\r\n")
    else { return false }
    let headers = text[..<headerEnd.lowerBound]
    let length = contentLength(String(headers))
    let bodyStart = text.distance(from: text.startIndex, to: headerEnd.upperBound)
    return data.count >= bodyStart + length
}

private func contentLength(_ headers: String) -> Int {
    for line in headers.split(separator: "\r\n") {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
            return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }
    return 0
}

private func httpBody(_ data: Data) -> String {
    guard let text = String(data: data, encoding: .utf8),
          let headerEnd = text.range(of: "\r\n\r\n")
    else { return "" }
    return String(text[headerEnd.upperBound...])
}

private func stringify(_ value: Any?) -> String {
    switch value {
    case nil:
        return ""
    case let text as String:
        return text
    case let number as NSNumber:
        return number.stringValue
    default:
        if let value, JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value as Any)
    }
}
