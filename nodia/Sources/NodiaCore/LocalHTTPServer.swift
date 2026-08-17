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

    public typealias Handler = @Sendable (Request) -> Response

    private let port: UInt16
    private let tokenProvider: @Sendable () -> String
    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.eddix.nodia.http")

    public private(set) var lastError: String?

    public init(port: UInt16, tokenProvider: @escaping @Sendable () -> String, handler: @escaping Handler) {
        self.port = port
        self.tokenProvider = tokenProvider
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

    // MARK: - Connection

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if error != nil {
                conn.cancel()
                return
            }

            // Keep reading until headers are complete and the declared body has
            // arrived — extracted page text easily spans several TCP segments.
            if let request = Self.parse(buffer) {
                let response = self.route(request)
                self.send(response, on: conn, origin: request.origin)
            } else if isComplete {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buffer)
            }
        }
    }

    private func route(_ request: Request) -> Response {
        // Preflight: answered without the token, but only for the extension.
        if request.method == "OPTIONS" { return Response(status: 204, json: Data()) }

        let expected = tokenProvider()
        guard let auth = request.bearerToken, !expected.isEmpty, auth == expected else {
            Log.write("http: rejected \(request.method) \(request.path) — bad or missing token")
            return .error(401, "unauthorized")
        }
        return handler(request)
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

    private static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

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
        let body = data[headerEnd.upperBound...]
        guard body.count >= declared else { return nil }  // wait for the rest

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

        return Request(
            method: method,
            path: path,
            query: query,
            body: Data(body.prefix(declared)),
            origin: headers["origin"],
            authorization: headers["authorization"]
        )
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
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
