import Cocoa
import Network
import CryptoKit

// MARK: - EzyChat sign-in (MCP authorization: OAuth 2.1 + PKCE S256 + dynamic client registration)
//
// 1. Discover: <origin>/.well-known/oauth-protected-resource/mcp  ->  authorization server metadata
// 2. Listen on http://127.0.0.1:<random port>/callback (RFC 8252 loopback redirect)
// 3. Register PulseBar as a public client (token_endpoint_auth_method "none")
// 4. Open the browser on the authorize page; the admin signs in and clicks Approve
// 5. Swap the one-time code (+ PKCE verifier) for an access token, kept in the Keychain
//
// EzyChat issues no refresh token: the app token lives until it is removed in
// EzyChat -> Settings -> Integrations -> Connected apps.

enum OAuthFlowError: LocalizedError {
    case badAddress, mcpOff(String), discovery(String), registration(String), denied(String)
    case stateMismatch, timeout, cancelled, token(String)

    var errorDescription: String? {
        switch self {
        case .badAddress: return "Enter your EzyChat address, e.g. https://your-ezychat-address or http://localhost:7440."
        case .mcpOff(let host): return "\(host) has AI assistant access turned off. In EzyChat → Admin → Settings → Integrations, turn on “Let AI assistants read this inbox”, then connect again."
        case .discovery(let m): return "Couldn't find EzyChat's sign-in: \(m)"
        case .registration(let m): return "EzyChat refused to register PulseBar: \(m)"
        case .denied(let m): return m == "access_denied" ? "The connection was denied in EzyChat." : "EzyChat sign-in failed: \(m)"
        case .stateMismatch: return "The sign-in reply didn't match this request. Please try again."
        case .timeout: return "Timed out waiting for approval in the browser."
        case .cancelled: return "Cancelled."
        case .token(let m): return "Couldn't get access from EzyChat: \(m)"
        }
    }
}

struct EzyChatConnection {
    let mcpURL: String
    let clientId: String
    let token: String
}

/// Turns what the user typed into the MCP endpoint URL: adds https:// (http:// for localhost) and /mcp.
func normalizeEzyChatAddress(_ raw: String) -> URL? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    if !s.contains("://") {
        let local = s.hasPrefix("localhost") || s.hasPrefix("127.0.0.1") || s.hasPrefix("[::1]")
        s = (local ? "http://" : "https://") + s
    }
    guard var c = URLComponents(string: s), c.host?.isEmpty == false,
          c.scheme == "https" || c.scheme == "http" else { return nil }
    var path = c.path
    while path.hasSuffix("/") { path.removeLast() }
    if !path.hasSuffix("/mcp") { path += "/mcp" }
    c.path = path; c.query = nil; c.fragment = nil
    return c.url
}

// MARK: Loopback redirect receiver

