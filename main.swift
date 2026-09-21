import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import Charts
import Combine

// MARK: - Model

struct Session: Identifiable {
    let id: String
    var title: String
    var project: String
    var cwd: String
    var start: Date
    var lastActive: Date
    var prompts: Int
    var files: Set<String>
    var toolCalls: Int
    var lastPrompt: String
    var promptTimes: [Date] = []
}

// MARK: - Loader

enum Loader {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain = ISO8601DateFormatter()
    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    static func count(_ d: Data.SubSequence, _ needle: StaticString) -> Int {
        let nlen = needle.utf8CodeUnitCount
        let np = UnsafeRawPointer(needle.utf8Start)
        return d.withUnsafeBytes { (h: UnsafeRawBufferPointer) -> Int in
            guard let base = h.baseAddress else { return 0 }
            var p = base
            var left = h.count
            var n = 0
            while left >= nlen, let f = memmem(p, left, np, nlen) {
                n += 1
                let adv = base.distance(to: UnsafeRawPointer(f)) - base.distance(to: p) + nlen
                p = p.advanced(by: adv)
                left -= adv
            }
            return n
        }
    }

    static func has(_ d: Data.SubSequence, _ needle: StaticString) -> Bool {
        let nlen = needle.utf8CodeUnitCount
        let np = UnsafeRawPointer(needle.utf8Start)
        return d.withUnsafeBytes { (h: UnsafeRawBufferPointer) -> Bool in
            guard let base = h.baseAddress, h.count >= nlen else { return false }
            return memmem(base, h.count, np, nlen) != nil
        }
    }

    static let lock = NSLock()
    static var cache: [String: (Date, Session?)] = [:]

    static func cachedParse(_ url: URL, modified: Date) -> Session? {
        lock.lock(); let hit = cache[url.path]; lock.unlock()
        if let hit, hit.0 == modified { return hit.1 }
        let r = parse(url, modified: modified)
        lock.lock(); cache[url.path] = (modified, r); lock.unlock()
        return r
    }

    static func loadAll(days: Int = 30, limit: Int = 80) -> [Session] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var files: [(URL, Date)] = []
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for d in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for u in items where u.pathExtension == "jsonl" {
                let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if m >= cutoff { files.append((u, m)) }
            }
        }
        files.sort { $0.1 > $1.1 }
        return files.prefix(limit).compactMap { cachedParse($0.0, modified: $0.1) }
    }

    static func parse(_ url: URL, modified: Date) -> Session? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var s = Session(id: url.deletingPathExtension().lastPathComponent, title: "", project: "", cwd: "",
                        start: modified, lastActive: modified, prompts: 0, files: [], toolCalls: 0, lastPrompt: "")
        var firstPrompt = ""
        var gotStart = false

        for lineData in data.split(separator: UInt8(ascii: "\n")) {
            // Cheap byte-level pre-filter so we only JSON-parse lines we care about.
            let isTitle = has(lineData, "\"ai-title\"")
            let isLast = has(lineData, "\"last-prompt\"")
            let isUser = has(lineData, "\"type\":\"user\"") && !has(lineData, "\"type\":\"tool_result\"")
            let toolUses = count(lineData, "\"type\":\"tool_use\"")
            let isEdit = toolUses > 0 && (has(lineData, "\"name\":\"Edit\"") || has(lineData, "\"name\":\"Write\"")
                || has(lineData, "\"name\":\"MultiEdit\"") || has(lineData, "\"name\":\"NotebookEdit\""))
            if toolUses > 0 && !isEdit && !isTitle && !isLast && !isUser { s.toolCalls += toolUses; continue }
            guard isTitle || isLast || isUser || isEdit else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else { continue }
            let type = obj["type"] as? String

            if s.cwd.isEmpty, let c = obj["cwd"] as? String { s.cwd = c }
            if type == "ai-title", let t = obj["aiTitle"] as? String { s.title = t; continue }
            if type == "last-prompt", let t = obj["lastPrompt"] as? String { s.lastPrompt = t; continue }
            if obj["isSidechain"] as? Bool == true { continue }

            if type == "user" {
                if obj["isMeta"] as? Bool == true { continue }
                guard let msg = obj["message"] as? [String: Any] else { continue }
                var text: String?
                if let c = msg["content"] as? String { text = c }
                else if let arr = msg["content"] as? [[String: Any]] {
                    text = arr.first(where: { $0["type"] as? String == "text" })?["text"] as? String
                }
                guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
                      !t.hasPrefix("<") else { continue }
                s.prompts += 1
                if firstPrompt.isEmpty { firstPrompt = t }
                if let d = date(obj["timestamp"] as? String) {
                    s.promptTimes.append(d)
                    if !gotStart { s.start = d; gotStart = true }
                }
            } else if type == "assistant" {
                guard let msg = obj["message"] as? [String: Any],
                      let arr = msg["content"] as? [[String: Any]] else { continue }
                for b in arr where b["type"] as? String == "tool_use" {
                    s.toolCalls += 1
                    if let name = b["name"] as? String, editTools.contains(name),
                       let input = b["input"] as? [String: Any],
                       let p = (input["file_path"] ?? input["notebook_path"]) as? String {
                        s.files.insert(p)
                    }
                }
            }
        }
        guard s.prompts > 0 else { return nil }
        if s.lastPrompt.isEmpty { s.lastPrompt = firstPrompt }
        if s.title.isEmpty { s.title = String(firstPrompt.prefix(70)) }
        s.project = s.cwd.isEmpty ? "Unknown" : (s.cwd as NSString).lastPathComponent
        return s
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var loading = false
    @Published var range: Range = .today
    @Published var widgetOn: Bool = UserDefaults.standard.object(forKey: "widgetOn") as? Bool ?? true
    @Published var widgetSize: WidgetSize =
        WidgetSize(rawValue: UserDefaults.standard.string(forKey: "widgetSize") ?? "") ?? .medium
    var onOpen: () -> Void = {}

    enum Range: String, CaseIterable, Identifiable {
        case today = "Today", week = "7 Days", all = "30 Days"
        var id: String { rawValue }
    }

    var visible: [Session] {
        let cal = Calendar.current
        switch range {
        case .today: return sessions.filter { cal.isDateInToday($0.lastActive) }
        case .week: return sessions.filter { $0.lastActive > Date().addingTimeInterval(-7 * 86400) }
        case .all: return sessions
        }
    }

    func refresh() {
        loading = true
        Task.detached(priority: .userInitiated) {
            let r = Loader.loadAll()
            await MainActor.run {
                self.sessions = r
                self.loading = false
            }
        }
    }
}

