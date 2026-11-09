import Cocoa
import SwiftUI
import Security
import Combine

// MARK: - Settings (UserDefaults; token in Keychain)

enum AlertKey {
    static let enabled = "alertsEnabled", memEnabled = "alertMemEnabled", cpuEnabled = "alertCpuEnabled"
    static let memBelowGB = "alertMemBelowGB", cpuAbovePct = "alertCpuAbovePct"
    static let sustainMin = "alertSustainMin", cooldownMin = "alertCooldownMin", recovery = "alertSendRecovery"
    static let mcpURL = "ezychatMcpURL", phone = "ezychatPhone"
}

struct AlertSettings {
    var enabled = false, memEnabled = true, cpuEnabled = true, sendRecovery = true
    var memBelowGB = 4.0, cpuAbovePct = 90.0
    var sustainMin = 5.0, cooldownMin = 30.0
    var mcpURL = "", phone = "", token = ""

    static func load() -> AlertSettings {
        let d = UserDefaults.standard
        func b(_ k: String, _ v: Bool) -> Bool { d.object(forKey: k) as? Bool ?? v }
        func n(_ k: String, _ v: Double) -> Double { d.object(forKey: k) as? Double ?? v }
        var s = AlertSettings()
        s.enabled = b(AlertKey.enabled, s.enabled); s.memEnabled = b(AlertKey.memEnabled, s.memEnabled)
        s.cpuEnabled = b(AlertKey.cpuEnabled, s.cpuEnabled); s.sendRecovery = b(AlertKey.recovery, s.sendRecovery)
        s.memBelowGB = n(AlertKey.memBelowGB, s.memBelowGB); s.cpuAbovePct = n(AlertKey.cpuAbovePct, s.cpuAbovePct)
        s.sustainMin = n(AlertKey.sustainMin, s.sustainMin); s.cooldownMin = n(AlertKey.cooldownMin, s.cooldownMin)
        s.mcpURL = d.string(forKey: AlertKey.mcpURL) ?? ""
        s.phone = d.string(forKey: AlertKey.phone) ?? ""
        s.token = Keychain.token
        return s
    }
}

enum Keychain {
    private static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "io.github.ossmalaysia.pulsebar.ezychat",
                                              kSecAttrAccount as String: "accessToken"]
    /// PULSEBAR_TOKEN overrides the Keychain (used by the self-tests).
    static var token: String {
        get {
            if let t = ProcessInfo.processInfo.environment["PULSEBAR_TOKEN"] { return t }
            var q = base
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
            return String(decoding: d, as: UTF8.self)
        }
        set {
            SecItemDelete(base as CFDictionary)
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { return }
            var q = base
            q[kSecValueData as String] = Data(v.utf8)
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}

// MARK: - EzyChat MCP client (stateless Streamable HTTP, one JSON-RPC call per request)

enum EzyChatError: LocalizedError {
    case notConfigured(String), http(Int, String), tool(String), badResponse(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured(let m): return m
        case .http(401, _): return "Token rejected (401). Check the access token."
        case .http(403, let b): return "Not allowed (403). Does the token have \u{201C}Can send WhatsApp messages\u{201D}? \(b)"
        case .http(let c, let b): return "HTTP \(c): \(b)"
        case .tool(let m): return m
        case .badResponse(let m): return "Unexpected reply: \(m)"
        }
    }
}

struct EzyChatClient {
    let url: URL
    let token: String

    init(settings s: AlertSettings) throws {
        guard let u = URL(string: s.mcpURL.trimmingCharacters(in: .whitespaces)), u.scheme?.hasPrefix("http") == true else {
            throw EzyChatError.notConfigured("Set the EzyChat MCP address (ends with /mcp).")
        }
        guard !s.token.isEmpty else { throw EzyChatError.notConfigured("Set the EzyChat access token (ezc_pat_…).") }
        url = u; token = s.token
    }