/// Confined to the main queue: the listener, its connections and all timers run there.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    /// Starts listening and returns the port the system picked.
    private var starter: CheckedContinuation<UInt16, Error>?

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            starter = c
            // Runs on the main queue (listener.start below), like everything else in this class.
            listener.stateUpdateHandler = { [weak self] st in
                guard let self, let c = self.starter else { return }
                switch st {
                case .ready: self.starter = nil; c.resume(returning: self.listener.port?.rawValue ?? 0)
                case .failed(let e): self.starter = nil; c.resume(throwing: e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: .main)
        }
    }

    /// Waits for GET /callback?... and returns its query parameters.
    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { c in
            waiter = c
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(OAuthFlowError.timeout)) }
        }
    }

    func cancel() { finish(.failure(OAuthFlowError.cancelled)) }

    private func finish(_ r: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = r
        waiter?.resume(with: r); waiter = nil
        // Give the browser a moment to receive the page before closing the socket.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [listener] in listener.cancel() }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let target = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"
            let comps = URLComponents(string: "http://127.0.0.1" + target)
            guard comps?.path == "/callback" else { return Self.respond(conn, 404, "Not found") }
            var q: [String: String] = [:]
            for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }
            let ok = q["code"] != nil && q["error"] == nil
            Self.respond(conn, 200, ok
                ? "✅ PulseBar is connected to EzyChat.<br>You can close this tab."
                : "⚠️ PulseBar was not connected: \(Self.escape(q["error_description"] ?? q["error"] ?? "unknown error")).<br>You can close this tab.")
            self?.finish(.success(q))
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func respond(_ conn: NWConnection, _ status: Int, _ message: String) {
        let html = """
        <!doctype html><meta charset="utf-8"><title>PulseBar</title>
        <body style="font:16px -apple-system,sans-serif;display:grid;place-items:center;height:90vh;text-align:center">
        <p>\(message)</p></body>
        """
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\nContent-Type: text/html; charset=utf-8\r\n" +
                   "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: Flow

@MainActor
final class EzyChatOAuth {
    /// How the authorize page is opened. Tests swap this for a headless fetch.
    var openBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var receiver: LoopbackReceiver?

    func cancel() { receiver?.cancel() }

    func connect(address: String, timeout: TimeInterval = 300) async throws -> EzyChatConnection {
        guard let mcp = normalizeEzyChatAddress(address), let origin = Self.origin(of: mcp) else { throw OAuthFlowError.badAddress }

        // 1. Discovery (RFC 9728 → RFC 8414)
        let prmURL = URL(string: origin + "/.well-known/oauth-protected-resource" + mcp.path)!
        let prm: [String: Any]
        do { prm = try await Self.getJSON(prmURL) } catch OAuthFlowError.discovery(let m) where m.hasPrefix("HTTP 404") {
            throw OAuthFlowError.mcpOff(mcp.host ?? origin)   // EzyChat hides /mcp and its metadata while access is off
        }
        let resource = prm["resource"] as? String ?? mcp.absoluteString
        let issuer = (prm["authorization_servers"] as? [String])?.first ?? origin
        let asm = try await Self.getJSON(URL(string: issuer + "/.well-known/oauth-authorization-server")!)
        guard let authorizeEP = (asm["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let tokenEP = (asm["token_endpoint"] as? String).flatMap(URL.init(string:)),
              let registerEP = (asm["registration_endpoint"] as? String).flatMap(URL.init(string:)) else {
            throw OAuthFlowError.discovery("authorization server metadata is incomplete")
        }
        if let methods = asm["code_challenge_methods_supported"] as? [String], !methods.contains("S256") {
            throw OAuthFlowError.discovery("server doesn't support PKCE S256")
        }

        // 2. Loopback redirect
        let rx = try LoopbackReceiver()
        receiver = rx
        defer { rx.cancel(); receiver = nil }
        let port = try await rx.start()
        let redirect = "http://127.0.0.1:\(port)/callback"

        // 3. Dynamic client registration (public client)
        let reg = try await Self.postJSON(registerEP, [
            "client_name": "PulseBar",
            "redirect_uris": [redirect],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code"],
            "response_types": ["code"],
        ], fail: OAuthFlowError.registration)
        guard let clientId = reg["client_id"] as? String else { throw OAuthFlowError.registration("no client_id returned") }

        // 4. Authorize in the browser (PKCE S256)
        let verifier = Self.randomURLSafe(32)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(16)
        var auth = URLComponents(url: authorizeEP, resolvingAgainstBaseURL: false)!
        auth.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirect), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
            .init(name: "resource", value: resource),
        ]
        openBrowser(auth.url!)
        let reply = try await rx.waitForCallback(timeout: timeout)
        if let err = reply["error"] { throw OAuthFlowError.denied(reply["error_description"].map { "\(err): \($0)" } ?? err) }
        guard reply["state"] == state else { throw OAuthFlowError.stateMismatch }
        guard let code = reply["code"] else { throw OAuthFlowError.denied("no code returned") }

        // 5. Code -> token
        var req = URLRequest(url: tokenEP, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(Self.formEncode([
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
            "client_id": clientId, "code_verifier": verifier, "resource": resource,
        ]).utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let token = obj["access_token"] as? String else {
            throw OAuthFlowError.token((obj["error_description"] ?? obj["error"]).map { "\($0)" } ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return EzyChatConnection(mcpURL: resource, clientId: clientId, token: token)
    }

    // MARK: helpers

    static func origin(of u: URL) -> String? {
        guard let scheme = u.scheme, let host = u.host else { return nil }
        let h = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(h)" + (u.port.map { ":\($0)" } ?? "")
    }

    private static func getJSON(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw OAuthFlowError.discovery(error.localizedDescription) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OAuthFlowError.discovery("HTTP \(status) from \(url.path)")
        }
        return obj
    }

    private static func postJSON(_ url: URL, _ body: [String: Any], fail: (String) -> OAuthFlowError) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw fail((obj["error_description"] ?? obj["error"]).map { "\($0)" } ?? "HTTP \(status)")
        }
        return obj
    }

    private static func formEncode(_ f: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return f.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return base64url(Data(b))
    }
}
