import Cocoa
import Darwin

// MARK: - Memory sampling (mirrors Activity Monitor's math)

struct MemoryStats {
    let total: UInt64
    let used: UInt64
    var available: UInt64 { total > used ? total - used : 0 }
    var availableFraction: Double { Double(available) / Double(total) }
}

func readMemory() -> MemoryStats? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }

    let page = UInt64(vm_kernel_page_size)
    let appMemory  = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
    let wired      = UInt64(stats.wire_count)
    let compressed = UInt64(stats.compressor_page_count)
    let used = (appMemory + wired + compressed) * page
    return MemoryStats(total: ProcessInfo.processInfo.physicalMemory, used: used)
}

// MARK: - CPU sampling (delta of cumulative tick counters, all cores combined)

struct CPUStats {
    let user: Double     // 0...1
    let system: Double   // 0...1 (includes nice)
    var total: Double { min(user + system, 1) }
}

final class CPUSampler {
    private var prev: [UInt32]?

    func sample() -> CPUStats? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let now = [t.0, t.1, t.2, t.3]          // user, system, idle, nice
        defer { prev = now }
        guard let p = prev else { return nil }   // need two readings for a delta
        let d = zip(now, p).map { Double($0 &- $1) }  // &- : counters may wrap
        let all = d.reduce(0, +)
        guard all > 0 else { return nil }
        return CPUStats(user: d[0] / all, system: (d[1] + d[3]) / all)
    }
}

func formatGB(_ bytes: UInt64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
}

let brightRed   = NSColor(srgbRed: 1.00, green: 0.38, blue: 0.36, alpha: 1)
let brightAmber = NSColor(srgbRed: 1.00, green: 0.72, blue: 0.25, alpha: 1)
let brightMint  = NSColor(srgbRed: 0.35, green: 0.95, blue: 0.55, alpha: 1)

/// Colour for the readout based on how much memory is still available.
/// Tweak these thresholds to taste — e.g. on a 64 GB machine 10% is still 6 GB.
func pressureColor(for s: MemoryStats) -> NSColor {
    switch s.availableFraction {
    case ..<0.10: return brightRed
    case ..<0.25: return brightAmber
    default:      return brightMint
    }
}

func cpuColor(for c: CPUStats) -> NSColor {
    switch c.total {
    case 0.80...: return brightRed
    case 0.50...: return brightAmber
    default:      return brightMint
    }
}

/// Simple bar drawn by hand so it stays high-contrast on the dark card.
final class UsageBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var fillColor: NSColor = .white { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        NSColor(white: 1, alpha: 0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        var f = bounds; f.size.width = max(bounds.height, bounds.width * CGFloat(min(max(fraction, 0), 1)))
        fillColor.setFill()
        NSBezierPath(roundedRect: f, xRadius: r, yRadius: r).fill()
    }
}

// MARK: - Floating widget

/// One dark card: title, big value, bar, detail line. Purely visual — mouse handling lives in WidgetView.
final class CardView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "—")
    private let detail = NSTextField(labelWithString: " ")
    private let bar = UsageBar()

    init(frame: NSRect, title t: String) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.90).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.masksToBounds = true

        title.stringValue = t
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = NSColor(white: 1, alpha: 0.65)
        value.font = .monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        detail.textColor = NSColor(white: 1, alpha: 0.85)

        let stack = NSStackView(views: [title, value, bar, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Small chart glyph top-right: hints that clicking opens history.
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: "History")
        icon.contentTintColor = NSColor(white: 1, alpha: 0.55)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(value v: String, color: NSColor, fraction: Double, detail d: String) {
        value.stringValue = v
        value.textColor = color
        bar.fraction = fraction
        bar.fillColor = color
        detail.stringValue = d
    }
}

/// Holds both cards; handles drag-to-move vs click-to-open-history.
final class WidgetView: NSView {
    static let cardSize = NSSize(width: 200, height: 96)
    static let gap: CGFloat = 8
    static var totalSize: NSSize { NSSize(width: cardSize.width, height: cardSize.height * 2 + gap) }