    func callTool(_ name: String, _ args: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": args],
        ])
        URLSession.shared.dataTask(with: req) { data, resp, err in
            func finish(_ r: Result<String, Error>) { DispatchQueue.main.async { completion(r) } }
            if let err { return finish(.failure(err)) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var body = String(decoding: data ?? Data(), as: UTF8.self)
            // Tolerate an SSE-framed reply: take the last "data:" line.
            if body.contains("data:") && !body.hasPrefix("{"),
               let last = body.split(separator: "\n").last(where: { $0.hasPrefix("data:") }) {
                body = String(last.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
            guard (200..<300).contains(status) else { return finish(.failure(EzyChatError.http(status, String(body.prefix(200))))) }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
                return finish(.failure(EzyChatError.badResponse(String(body.prefix(200)))))
            }
            if let e = obj["error"] as? [String: Any] {
                return finish(.failure(EzyChatError.tool(e["message"] as? String ?? "MCP error")))
            }
            let result = obj["result"] as? [String: Any] ?? [:]
            let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            finish(result["isError"] as? Bool == true ? .failure(EzyChatError.tool(text)) : .success(text))
        }.resume()
    }

    /// `phone` is used as the chat id: EzyChat resolves a phone number to its existing chat.
    func send(_ text: String, to phone: String, completion: @escaping (Result<String, Error>) -> Void) {
        let digits = phone.filter(\.isNumber)
        guard digits.count >= 7 else { return completion(.failure(EzyChatError.notConfigured("Set your WhatsApp number (with country code)."))) }
        let requestId = "pb-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        callTool("send_message", ["jid": digits, "text": text, "requestId": requestId], completion: completion)
    }
}

// MARK: - Alert log (tab-separated, next to history.csv)

struct AlertLogEntry: Identifiable {
    let date: Date, kind: String, event: String, detail: String
    var id: String { "\(date.timeIntervalSince1970)-\(kind)-\(event)" }
}

final class AlertLog {
    let url: URL
    init(dir: URL) { url = dir.appendingPathComponent("alerts.log") }

    func add(_ kind: String, _ event: String, _ detail: String) {
        let clean = detail.replacingOccurrences(of: "\n", with: " ⏎ ").replacingOccurrences(of: "\t", with: " ")
        let line = "\(Int(Date().timeIntervalSince1970))\t\(kind)\t\(event)\t\(clean)\n"
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
    }

    func recent(_ n: Int = 20) -> [AlertLogEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(n).reversed().compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard f.count == 4, let t = Double(f[0]) else { return nil }
            return AlertLogEntry(date: Date(timeIntervalSince1970: t), kind: String(f[1]), event: String(f[2]), detail: String(f[3]))
        }
    }
}

// MARK: - Alert engine: rolling-window average + cooldown + recovery

final class AlertEngine {
    enum Kind: String, CaseIterable { case memory = "Memory", cpu = "CPU" }
    private struct Sample { let t: Date; let availGB: Double; let cpuPct: Double? }

    let settings: () -> AlertSettings
    let log: AlertLog
    var hostName = Host.current().localizedName ?? "Mac"
    private var samples: [Sample] = []
    private var active: Set<Kind> = []
    private var delivered: Set<Kind> = []   // alerts that actually reached WhatsApp (only these get a recovery message)
    private var inFlight: Set<Kind> = []
    private var pendingRecovery: [Kind: String] = [:]   // recovered while its alert was still sending
    private var lastAlert: [Kind: Date] = [:]
    private var retryAt: [Kind: Date] = [:]

    init(settings: @escaping () -> AlertSettings, log: AlertLog) {
        self.settings = settings
        self.log = log
    }