// MARK: - UI

extension Color {
    static func project(_ name: String) -> Color {
        var h: UInt64 = 5381
        for u in name.unicodeScalars { h = (h &* 33) &+ UInt64(u.value) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.95)
    }
}

func relative(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: d, relativeTo: Date())
}

func dayLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"
    return f.string(from: d)
}

struct Tile: View {
    let value: Int, label: String, icon: String, tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            Text("\(value)").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct Chip: View {
    let icon: String, text: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

struct Row: View {
    let s: Session
    @State private var hover = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(Color.project(s.project)).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(s.project).foregroundStyle(Color.project(s.project))
                    Text("·").foregroundStyle(.tertiary)
                    Text(relative(s.lastActive)).foregroundStyle(.secondary)
                }.font(.system(size: 11))
                if !s.lastPrompt.isEmpty {
                    Text(s.lastPrompt.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(hover ? 3 : 1)
                }
                HStack(spacing: 5) {
                    Chip(icon: "text.bubble", text: "\(s.prompts)")
                    if !s.files.isEmpty { Chip(icon: "doc.badge.gearshape", text: "\(s.files.count) files") }
                    Chip(icon: "wrench.and.screwdriver", text: "\(s.toolCalls)")
                }.padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(hover ? AnyShapeStyle(.quaternary.opacity(0.8)) : AnyShapeStyle(.quaternary.opacity(0.35))))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .onTapGesture {
            if !s.cwd.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: s.cwd)) }
        }
        .help("Open \(s.cwd) in Finder")
    }
}


// MARK: - Analytics

func dailyPrompts(_ sessions: [Session], days: Int) -> [(day: Date, count: Int)] {
    let cal = Calendar.current
    var counts: [Date: Int] = [:]
    for t in sessions.flatMap({ $0.promptTimes }) { counts[cal.startOfDay(for: t), default: 0] += 1 }
    let today = cal.startOfDay(for: Date())
    return (0..<days).reversed().map { i in
        let d = cal.date(byAdding: .day, value: -i, to: today)!
        return (d, counts[d] ?? 0)
    }
}

func hourlyPrompts(_ sessions: [Session]) -> [(hour: Int, count: Int)] {
    var counts = [Int](repeating: 0, count: 24)
    for t in sessions.flatMap({ $0.promptTimes }) { counts[Calendar.current.component(.hour, from: t)] += 1 }
    return counts.enumerated().map { ($0.offset, $0.element) }
}

struct ProjectStat: Identifiable {
    let name: String
    var prompts = 0, sessions = 0
    var files = Set<String>()
    var id: String { name }
}

