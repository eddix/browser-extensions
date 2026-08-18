import Foundation
import Network

/// A deliberately small HTTP/1.1 server on 127.0.0.1, just enough to receive
/// saves from the browser extension. Hand-written rather than pulled from a
/// package: three endpoints don't justify a dependency in an otherwise
/// dependency-free app.
///
/// **Security.** A localhost port is reachable by script on *any* page you
/// visit, so the port alone is not a boundary (the previous Rust backend
/// allowed every origin, which let any site read the whole bookmark index).
/// Two things close that:
///
/// 1. every request must carry `Authorization: Bearer <token>`, a secret the
///    extension holds and a web page cannot read;
/// 2. CORS is granted only to `chrome-extension://` origins, so even a
///    tokenless probe can't read a reply.
public final class LocalHTTPServer: @unchecked Sendable {

    public struct Request {
        public let method: String
        public let path: String
        public let query: [String: String]
        public let body: Data
        public let origin: String?
        /// Raw `Authorization` header value, checked before routing.
        let authorization: String?

        /// The bearer token, if the header is well-formed.
        var bearerToken: String? {
            guard let raw = authorization else { return nil }
            guard raw.lowercased().hasPrefix("bearer ") else { return raw }
            return String(raw.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        }
    }

    public struct Response {
        public let status: Int
        public let json: Data

        public init(status: Int = 200, json: Data) {
            self.status = status
            self.json = json
        }

        public static func ok<T: Encodable>(_ value: T) -> Response {
            let encoder = JSONEncoder()
            // Keep URLs readable in replies and logs ("/a" not "\/a").
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
            return Response(status: 200, json: data)
        }

        public static func error(_ status: Int, _ message: String) -> Response {
            let payload = ["success": false, "error": message] as [String: Any]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return Response(status: status, json: data)
        }
    }

    /// Callback-style rather than returning a `Response` directly: generating a
    /// summary means waiting on a model, and every connection shares one queue —
    /// blocking it to await would stall every other request.
    public typealias Handler = @Sendable (Request, @escaping @Sendable (Response) -> Void) -> Void

    private let port: UInt16
    private let tokenProvider: @Sendable () -> String
    private let handler: Handler
    /// How long a connection may go without sending anything before we hang up
    /// on it. Times the *reading* of a request only, never the answering of
    /// one: a summary takes tens of seconds, and the clock stops the moment we
    /// have a whole request. Over loopback, bytes that are coming arrive in
    /// milliseconds, so the default is generous by orders of magnitude — it is
    /// a parameter so a test can make the wait short enough to watch.
    private let readTimeout: TimeInterval
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.eddix.nodia.http")

    public private(set) var lastError: String?

    public init(
        port: UInt16,
        tokenProvider: @escaping @Sendable () -> String,
        readTimeout: TimeInterval = LocalHTTPServer.defaultReadTimeout,
        handler: @escaping Handler
    ) {
        self.port = port
        self.tokenProvider = tokenProvider
        self.readTimeout = readTimeout
        self.handler = handler
    }

    public var isRunning: Bool { listener?.state == .ready }

    public func start() throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only. Nothing on the network should reach this.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                           port: NWEndpoint.Port(rawValue: port)!)

        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.lastError = nil
                Log.write("http: listening on 127.0.0.1:\(self?.port ?? 0)")
            case .failed(let error), .waiting(let error):
                self?.lastError = error.localizedDescription
                Log.write("http: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Limits

    /// Ceilings on what one connection may cost us before it has proved it is
    /// the extension.
    ///
    /// Everything below runs *before* the token check, so a request that never
    /// ends is a request from anyone at all. Measured on the unbounded version:
    /// a tokenless POST was still growing past 60 MiB, one that declared 200
    /// MiB and delivered it took the app to 427 MB resident, and a connection
    /// that sent half a header block was still sitting there fifteen seconds
    /// later holding a slot.
    ///
    /// The numbers come from the one request that is genuinely big. The
    /// extension ships at most `MAX_CONTENT_CHARS` = 32000 characters of page
    /// text per preview; at UTF-8's worst four bytes a character, plus JSON
    /// escaping and the title and URL around it, that is a couple of hundred
    /// kilobytes. Bulk saves send an array, but deliberately carry no page text
    /// at all. So 4 MiB is roughly twenty times the largest real request, and
    /// still a number we can afford to be handed by a stranger.
    private static let maxHeaderBytes = 64 * 1024
    private static let maxBodyBytes = 4 * 1024 * 1024
    public static let defaultReadTimeout: TimeInterval = 10

    // MARK: - Connection

    /// One in-flight request. Exists so the idle timer has somewhere to live
    /// alongside the buffer it guards; both are touched only from `queue`,
    /// which every connection callback is delivered on.
    private final class Session {
        let conn: NWConnection
        var buffer = Data()
        private var answering = false
        private var idle: DispatchSourceTimer?

        init(conn: NWConnection, queue: DispatchQueue, timeout: TimeInterval) {
            self.conn = conn
            let timer = DispatchSource.makeTimerSource(queue: queue)
            idle = timer
            timer.setEventHandler { [weak self] in
                // `cancel()` only promises to stop *future* firings, so a timer
                // that came due in the same instant the last byte arrived can
                // still land here. Standing down once we're answering is what
                // stops it from closing a connection we are about to reply on.
                guard let self, !self.answering else { return }
                Log.write("http: dropped a connection that stopped mid-request")
                self.conn.cancel()
            }
            timer.schedule(deadline: .now() + timeout)
            timer.resume()
        }

        /// Bytes arrived, so the peer is alive; give it the full window again.
        func touch(timeout: TimeInterval) {
            idle?.schedule(deadline: .now() + timeout)
        }

        /// Called once the request is whole. From here on the connection is
        /// waiting on *us*, and killing it would only ever kill our own reply.
        ///
        /// Today the session is released the moment the read loop stops
        /// referencing it, so `deinit` below would disarm the timer anyway.
        /// Said out loud regardless, because "the object happened to be
        /// deallocated in time" is not a property to hang a live connection on,
        /// and it stops holding the day anything keeps a session alive across
        /// the handoff.
        func stopWaiting() {
            answering = true
            idle?.cancel()
            idle = nil
        }

        deinit { idle?.cancel() }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(Session(conn: conn, queue: queue, timeout: readTimeout))
    }

    private func receive(_ session: Session) {
        let conn = session.conn
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if let chunk { session.buffer.append(chunk) }
            session.touch(timeout: self.readTimeout)

            if error != nil {
                session.stopWaiting()
                conn.cancel()
                return
            }

            // Keep reading until headers are complete and the declared body has
            // arrived — extracted page text easily spans several TCP segments.
            switch Self.parse(session.buffer) {
            case .request(let request):
                session.stopWaiting()
                self.route(request) { response in
                    self.send(response, on: conn, origin: request.origin)
                }
            case .malformed:
                // No origin: a request we can't parse has no header we'd trust
                // to hand out a CORS grant with.
                session.stopWaiting()
                self.send(.error(400, "malformed request"), on: conn, origin: nil)
            case .headersTooLarge:
                session.stopWaiting()
                self.send(.error(431, "header too large"), on: conn, origin: nil)
            case .bodyTooLarge:
                // Answered rather than dropped, because the honest caller for
                // this is a page whose extracted text ran away with itself, and
                // a status is easier to act on than a closed socket.
                session.stopWaiting()
                self.send(.error(413, "body too large"), on: conn, origin: nil)
            case .incomplete:
                if isComplete { conn.cancel() } else { self.receive(session) }
            }
        }
    }

