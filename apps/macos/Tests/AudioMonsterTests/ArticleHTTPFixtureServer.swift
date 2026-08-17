import Foundation
import Network

/// Loopback HTTP server for WebKit tests. Binds to 127.0.0.1 so App Transport
/// Security's localhost exception applies; remote-HTTP coverage lives in the
/// packaged Info.plist verifier, because XCTest hosts do not load the app plist.
final class ArticleHTTPFixtureServer: @unchecked Sendable {
    struct Request: Equatable, Sendable {
        var method: String
        var path: String
        var query: String?
    }

    struct Response: Sendable {
        var status: Int
        var reason: String
        var headers: [String: String]
        var body: Data

        static func html(_ html: String, status: Int = 200) -> Response {
            let body = Data(html.utf8)
            return Response(
                status: status,
                reason: Self.reason(for: status),
                headers: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Content-Length": "\(body.count)",
                    "Connection": "close",
                ],
                body: body
            )
        }

        static func redirect(to location: String, status: Int = 302) -> Response {
            Response(
                status: status,
                reason: Self.reason(for: status),
                headers: [
                    "Location": location,
                    "Content-Length": "0",
                    "Connection": "close",
                ],
                body: Data()
            )
        }

        static func status(_ status: Int) -> Response {
            let reason = Self.reason(for: status)
            let body = Data("HTTP \(status) \(reason)".utf8)
            return Response(
                status: status,
                reason: reason,
                headers: [
                    "Content-Type": "text/plain; charset=utf-8",
                    "Content-Length": "\(body.count)",
                    "Connection": "close",
                ],
                body: body
            )
        }

        fileprivate func encoded() -> Data {
            var header = "HTTP/1.1 \(status) \(reason)\r\n"
            for (name, value) in headers {
                header += "\(name): \(value)\r\n"
            }
            header += "\r\n"
            var data = Data(header.utf8)
            data.append(body)
            return data
        }

        private static func reason(for status: Int) -> String {
            switch status {
            case 200: "OK"
            case 301: "Moved Permanently"
            case 302: "Found"
            case 307: "Temporary Redirect"
            case 308: "Permanent Redirect"
            case 404: "Not Found"
            case 429: "Too Many Requests"
            case 503: "Service Unavailable"
            default: "Error"
            }
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.audiomonster.http-fixture")
    private let lock = NSLock()
    private var routes: [String: Response]
    private var hangingPaths: Set<String>
    private(set) var port: UInt16

    var origin: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    func url(_ path: String) -> URL {
        URL(string: path, relativeTo: origin)!.absoluteURL
    }

    static func start(
        routes: [String: Response],
        hangingPaths: Set<String> = []
    ) async throws -> ArticleHTTPFixtureServer {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters, on: .any)
        let server = ArticleHTTPFixtureServer(
            listener: listener,
            routes: routes,
            hangingPaths: hangingPaths
        )

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let resumeOnce = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce.run { continuation.resume() }
                case .failed(let error):
                    resumeOnce.run { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                server.handle(connection)
            }
            listener.start(queue: server.queue)
        }

        guard let assignedPort = listener.port else {
            listener.cancel()
            throw ArticleHTTPFixtureServerError.missingPort
        }
        server.port = assignedPort.rawValue
        return server
    }

    private init(
        listener: NWListener,
        routes: [String: Response],
        hangingPaths: Set<String>
    ) {
        self.listener = listener
        self.routes = routes
        self.hangingPaths = hangingPaths
        self.port = 0
    }

    func set(_ path: String, response: Response) {
        lock.lock()
        routes[path] = response
        lock.unlock()
    }

    func finish() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
                return
            }
            let header = buffer[..<headerRange.lowerBound]
            guard let request = Self.parseRequest(header) else {
                connection.cancel()
                return
            }
            if self.isHanging(request.path) {
                return
            }
            let response = self.response(for: request.path)
            connection.send(
                content: response.encoded(),
                completion: .contentProcessed { _ in
                    connection.cancel()
                }
            )
        }
    }

    private func isHanging(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hangingPaths.contains(path)
    }

    private func response(for path: String) -> Response {
        lock.lock()
        defer { lock.unlock() }
        return routes[path] ?? .status(404)
    }

    private static func parseRequest(_ header: Data.SubSequence) -> Request? {
        guard let text = String(data: Data(header), encoding: .utf8) else { return nil }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = pieces.isEmpty ? "/" : String(pieces[0])
        let query = pieces.count > 1 ? String(pieces[1]) : nil
        return Request(method: method, path: path.isEmpty ? "/" : path, query: query)
    }
}

private enum ArticleHTTPFixtureServerError: Error {
    case missingPort
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

enum ArticleHTTPFixturePages {
    static let essay = """
        <!doctype html>
        <html>
        <head><title>The HTTP Essay</title></head>
        <body>
          <nav>Publisher chrome that must never be narrated.</nav>
          <article>
            <h1>The HTTP Essay</h1>
            <p>This fixture exists so Audio Monster can prove it reads ordinary HTTP pages, not only encrypted ones.</p>
            <p>Many independent publishers still serve essays over HTTP, and a reader that rejects those pages is incomplete.</p>
            <p>The third paragraph gives the extractor enough continuous prose to treat this as a real article rather than a stub.</p>
          </article>
        </body>
        </html>
        """

    static let redirectedEssay = """
        <!doctype html>
        <html>
        <head><title>The Redirected HTTP Essay</title></head>
        <body>
          <article>
            <h1>The Redirected HTTP Essay</h1>
            <p>The submitted address was only a hop. The browser must keep that original URL while recording the final article location.</p>
            <p>Relative and absolute redirects are both ordinary on the public web, including HTTP to HTTP hops before any encryption begins.</p>
            <p>This paragraph exists so the redirected document still clears the readable-prose threshold used by the native extractor.</p>
          </article>
        </body>
        </html>
        """

    static func essayWithBrokenImage(imagePath: String) -> String {
        """
        <!doctype html>
        <html>
        <head><title>The Illustrated HTTP Essay</title></head>
        <body>
          <article>
            <h1>The Illustrated HTTP Essay</h1>
            <p>A missing image must not discard an otherwise readable HTTP article, because broken subresources are common on long-lived independent sites.</p>
            <img src="\(imagePath)" alt="A figure that is intentionally absent.">
            <p>The extractor should still recover this second paragraph after the image request fails with an HTTP error.</p>
            <p>A third paragraph keeps the document above the readable-prose threshold even if the image alt text is ignored.</p>
          </article>
        </body>
        </html>
        """
    }
}