func projectStats(_ sessions: [Session]) -> [ProjectStat] {
    var d: [String: ProjectStat] = [:]
    for s in sessions {
        var p = d[s.project] ?? ProjectStat(name: s.project)
        p.prompts += s.prompts; p.sessions += 1; p.files.formUnion(s.files)
        d[s.project] = p
    }
    return d.values.sorted { $0.prompts > $1.prompts }
}

func hourLabel(_ h: Int) -> String {
    let h12 = h % 12 == 0 ? 12 : h % 12
    return "\(h12) \(h < 12 ? "AM" : "PM")"
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct Insight: View {
    let label: String, value: String, sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1)
            Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct AnalyzeView: View {
    let sessions: [Session]

    var body: some View {
        let daily = dailyPrompts(sessions, days: 14)
        let hours = hourlyPrompts(sessions)
        let projects = Array(projectStats(sessions).prefix(6))
        let maxPrompts = max(projects.first?.prompts ?? 1, 1)
        let totalPrompts = sessions.reduce(0) { $0 + $1.prompts }
        let busiest = dailyPrompts(sessions, days: 30).max { $0.count < $1.count }
        let peak = hours.max { $0.count < $1.count }
        let biggest = sessions.max { $0.prompts < $1.prompts }
        let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f }()

        ScrollView {
            VStack(spacing: 10) {
                Card(title: "Prompts per day · 14 days") {
                    Chart(daily, id: \.day) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Prompts", d.count))
                            .foregroundStyle(Calendar.current.isDateInToday(d.day) ? Color.orange : Color.orange.opacity(0.4))
                            .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                            AxisValueLabel(format: .dateTime.day(), centered: true)
                        }
                    }
                    .frame(height: 100)
                }
                Card(title: "When you work with Claude") {
                    Chart(hours, id: \.hour) { h in
                        BarMark(x: .value("Hour", h.hour), y: .value("Prompts", h.count))
                            .foregroundStyle(h.hour == peak?.hour ? Color.blue : Color.blue.opacity(0.4))
                            .cornerRadius(2)
                    }
                    .chartXScale(domain: -1...24)
                    .chartXAxis {
                        AxisMarks(values: [0, 6, 12, 18]) { v in
                            AxisValueLabel { if let h = v.as(Int.self) { Text(hourLabel(h)) } }
                        }
                    }
                    .frame(height: 80)
                }
                Card(title: "Projects · 30 days") {
                    ForEach(projects) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Circle().fill(Color.project(p.name)).frame(width: 7, height: 7)
                                Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text("\(p.prompts) prompts · \(p.files.count) files")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            GeometryReader { g in
                                Capsule().fill(Color.project(p.name).opacity(0.85))
                                    .frame(width: max(4, g.size.width * CGFloat(p.prompts) / CGFloat(maxPrompts)))
                            }.frame(height: 5)
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                    Insight(label: "Busiest day", value: busiest.map { df.string(from: $0.day) } ?? "–",
                            sub: "\(busiest?.count ?? 0) prompts")
                    Insight(label: "Peak hour", value: (peak?.count ?? 0) > 0 ? hourLabel(peak!.hour) : "–",
                            sub: "\(peak?.count ?? 0) prompts")
                    Insight(label: "Avg per session", value: sessions.isEmpty ? "–" : "\(totalPrompts / sessions.count)",
                            sub: "\(sessions.count) sessions")
                    Insight(label: "Biggest session", value: "\(biggest?.prompts ?? 0) prompts",
                            sub: biggest?.title ?? "–")
                    Insight(label: "Tool calls", value: "\(sessions.reduce(0) { $0 + $1.toolCalls })", sub: "last 30 days")
                    Insight(label: "Files edited", value: "\(Set(sessions.flatMap { $0.files }).count)", sub: "unique, last 30 days")
                }
            }
        }.scrollIndicators(.hidden)
    }
}

// MARK: - Desktop widget

/// Hosting view that drags its window itself so we get a reliable "dropped" callback for snapping.
final class DragHostingView<Content: View>: NSHostingView<Content> {
    var onDrop: () -> Void = {}
    private var grab = NSPoint.zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { super.mouseDown(with: e); return }  // ctrl-click → context menu
        grab = e.locationInWindow
    }
    override func mouseDragged(with e: NSEvent) {
        guard let w = window else { return }
        let d = NSPoint(x: e.locationInWindow.x - grab.x, y: e.locationInWindow.y - grab.y)
        w.setFrameOrigin(NSPoint(x: w.frame.minX + d.x, y: w.frame.minY + d.y))
    }
    override func mouseUp(with e: NSEvent) { onDrop() }
}