    func evaluate(mem: MemoryStats, cpu: CPUStats?, now: Date = Date()) {
        let s = settings()
        guard s.enabled else { samples.removeAll(); active.removeAll(); return }
        // A long gap (sleep) means the window no longer describes "the last N minutes".
        if let last = samples.last, now.timeIntervalSince(last.t) > 60 { samples.removeAll() }
        samples.append(Sample(t: now, availGB: Double(mem.available) / 1_073_741_824, cpuPct: cpu.map { $0.total * 100 }))
        let window = s.sustainMin * 60
        samples.removeAll { now.timeIntervalSince($0.t) > window }
        guard let first = samples.first, now.timeIntervalSince(first.t) >= window - 5 else { return }  // window not full yet

        let recent = samples.filter { now.timeIntervalSince($0.t) <= 60 }
        func avg(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }

        if s.memEnabled, let w = avg(samples.map(\.availGB)), let r = avg(recent.map(\.availGB)) {
            // Recover only with margin (≥ threshold + 1 GB) so a value hovering at the line doesn't flap.
            check(.memory, breached: w < s.memBelowGB, recovered: r >= s.memBelowGB + 1, now: now, s: s,
                  alert: { self.memoryAlert(windowAvg: w, mem: mem, cpu: cpu, s: s) },
                  recovery: { "✅ \(self.hostName): memory back to normal: \(formatGB(mem.available)) available." })
        } else { active.remove(.memory) }

        if s.cpuEnabled, let w = avg(samples.compactMap(\.cpuPct)), let r = avg(recent.compactMap(\.cpuPct)) {
            // Recover only with margin (≤ threshold − 10 points).
            check(.cpu, breached: w > s.cpuAbovePct, recovered: r <= s.cpuAbovePct - 10, now: now, s: s,
                  alert: { self.cpuAlert(windowAvg: w, mem: mem, cpu: cpu, s: s) },
                  recovery: { String(format: "✅ %@: CPU back to normal: %.0f%% now (last minute avg %.0f%%).",
                                     self.hostName, (cpu?.total ?? 0) * 100, r) })
        } else { active.remove(.cpu) }
    }

    private func check(_ k: Kind, breached: Bool, recovered: Bool, now: Date, s: AlertSettings,
                       alert: () -> String, recovery: () -> String) {
        if !active.contains(k) && breached {
            if let r = retryAt[k], now < r { return }
            if let l = lastAlert[k], now.timeIntervalSince(l) < s.cooldownMin * 60 { return }
            active.insert(k)                 // optimistic: blocks duplicates while the request is in flight
            lastAlert[k] = now
            inFlight.insert(k)
            deliver(k, "alert", alert(), s) { [weak self] ok in
                guard let self else { return }
                self.inFlight.remove(k)
                let queued = self.pendingRecovery.removeValue(forKey: k)
                switch (ok, queued) {
                case (true, let text?):  // alert landed and things already recovered: send the follow-up now
                    self.deliver(k, "recovered", text, s) { _ in }
                case (true, nil):
                    self.delivered.insert(k)
                case (false, _?):        // alert failed and it's already over: nothing to follow up
                    self.log.add(k.rawValue, "recovered", "(no message sent)")
                case (false, nil):       // alert failed, still breached: retry in 5 min
                    self.active.remove(k); self.lastAlert[k] = nil
                    self.retryAt[k] = Date().addingTimeInterval(300)
                }
            }
        } else if active.contains(k) && recovered {
            active.remove(k)
            if inFlight.contains(k) {
                if s.sendRecovery { pendingRecovery[k] = recovery() }
                return
            }
            if s.sendRecovery && delivered.contains(k) { deliver(k, "recovered", recovery(), s) { _ in } }
            else { log.add(k.rawValue, "recovered", "(no message sent)") }
            delivered.remove(k)
        }
    }

    private func deliver(_ k: Kind, _ event: String, _ text: String, _ s: AlertSettings, done: @escaping (Bool) -> Void) {
        do {
            try EzyChatClient(settings: s).send(text, to: s.phone) { [weak self] r in
                switch r {
                case .success: self?.log.add(k.rawValue, event, text); done(true)
                case .failure(let e): self?.log.add(k.rawValue, "failed", "\(event): \(e.localizedDescription)"); done(false)
                }
            }
        } catch {
            log.add(k.rawValue, "failed", "\(event): \(error.localizedDescription)")
            done(false)
        }
    }