    private func route(_ request: Request, completion: @escaping @Sendable (Response) -> Void) {
        // Preflight: answered without the token, but only for the extension.
        if request.method == "OPTIONS" {
            return completion(Response(status: 204, json: Data()))
        }

        let expected = tokenProvider()
        guard let auth = request.bearerToken, !expected.isEmpty, auth == expected else {
            Log.write("http: rejected \(request.method) \(request.path) — bad or missing token")
            return completion(.error(401, "unauthorized"))
        }
        handler(request, completion)
    }

    private func send(_ response: Response, on conn: NWConnection, origin: String?) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(response.json.count)\r\n"
        // Only the extension may read replies; a normal web page gets no
        // Access-Control-Allow-Origin at all.
        if let origin, origin.hasPrefix("chrome-extension://") || origin.hasPrefix("moz-extension://") {
            head += "Access-Control-Allow-Origin: \(origin)\r\n"
            head += "Access-Control-Allow-Headers: Authorization, Content-Type\r\n"
            head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            head += "Access-Control-Max-Age: 86400\r\n"
        }
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(response.json)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Parsing

    /// More outcomes than "a request or not": bytes still on the way, and three
    /// separate ways of refusing to serve one.
    ///
    /// The refusals are a safety boundary, not tidiness. Parsing runs *before*
    /// the token check, so every line of it is reachable by any process that can
    /// open a loopback socket — one hand-written request, and whatever the
    /// parser does next it does on the whole app's behalf. A negative
    /// `Content-Length` was the proof: `body.count >= declared` is trivially
    /// true against a negative number, so the value flowed on into `prefix`,
    /// which traps, and the app died with exit 133 for anyone who asked.
    /// Clamping to zero would have stopped the crash and then answered as if
    /// nothing were wrong; a length that cannot exist is a request we have no
    /// business guessing the meaning of.
    ///
    /// The size cases are the same argument about memory rather than about
    /// crashes: a caller who has not authenticated should not be able to decide
    /// how much of this machine's RAM the reader takes.
    private enum Parsed {
        case request(Request)
        case incomplete
        case malformed
        case headersTooLarge
        case bodyTooLarge
    }

    private static func parse(_ data: Data) -> Parsed {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            // Not slowness — a header block with no end in sight is an open
            // tap, and the buffer holding it is the thing that grows.
            return data.count > maxHeaderBytes ? .headersTooLarge : .incomplete
        }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .incomplete }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .incomplete }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .incomplete }

        let method = String(requestLine[0])
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[String(name)] = value
        }

        let declared = Int(headers["content-length"] ?? "0") ?? 0
        guard declared >= 0 else { return .malformed }
        // Judged on the declaration, before a byte of it is read: waiting for
        // 200 MiB to arrive and *then* objecting is how the 427 MB resident
        // measurement happened.
        guard declared <= maxBodyBytes else { return .bodyTooLarge }
        let body = data[headerEnd.upperBound...]
        guard body.count >= declared else { return .incomplete }  // wait for the rest

        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<q])
            for pair in target[target.index(after: q)...].components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                guard kv.count == 2 else { continue }
                query[kv[0].removingPercentEncoding ?? kv[0]] =
                    kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]
            }
        }

        return .request(Request(
            method: method,
            path: path,
            query: query,
            body: Data(body.prefix(declared)),
            origin: headers["origin"],
            authorization: headers["authorization"]
        ))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 413: return "Content Too Large"
        case 431: return "Request Header Fields Too Large"
        default: return "Internal Server Error"
        }
    }
}

/// Generates the shared secret the extension must present. Shown in Settings
/// for one-time copy-paste into the extension's options page.
public enum SharedToken {
    public static func generate() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