enum WidgetSize: String {
    case medium, large
    /// Native desktop-widget cell is 180pt; medium = 2×1 cells, large = 2×2 cells.
    var window: CGSize { self == .medium ? CGSize(width: 360, height: 180) : CGSize(width: 360, height: 360) }
}

struct WidgetView: View {
    @ObservedObject var store: Store

    var body: some View {
        let cal = Calendar.current
        let today = store.sessions.filter { cal.isDateInToday($0.lastActive) }
        let week = dailyPrompts(store.sessions, days: 7)
        let large = store.widgetSize == .large
        let recent = Array(store.sessions.prefix(large ? 4 : 2))
        VStack(alignment: .leading, spacing: large ? 12 : 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.orange)
                Text("Claude Today").font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
                Text(Date(), format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                stat(today.count, "sessions")
                stat(today.reduce(0) { $0 + $1.prompts }, "prompts")
                stat(Set(today.flatMap { $0.files }).count, "files")
                Spacer(minLength: 0)
            }
            if large {
                chart(week).frame(height: 90)
                sessionList(recent)
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    chart(week).frame(width: 136, height: 52)
                    sessionList(recent)
                }
            }
        }
        .padding(14)
        .frame(width: 342, height: large ? 342 : 162, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .padding(9)   // native widget windows carry 9pt of transparent inset inside their 180pt cell
        .contextMenu {
            Button("Refresh") { store.refresh() }
            Button("Open Claude Work") { store.onOpen() }
            Menu("Size") {
                Button("Medium") { store.widgetSize = .medium }
                Button("Large") { store.widgetSize = .large }
            }
            Divider()
            Button("Hide widget") { store.widgetOn = false }
        }
    }

    func chart(_ week: [(day: Date, count: Int)]) -> some View {
        let cal = Calendar.current
        return Chart(week, id: \.day) { d in
            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Prompts", d.count))
                .foregroundStyle(cal.isDateInToday(d.day) ? Color.orange : Color.orange.opacity(0.35))
                .cornerRadius(3)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
            }
        }
    }

    func sessionList(_ recent: [Session]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(recent) { r in
                HStack(spacing: 7) {
                    Circle().fill(Color.project(r.project)).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text("\(r.project) · \(relative(r.lastActive))")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    func stat(_ v: Int, _ l: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(v)").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(l).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var tab = 0

    var groups: [(String, [Session])] {
        var order: [String] = []
        var dict: [String: [Session]] = [:]
        for s in store.visible {
            let k = dayLabel(s.lastActive)
            if dict[k] == nil { order.append(k) }
            dict[k, default: []].append(s)
        }
        return order.map { ($0, dict[$0]!) }
    }

    var body: some View {
        let v = store.visible
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.orange)
                Text("Claude Work").font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                Picker("", selection: $tab) {
                    Image(systemName: "list.bullet").tag(0)
                    Image(systemName: "chart.bar.xaxis").tag(1)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 84)
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh")
            }
            if tab == 1 {
                AnalyzeView(sessions: store.sessions)
            } else {
                Picker("", selection: $store.range) {
                    ForEach(Store.Range.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()

                HStack(spacing: 8) {
                    Tile(value: v.count, label: "Sessions", icon: "bolt.fill", tint: .orange)
                    Tile(value: v.reduce(0) { $0 + $1.prompts }, label: "Prompts", icon: "text.bubble.fill", tint: .blue)
                    Tile(value: Set(v.flatMap { $0.files }).count, label: "Files edited", icon: "doc.fill", tint: .green)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if v.isEmpty && !store.loading {
                            Text("No Claude activity in this period.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                        ForEach(groups, id: \.0) { g in
                            Text(g.0.uppercased()).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary).padding(.top, 4)
                            ForEach(g.1) { Row(s: $0) }
                        }
                    }
                }.scrollIndicators(.hidden)
            }

            HStack {
                Toggle("Login", isOn: $loginOn)
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                    .onChange(of: loginOn) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { loginOn = SMAppService.mainApp.status == .enabled }
                    }
                Toggle("Desktop widget", isOn: $store.widgetOn)
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var item: NSStatusItem!
    let popover = NSPopover()
    var hotKeyRef: EventHotKeyRef?
    var panel: NSPanel?
    var timer: Timer?
    var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Claude Work")
            b.target = self
            b.action = #selector(toggle)
        }
        popover.behavior = .transient
        let host = NSHostingController(rootView: ContentView(store: store))
        host.sizingOptions = []
        popover.contentViewController = host
        store.onOpen = { [weak self] in
            if self?.popover.isShown == false { self?.toggle() }
        }
        store.$widgetOn.sink { [weak self] on in
            UserDefaults.standard.set(on, forKey: "widgetOn")
            if on { self?.showWidget() } else { self?.hideWidget() }
        }.store(in: &cancellables)
        store.$widgetSize.dropFirst().sink { [weak self] size in
            UserDefaults.standard.set(size.rawValue, forKey: "widgetSize")
            DispatchQueue.main.async { self?.applyWidgetSize() }
        }.store(in: &cancellables)
        store.refresh()
        registerHotKey()
        // Native widgets may finish loading after us; re-check we're not sitting on top of one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.snapWidget() }
    }

    func showWidget() {
        if panel == nil {
            let sz = store.widgetSize.window
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: sz),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            let hv = DragHostingView(rootView: WidgetView(store: store))
            hv.onDrop = { [weak self] in self?.snapWidget() }
            p.contentView = hv
            if p.setFrameUsingName("ClaudeWorkWidget2") {
                p.setFrame(NSRect(x: p.frame.minX, y: p.frame.maxY - sz.height, width: sz.width, height: sz.height), display: false)
            } else if let v = NSScreen.screens.first?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: v.maxX - sz.width - 8, y: v.maxY - sz.height - 8))
            }
            p.setFrameAutosaveName("ClaudeWorkWidget2")
            panel = p
        }
        panel?.orderFrontRegardless()
        snapWidget()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
    }

    func applyWidgetSize() {
        guard let p = panel else { return }
        let sz = store.widgetSize.window
        p.setFrame(NSRect(x: p.frame.minX, y: p.frame.maxY - sz.height, width: sz.width, height: sz.height), display: true)
        snapWidget()
    }

    /// Frames (AppKit coordinates) of the native macOS desktop widgets currently on screen.
    func nativeWidgetFrames() -> [NSRect] {
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { w in
            guard (w[kCGWindowOwnerName as String] as? String) == "Notification Centre",
                  (w[kCGWindowLayer as String] as? Int) == -2147483601,
                  let b = w[kCGWindowBounds as String] as? [String: Double],
                  let x = b["X"], let y = b["Y"], let bw = b["Width"], let bh = b["Height"],
                  bw <= 720, bh <= 720, bw.truncatingRemainder(dividingBy: 180) == 0,
                  bh.truncatingRemainder(dividingBy: 180) == 0 else { return nil }
            return NSRect(x: x, y: primaryH - y - bh, width: bw, height: bh)
        }
    }

    /// Glide the widget onto the same 180pt grid the native desktop widgets use (anchored 8pt in from the
    /// top-left of the visible screen), choosing the nearest cell that isn't already taken by another widget.
    func snapWidget() {
        guard let p = panel, p.isVisible, let v = (p.screen ?? NSScreen.main)?.visibleFrame else { return }
        let cell: CGFloat = 180, inset: CGFloat = 8
        let w = p.frame.width, h = p.frame.height
        let taken = nativeWidgetFrames()
        var best: (pt: NSPoint, d: CGFloat)?
        var fallback: (pt: NSPoint, d: CGFloat)?
        let cols = Int((v.width - inset) / cell), rows = Int((v.height - inset) / cell)
        for c in 0..<max(cols, 1) {
            for r in 0..<max(rows, 1) {
                let pt = NSPoint(x: v.minX + inset + CGFloat(c) * cell, y: v.maxY - inset - CGFloat(r) * cell - h)
                let rect = NSRect(origin: pt, size: NSSize(width: w, height: h))
                guard v.insetBy(dx: -1, dy: -1).contains(rect) else { continue }
                let d = hypot(pt.x - p.frame.minX, pt.y - p.frame.minY)
                if fallback == nil || d < fallback!.d { fallback = (pt, d) }
                if taken.contains(where: { $0.insetBy(dx: 2, dy: 2).intersects(rect) }) { continue }
                if best == nil || d < best!.d { best = (pt, d) }
            }
        }
        guard let target = (best ?? fallback)?.pt else { return }
        guard abs(target.x - p.frame.minX) > 0.5 || abs(target.y - p.frame.minY) > 0.5 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(NSRect(origin: target, size: p.frame.size), display: true)
        }
    }

    func hideWidget() {
        panel?.orderOut(nil)
        timer?.invalidate()
        timer = nil
    }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let b = item.button else { return }
        store.refresh()
        let avail = (b.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 700
        popover.contentSize = NSSize(width: 380, height: max(320, min(560, avail - 80)))
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let d = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { d.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x434C5744), id: 1)  // 'CLWD'
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