    let memoryCard: CardView
    let cpuCard: CardView
    var onClick: ((HistoryMetric) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    private var dragOffset: NSPoint?
    private var didDrag = false
    private var downMetric: HistoryMetric = .memory

    override init(frame: NSRect) {
        let s = Self.cardSize
        memoryCard = CardView(frame: NSRect(x: 0, y: s.height + Self.gap, width: s.width, height: s.height), title: "AVAILABLE MEMORY")
        cpuCard = CardView(frame: NSRect(x: 0, y: 0, width: s.width, height: s.height), title: "CPU UTILIZATION")
        super.init(frame: frame)
        addSubview(memoryCard)
        addSubview(cpuCard)
        memoryCard.toolTip = "Click for memory history · right-click for menu · drag to move"
        cpuCard.toolTip = "Click for CPU history · right-click for menu · drag to move"
    }
    required init?(coder: NSCoder) { fatalError() }

    // We handle dragging ourselves so a plain click (no movement) can open the history window.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(memoryCard.frame, cursor: .pointingHand)
        addCursorRect(cpuCard.frame, cursor: .pointingHand)
    }
    // Clicks in the gap between cards fall through to whatever is behind.
    override func hitTest(_ p: NSPoint) -> NSView? {
        let local = convert(p, from: superview)
        return memoryCard.frame.contains(local) || cpuCard.frame.contains(local) ? self : nil
    }

    override func mouseDown(with e: NSEvent) {
        guard let w = window else { return }
        let local = convert(e.locationInWindow, from: nil)
        downMetric = cpuCard.frame.contains(local) ? .cpu : .memory
        let p = w.convertPoint(toScreen: e.locationInWindow)
        dragOffset = NSPoint(x: p.x - w.frame.origin.x, y: p.y - w.frame.origin.y)
        didDrag = false
    }

    override func mouseDragged(with e: NSEvent) {
        guard let w = window, let off = dragOffset else { return }
        let p = w.convertPoint(toScreen: e.locationInWindow)
        let target = NSPoint(x: p.x - off.x, y: p.y - off.y)
        if !didDrag && hypot(target.x - w.frame.origin.x, target.y - w.frame.origin.y) < 3 { return }
        didDrag = true
        w.setFrameOrigin(target)
    }

    override func mouseUp(with e: NSEvent) {
        if !didDrag { onClick?(downMetric) }
        dragOffset = nil
    }

    override func rightMouseDown(with e: NSEvent) { onRightClick?(e) }

    func update(_ s: MemoryStats) {
        memoryCard.set(value: formatGB(s.available), color: pressureColor(for: s),
                       fraction: 1 - s.availableFraction,   // bar shows *used*
                       detail: "Used \(formatGB(s.used)) of \(formatGB(s.total))")
    }