    private func memoryAlert(windowAvg w: Double, mem: MemoryStats, cpu: CPUStats?, s: AlertSettings) -> String {
        """
        ⚠️ Low memory on \(hostName)
        Available memory averaged \(String(format: "%.1f GB", w)) over the last \(Int(s.sustainMin)) min (alert below \(String(format: "%g", s.memBelowGB)) GB).
        Now: \(formatGB(mem.available)) available · \(formatGB(mem.used)) of \(formatGB(mem.total)) used\(cpu.map { String(format: " · CPU %.0f%%", $0.total * 100) } ?? "")
        Top memory: \(Self.topProcesses(byMemory: true))
        """
    }

    private func cpuAlert(windowAvg w: Double, mem: MemoryStats, cpu: CPUStats?, s: AlertSettings) -> String {
        """
        🔥 High CPU on \(hostName)
        CPU averaged \(String(format: "%.0f%%", w)) over the last \(Int(s.sustainMin)) min (alert above \(String(format: "%g", s.cpuAbovePct))%).
        Now: \(cpu.map { String(format: "CPU %.0f%%", $0.total * 100) } ?? "CPU —") · \(formatGB(mem.available)) memory available
        Top CPU: \(Self.topProcesses(byMemory: false))
        """
    }

    /// Top 3 processes from `ps` (rss in KB, %cpu is per-core so it can exceed 100).
    static func topProcesses(byMemory: Bool) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aco", "rss=,pcpu=,comm="]
        let pipe = Pipe(); p.standardOutput = pipe
        guard (try? p.run()) != nil else { return "n/a" }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let rows: [(rss: Double, cpu: Double, name: String)] = out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let r = Double(f[0]), let c = Double(f[1]) else { return nil }
            return (r, c, String(f[2]))
        }
        // Sum same-named processes (e.g. many "Google Chrome Helper" processes) so one app shows once.
        var byName: [String: (rss: Double, cpu: Double, n: Int)] = [:]
        for r in rows { let o = byName[r.name] ?? (0, 0, 0); byName[r.name] = (o.rss + r.rss, o.cpu + r.cpu, o.n + 1) }
        let top = byName.sorted { byMemory ? $0.value.rss > $1.value.rss : $0.value.cpu > $1.value.cpu }.prefix(3)
        return top.map { name, v in
            let label = v.n > 1 ? "\(name) ×\(v.n)" : name
            return byMemory ? String(format: "%@ %.1f GB", label, v.rss / 1_048_576) : String(format: "%@ %.0f%%", label, v.cpu)
        }.joined(separator: ", ")
    }
}

// MARK: - Settings window

