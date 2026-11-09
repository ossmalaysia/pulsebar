import Cocoa
import SwiftUI
import Charts
import Combine

// MARK: - Storage
// One CSV row per minute:
//   epoch,usedAvgBytes,availAvgBytes,usedPeakBytes,totalBytes,cpuAvgPct,cpuPeakPct
// Older rows have only the first 5 columns (memory only) and are still read.
// Lives in ~/Library/Application Support/PulseBar/history.csv (override with PULSEBAR_HISTORY for testing).

struct MemoryRecord {
    let date: Date
    let usedAvg: Double   // bytes
    let availAvg: Double
    let usedPeak: Double
    let total: Double
    let cpuAvg: Double?   // percent 0...100, nil for old rows / no sample
    let cpuPeak: Double?

    var csv: String {
        String(format: "%.0f,%.0f,%.0f,%.0f,%.0f,%.1f,%.1f",
               date.timeIntervalSince1970, usedAvg, availAvg, usedPeak, total, cpuAvg ?? -1, cpuPeak ?? -1)
    }
}

final class HistoryStore {
    static let retention: TimeInterval = 30 * 24 * 3600
    let url: URL

    init() {
        if let p = ProcessInfo.processInfo.environment["PULSEBAR_HISTORY"] {
            url = URL(fileURLWithPath: p)
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PulseBar", isDirectory: true)
            url = dir.appendingPathComponent("history.csv")
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    func append(_ r: MemoryRecord) {
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data((r.csv + "\n").utf8))
    }

    func load(since: Date) -> [MemoryRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let cutoff = since.timeIntervalSince1970
        var out: [MemoryRecord] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: ",").compactMap { Double($0) }
            guard f.count == 5 || f.count == 7, f[0] >= cutoff else { continue }
            let cpuA = f.count == 7 && f[5] >= 0 ? f[5] : nil
            let cpuP = f.count == 7 && f[6] >= 0 ? f[6] : nil
            out.append(MemoryRecord(date: Date(timeIntervalSince1970: f[0]), usedAvg: f[1], availAvg: f[2],
                                    usedPeak: f[3], total: f[4], cpuAvg: cpuA, cpuPeak: cpuP))
        }
        return out
    }

    /// Drop rows older than 30 days (rewrites the file atomically).
    func prune() {
        let body = load(since: Date().addingTimeInterval(-Self.retention)).map(\.csv).joined(separator: "\n")
        try? (body.isEmpty ? "" : body + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Recorder: folds 2-second samples into one row per minute

final class MemoryRecorder {
    let store: HistoryStore
    private var usedSum = 0.0, availSum = 0.0, usedPeak = 0.0, n = 0
    private var cpuSum = 0.0, cpuPeak = 0.0, cpuN = 0
    private var windowStart = Date()
    private var lastPrune = Date.distantPast

    init(store: HistoryStore) { self.store = store }

    func add(_ s: MemoryStats, cpu: CPUStats?) {
        let now = Date()
        // If the Mac slept, throw away the stale partial minute instead of smearing it.
        if now.timeIntervalSince(windowStart) > 120 { reset(at: now) }
        usedSum += Double(s.used); availSum += Double(s.available)
        usedPeak = max(usedPeak, Double(s.used)); n += 1
        if let c = cpu { cpuSum += c.total * 100; cpuPeak = max(cpuPeak, c.total * 100); cpuN += 1 }
        if now.timeIntervalSince(windowStart) >= 60 {
            store.append(MemoryRecord(date: now, usedAvg: usedSum / Double(n), availAvg: availSum / Double(n),
                                      usedPeak: usedPeak, total: Double(s.total),
                                      cpuAvg: cpuN > 0 ? cpuSum / Double(cpuN) : nil,
                                      cpuPeak: cpuN > 0 ? cpuPeak : nil))
            reset(at: now)
        }
        if now.timeIntervalSince(lastPrune) > 6 * 3600 { store.prune(); lastPrune = now }
    }

    private func reset(at d: Date) {
        usedSum = 0; availSum = 0; usedPeak = 0; n = 0
        cpuSum = 0; cpuPeak = 0; cpuN = 0
        windowStart = d
    }
}

// MARK: - History window (SwiftUI + Charts)

enum HistoryMetric: String, CaseIterable, Identifiable {
    case memory = "Memory", cpu = "CPU"
    var id: Self { self }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case day = "24 Hours", week = "7 Days", month = "30 Days"
    var id: Self { self }
    var span: TimeInterval { switch self { case .day: 86_400; case .week: 7 * 86_400; case .month: 30 * 86_400 } }
    var bucket: TimeInterval { switch self { case .day: 300; case .week: 1_800; case .month: 7_200 } }
}

struct ChartPoint: Identifiable {
    let date: Date
    let series: String
    let value: Double
    var id: String { "\(series)-\(date.timeIntervalSince1970)" }
}

private let GB = 1_073_741_824.0

struct HistoryView: View {
    let store: HistoryStore
    @AppStorage("historyRange") private var range: HistoryRange = .day      // remembers last tab
    @AppStorage("historyMetric") private var metric: HistoryMetric = .memory
    @State private var all: [MemoryRecord] = []
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Rows relevant to the selected metric (CPU view skips old memory-only rows).
    private var records: [MemoryRecord] { metric == .cpu ? all.filter { $0.cpuAvg != nil } : all }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("", selection: $metric) {
                    ForEach(HistoryMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                Spacer()
                Picker("", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }

            if records.isEmpty {
                Spacer()
                Text("No \(metric.rawValue) data yet for this range.\nA sample is recorded every minute while the app runs.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                if metric == .memory { memoryStats } else { cpuStats }
                chart
            }

            HStack {
                Text("Recorded every minute · kept for 30 days")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show Data File") { NSWorkspace.shared.activateFileViewerSelecting([store.url]) }
                    .controlSize(.small)
            }
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 420)
        .onAppear(perform: reload)
        .onChange(of: range) { _, _ in reload() }
        .onReceive(tick) { _ in reload() }
    }

    private var timeFormat: DateFormatter {
        let df = DateFormatter(); df.dateFormat = range == .day ? "HH:mm" : "d MMM HH:mm"; return df
    }

    private var memoryStats: some View {
        let avgUsed = records.map(\.usedAvg).reduce(0, +) / Double(records.count)
        let peak = records.max { $0.usedPeak < $1.usedPeak }!
        let low = records.min { $0.availAvg < $1.availAvg }!
        let gb = { (b: Double) in String(format: "%.1f GB", b / GB) }
        return HStack(spacing: 12) {
            stat("Average used", gb(avgUsed), nil, .orange)
            stat("Peak used", gb(peak.usedPeak), timeFormat.string(from: peak.date), .red)
            stat("Lowest available", gb(low.availAvg), timeFormat.string(from: low.date), .green)
            stat("Total RAM", gb(records.last!.total), nil, .secondary)
        }
    }

    private var cpuStats: some View {
        let avg = records.compactMap(\.cpuAvg).reduce(0, +) / Double(records.count)
        let peak = records.max { ($0.cpuPeak ?? 0) < ($1.cpuPeak ?? 0) }!
        let busyMin = records.filter { ($0.cpuAvg ?? 0) >= 80 }.count   // one row == one minute
        let busy = busyMin >= 60 ? String(format: "%dh %02dm", busyMin / 60, busyMin % 60) : "\(busyMin)m"
        return HStack(spacing: 12) {
            stat("Average CPU", String(format: "%.0f%%", avg), nil, .blue)
            stat("Peak CPU", String(format: "%.0f%%", peak.cpuPeak ?? 0), timeFormat.string(from: peak.date), .red)
            stat("Time above 80%", busy, nil, .orange)
            stat("CPU cores", "\(ProcessInfo.processInfo.activeProcessorCount)", nil, .secondary)
        }
    }

    private func stat(_ title: String, _ value: String, _ when: String?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .bold).monospacedDigit()).foregroundStyle(tint)
            Text(when ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    /// Main series is shaded; "Peak …" series is a thin dashed line.
    private var mainSeries: String { metric == .memory ? "Used" : "CPU" }
    private var peakSeries: String { metric == .memory ? "Peak used" : "Peak CPU" }

    private var chart: some View {
        let yMax = metric == .memory ? max((records.last?.total ?? 0) / GB, 1) : 100
        let colors: KeyValuePairs<String, Color> = metric == .memory
            ? ["Used": .orange, "Peak used": .red, "Available": .green]
            : ["CPU": .blue, "Peak CPU": .red]
        let unit = metric == .memory ? " GB" : "%"
        return Chart(points) { p in
            // Shade only the main series; unstacked so series don't add on top of each other.
            if p.series == mainSeries {
                AreaMark(x: .value("Time", p.date), y: .value("Value", p.value), stacking: .unstacked)
                    .foregroundStyle((metric == .memory ? Color.orange : Color.blue).opacity(0.18))
                    .interpolationMethod(.monotone)
            }
            LineMark(x: .value("Time", p.date), y: .value("Value", p.value), series: .value("Series", p.series))
                .foregroundStyle(by: .value("Series", p.series))
                .lineStyle(StrokeStyle(lineWidth: p.series == peakSeries ? 1 : 2,
                                       dash: p.series == peakSeries ? [3, 3] : []))
                .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(colors)
        .chartYScale(domain: 0...yMax)
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))\(unit)") } } } }
        .chartXScale(domain: Date().addingTimeInterval(-range.span)...Date())
        .chartLegend(position: .top, alignment: .trailing)
        .frame(minHeight: 240)
        .clipped()
    }

    /// Averages raw minute rows into fixed-size time buckets so each chart has ~300 points.
    private var points: [ChartPoint] {
        let b = range.bucket
        var groups: [Double: [MemoryRecord]] = [:]
        for r in records {
            groups[(r.date.timeIntervalSince1970 / b).rounded(.down) * b, default: []].append(r)
        }
        return groups.keys.sorted().flatMap { key -> [ChartPoint] in
            let g = groups[key]!, d = Date(timeIntervalSince1970: key + b / 2), c = Double(g.count)
            if metric == .cpu {
                return [
                    ChartPoint(date: d, series: "CPU", value: g.compactMap(\.cpuAvg).reduce(0, +) / c),
                    ChartPoint(date: d, series: "Peak CPU", value: g.compactMap(\.cpuPeak).max() ?? 0),
                ]
            }
            return [
                ChartPoint(date: d, series: "Used", value: g.map(\.usedAvg).reduce(0, +) / c / GB),
                ChartPoint(date: d, series: "Peak used", value: g.map(\.usedPeak).max()! / GB),
                ChartPoint(date: d, series: "Available", value: g.map(\.availAvg).reduce(0, +) / c / GB),
            ]
        }
    }

    private func reload() { all = store.load(since: Date().addingTimeInterval(-range.span)) }
}

final class HistoryWindowController {
    private var window: NSWindow?
    let store: HistoryStore
    init(store: HistoryStore) { self.store = store }

    func show(metric: HistoryMetric? = nil) {
        // The view reads this via @AppStorage, so setting it switches the tab even if the window is open.
        if let metric { UserDefaults.standard.set(metric.rawValue, forKey: "historyMetric") }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Usage History"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: HistoryView(store: store))
            w.setContentSize(NSSize(width: 760, height: 500))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)   // accessory apps must activate explicitly
        window?.makeKeyAndOrderFront(nil)
    }
}