    func update(_ c: CPUStats) {
        cpuCard.set(value: String(format: "%.0f%%", c.total * 100), color: cpuColor(for: c), fraction: c.total,
                    detail: String(format: "User %.0f%% · System %.0f%%", c.user * 100, c.system * 100))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var widget: WidgetView!
    private var toggleItem: NSMenuItem!
    private var timer: Timer?
    private var recordItem: NSMenuItem!
    private let cpu = CPUSampler()
    private let store = HistoryStore()
    private lazy var recorder = MemoryRecorder(store: store)
    private lazy var historyWindow = HistoryWindowController(store: store)
    private lazy var alertLog = AlertLog(dir: store.url.deletingLastPathComponent())
    private lazy var alerts = AlertEngine(settings: AlertSettings.load, log: alertLog)
    private lazy var alertWindow = AlertSettingsWindowController(log: alertLog)
    private let defaults = UserDefaults.standard
    private var recording: Bool {
        get { defaults.object(forKey: "recordHistory") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "recordHistory") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        setupPanel()
        setupStatusItem()
        store.prune()
        refresh()
        if CommandLine.arguments.contains("--show-history") { historyWindow.show() }
        if CommandLine.arguments.contains("--show-settings") { alertWindow.show() }
        if CommandLine.arguments.contains("--alerttest") { runAlertTest(); return }
        if CommandLine.arguments.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.runSelfTest() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func setupPanel() {
        let size = WidgetView.totalSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20)
        if let saved = defaults.string(forKey: "widgetOrigin") { origin = NSPointFromString(saved) }

        panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false   // WidgetView handles drag vs click
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        widget = WidgetView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = widget
        widget.onClick = { [weak self] metric in self?.historyWindow.show(metric: metric) }
        widget.onRightClick = { [weak self] e in
            guard let self, let menu = self.statusItem?.menu else { return }
            NSMenu.popUpContextMenu(menu, with: e, for: self.widget)
        }

        // The panel got taller (2 cards): keep a previously saved position fully on screen.
        if let vis = (NSScreen.screens.first { $0.visibleFrame.intersects(panel.frame) } ?? NSScreen.main)?.visibleFrame {
            var f = panel.frame
            f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - f.height)
            f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - f.width)
            panel.setFrameOrigin(f.origin)
        }

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.defaults.set(NSStringFromPoint(self.panel.frame.origin), forKey: "widgetOrigin")
        }
        if defaults.object(forKey: "widgetVisible") as? Bool ?? true { panel.orderFrontRegardless() }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Memory")
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "", action: #selector(toggleWidget), keyEquivalent: "w")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let hist = NSMenuItem(title: "Memory History…", action: #selector(showHistory), keyEquivalent: "h")
        hist.target = self
        menu.addItem(hist)
        let cpuHist = NSMenuItem(title: "CPU History…", action: #selector(showCPUHistory), keyEquivalent: "j")
        cpuHist.target = self
        menu.addItem(cpuHist)
        let al = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        al.target = self
        menu.addItem(al)
        recordItem = NSMenuItem(title: "Record History", action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        recordItem.state = recording ? .on : .off
        menu.addItem(recordItem)
        menu.addItem(.separator())
        let am = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
        am.target = self
        menu.addItem(am)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PulseBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateToggleTitle()
    }

    private func refresh() {
        guard let s = readMemory() else { return }
        let c = cpu.sample()
        widget.update(s)
        if let c { widget.update(c) }
        if recording { recorder.add(s, cpu: c) }
        alerts.evaluate(mem: s, cpu: c)

        var text = " " + formatGB(s.available)
        if let c { text += String(format: " · %.0f%%", c.total * 100) }
        let alert = s.availableFraction < 0.10 || (c?.total ?? 0) >= 0.90
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                         .foregroundColor: alert ? NSColor.systemRed : NSColor.labelColor])
    }

    @objc private func toggleWidget() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        defaults.set(panel.isVisible, forKey: "widgetVisible")
        updateToggleTitle()
    }

    private func updateToggleTitle() {
        toggleItem.title = panel.isVisible ? "Hide Desktop Widget" : "Show Desktop Widget"
    }

    @objc private func showHistory() { historyWindow.show(metric: .memory) }
    @objc private func showCPUHistory() { historyWindow.show(metric: .cpu) }
    @objc private func showSettings() { alertWindow.show() }

    /// Drives the alert engine with simulated time (2 s steps) against PULSEBAR_MCP_URL and prints the log.
    private func runAlertTest() {
        timer?.invalidate()
        var cfg = AlertSettings()
        cfg.enabled = true; cfg.memBelowGB = 4; cfg.cpuAbovePct = 90; cfg.sustainMin = 5; cfg.cooldownMin = 30
        cfg.mcpURL = ProcessInfo.processInfo.environment["PULSEBAR_MCP_URL"] ?? ""
        cfg.phone = "+60 12-345 6789"; cfg.token = Keychain.token
        let engine = AlertEngine(settings: { cfg }, log: alertLog)
        engine.hostName = "TestMac"
        let G: UInt64 = 1_073_741_824
        var t = Date()
        func run(minutes: Double, availGB: Double, cpuPct: Double) {
            for _ in 0..<Int(minutes * 30) {
                t = t.addingTimeInterval(2)
                let used = 64 * G - UInt64(availGB * Double(G))
                engine.evaluate(mem: MemoryStats(total: 64 * G, used: used),
                                cpu: CPUStats(user: cpuPct / 100 * 0.7, system: cpuPct / 100 * 0.3), now: t)
            }
        }
        run(minutes: 3,  availGB: 20, cpuPct: 95)   // high CPU but < 5 min        -> nothing
        run(minutes: 3,  availGB: 20, cpuPct: 95)   // now 6 min sustained          -> CPU alert
        run(minutes: 10, availGB: 20, cpuPct: 95)   // still high                   -> no repeat
        run(minutes: 2,  availGB: 20, cpuPct: 20)   // drops                        -> CPU recovered
        run(minutes: 7,  availGB: 20, cpuPct: 96)   // high again within cooldown   -> suppressed
        run(minutes: 2,  availGB: 20, cpuPct: 10)
        run(minutes: 1,  availGB: 2,  cpuPct: 10)   // memory spike < 5 min         -> nothing yet
        run(minutes: 6,  availGB: 2,  cpuPct: 10)   // sustained low memory         -> Memory alert
        run(minutes: 2,  availGB: 18, cpuPct: 10)   //                               -> Memory recovered
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            _ = engine   // keep the engine alive until in-flight sends have logged
            for e in self.alertLog.recent(50).reversed() { print("LOG \(e.kind) \(e.event): \(e.detail.prefix(110))") }
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    /// Feeds synthetic mouse events through the panel to verify drag-vs-click handling.
    private func runSelfTest() {
        // p is in *screen* coords; convert against the panel's current frame like a real event would be.
        func send(_ t: NSEvent.EventType, _ screen: NSPoint) {
            let p = NSPoint(x: screen.x - panel.frame.origin.x, y: screen.y - panel.frame.origin.y)
            let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            panel.sendEvent(e)
        }
        func historyVisible() -> Bool { NSApp.windows.contains { $0.title == "Usage History" && $0.isVisible } }
        func metric() -> String { defaults.string(forKey: "historyMetric") ?? "?" }
        func pass(_ ok: Bool) -> String { ok ? "PASS" : "FAIL" }

        let start = panel.frame.origin
        let memMid = NSPoint(x: start.x + 100, y: start.y + widget.memoryCard.frame.midY)
        let cpuMid = NSPoint(x: start.x + 100, y: start.y + widget.cpuCard.frame.midY)
        let gap = NSPoint(x: start.x + 100, y: start.y + WidgetView.cardSize.height + WidgetView.gap / 2)

        // 1) drag the CPU card 60pt left: whole panel moves, history does NOT open
        send(.leftMouseDown, cpuMid)
        for i in 1...6 { send(.leftMouseDragged, NSPoint(x: cpuMid.x - CGFloat(i * 10), y: cpuMid.y)) }
        send(.leftMouseUp, NSPoint(x: cpuMid.x - 60, y: cpuMid.y))
        let moved = panel.frame.origin.x - start.x
        print("DRAG      : moved \(moved)pt, history opened: \(historyVisible()) -> \(pass(abs(moved + 60) < 1 && !historyVisible()))")
        panel.setFrameOrigin(start)

        // 2) gap between cards is click-through
        let hit = widget.hitTest(NSPoint(x: gap.x - start.x, y: gap.y - start.y))
        print("GAP       : click-through \(hit == nil) -> \(pass(hit == nil))")

        // 3) click CPU card -> history opens on CPU
        send(.leftMouseDown, cpuMid); send(.leftMouseUp, cpuMid)
        print("CLICK CPU : open \(historyVisible()), metric \(metric()) -> \(pass(historyVisible() && metric() == "CPU"))")

        // 4) click memory card -> switches to Memory
        send(.leftMouseDown, memMid); send(.leftMouseDragged, NSPoint(x: memMid.x + 1, y: memMid.y)); send(.leftMouseUp, memMid)
        print("CLICK MEM : open \(historyVisible()), metric \(metric()) -> \(pass(historyVisible() && metric() == "Memory"))")
        fflush(stdout)
        if !CommandLine.arguments.contains("--keep") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
    }

    @objc private func toggleRecording() {
        recording.toggle()
        recordItem.state = recording ? .on : .off
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