struct AlertSettingsView: View {
    let log: AlertLog
    @AppStorage(AlertKey.enabled) private var enabled = false
    @AppStorage(AlertKey.memEnabled) private var memEnabled = true
    @AppStorage(AlertKey.cpuEnabled) private var cpuEnabled = true
    @AppStorage(AlertKey.memBelowGB) private var memBelowGB = 4.0
    @AppStorage(AlertKey.cpuAbovePct) private var cpuAbovePct = 90.0
    @AppStorage(AlertKey.sustainMin) private var sustainMin = 5.0
    @AppStorage(AlertKey.cooldownMin) private var cooldownMin = 30.0
    @AppStorage(AlertKey.recovery) private var sendRecovery = true
    @AppStorage(AlertKey.mcpURL) private var mcpURL = ""
    @AppStorage(AlertKey.phone) private var phone = ""
    @State private var token = ""
    @State private var testStatus = ""
    @State private var testing = false
    @State private var entries: [AlertLogEntry] = []
    private let tick = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Send WhatsApp alerts through EzyChat", isOn: $enabled)
            }
            Section("When to alert") {
                HStack {
                    Toggle("Available memory below", isOn: $memEnabled)
                    Spacer()
                    TextField("", value: $memBelowGB, format: .number).frame(width: 60).multilineTextAlignment(.trailing)
                    Text("GB")
                }
                HStack {
                    Toggle("CPU above", isOn: $cpuEnabled)
                    Spacer()
                    TextField("", value: $cpuAbovePct, format: .number).frame(width: 60).multilineTextAlignment(.trailing)
                    Text("%")
                }
                Stepper("…on average for \(Int(sustainMin)) min", value: $sustainMin, in: 1...60, step: 1)
                Stepper("Don't repeat the same alert within \(Int(cooldownMin)) min", value: $cooldownMin, in: 5...720, step: 5)
                Toggle("Also send a message when it's back to normal", isOn: $sendRecovery)
            }
            .disabled(!enabled)
            Section {
                TextField("MCP address", text: $mcpURL, prompt: Text("https://your-ezychat-address/mcp"))
                SecureField("Access token", text: $token, prompt: Text("ezc_pat_…"))
                    .onChange(of: token) { _, v in Keychain.token = v }
                TextField("Your WhatsApp number", text: $phone, prompt: Text("60123456789"))
                HStack {
                    Button(testing ? "Sending…" : "Send Test Message", action: sendTest).disabled(testing)
                    Text(testStatus).font(.caption).foregroundStyle(testStatus.hasPrefix("✓") ? .green : .red)
                        .lineLimit(3).textSelection(.enabled)
                }
            } header: {
                Text("EzyChat")
            } footer: {
                Text("Create a token in EzyChat → Admin → Settings → Integrations → For developer tools, with **Can send WhatsApp messages** on. Your number must already have a chat in the inbox (send any message to your EzyChat number once). The token is stored in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recent alerts") {
                if entries.isEmpty {
                    Text("No alerts yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { e in
                        HStack(alignment: .top) {
                            Text(e.date, format: .dateTime.day().month().hour().minute()).monospacedDigit().frame(width: 110, alignment: .leading)
                            Text("\(e.kind) \(e.event)").foregroundStyle(color(e.event)).frame(width: 130, alignment: .leading)
                            Text(e.detail.replacingOccurrences(of: " ⏎ ", with: " · ")).lineLimit(2).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 600)
        .onAppear { token = Keychain.token; entries = log.recent() }
        .onReceive(tick) { _ in entries = log.recent() }
    }

    private func color(_ event: String) -> Color {
        switch event { case "alert": .orange; case "recovered": .green; case "failed": .red; default: .secondary }
    }

    private func sendTest() {
        let s = AlertSettings.load()
        testing = true; testStatus = ""
        let host = Host.current().localizedName ?? "Mac"
        let text = "✅ PulseBar test from \(host). Alerts: " +
            [s.memEnabled ? String(format: "memory below %g GB", s.memBelowGB) : nil,
             s.cpuEnabled ? String(format: "CPU above %g%%", s.cpuAbovePct) : nil].compactMap { $0 }.joined(separator: ", ") +
            " for \(Int(s.sustainMin)) min."
        do {
            try EzyChatClient(settings: s).send(text, to: s.phone) { r in
                testing = false
                switch r {
                case .success: testStatus = "✓ Sent. Check WhatsApp."; log.add("Test", "sent", text)
                case .failure(let e): testStatus = e.localizedDescription; log.add("Test", "failed", e.localizedDescription)
                }
                entries = log.recent()
            }
        } catch {
            testing = false; testStatus = error.localizedDescription
        }
    }
}

final class AlertSettingsWindowController {
    private var window: NSWindow?
    let log: AlertLog
    init(log: AlertLog) { self.log = log }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "PulseBar Settings"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: AlertSettingsView(log: log))
            w.setContentSize(NSSize(width: 600, height: 680))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
