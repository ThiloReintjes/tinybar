import AppKit
import Charts
import SwiftUI
import TinybarCore

/// The Stats window (SPEC §13). Built when opened and released when closed, so it costs nothing
/// while you're not looking at it.
@MainActor
final class StatsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: StatsView(model: model))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Tinybar Stats"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Stats")
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the SwiftUI tree with the window; the next open builds it fresh.
        window?.contentViewController = nil
        window = nil
    }
}

/// Window chrome around the card: the range picker and the copy button sit in the title bar row,
/// outside what gets copied.
struct StatsView: View {
    let model: AppModel
    @AppStorage("statsRange") private var rangeRaw = StatsRange.month.rawValue
    @State private var summary: StatsSummary?
    @State private var copied = false
    @Environment(\.colorScheme) private var scheme

    private var range: StatsRange { StatsRange(rawValue: rangeRaw) ?? .month }

    var body: some View {
        let palette = StatsPalette(scheme)
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Picker("Range", selection: $rangeRaw) {
                    ForEach(StatsRange.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy image", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 96)
                }
                .disabled(summary?.isEmpty ?? true)
                .keyboardShortcut("c")
                .help("Copy the card as an image, ready to paste")
                .padding(.trailing, 20)
            }
            .frame(height: 52)

            StatsCard(summary: summary, importing: model.importProgress, palette: palette)
        }
        .background(palette.canvas)
        .task(id: "\(rangeRaw)|\(model.lastUpdated?.timeIntervalSince1970 ?? 0)|\(model.importProgress == nil)") {
            summary = await model.statsSummary(range)
        }
    }

    private func copy() {
        guard let summary, let image = StatsCard.image(summary, scheme: scheme) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}

// MARK: Palette

/// The card's colours, fixed per appearance rather than read from AppKit, so the copied image looks
/// the same as the window. Claude is its logo's orange; Codex is ink, like OpenAI's mark.
struct StatsPalette {
    let canvas: Color
    let ink: Color
    let ink2: Color
    let ink3: Color
    let faint: Color
    let claude: Color

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            canvas = Color(red: 0.11, green: 0.11, blue: 0.12)
            ink = Color(white: 0.96)
            claude = Color(red: 0.91, green: 0.53, blue: 0.40)
        } else {
            canvas = .white
            ink = Color(white: 0.07)
            claude = Color(red: 0.85, green: 0.45, blue: 0.31)
        }
        ink2 = ink.opacity(0.62)
        ink3 = ink.opacity(0.4)
        faint = ink.opacity(0.07)
    }

    func color(_ provider: ProviderID) -> Color {
        provider == .claude ? claude : ink
    }
}

// MARK: Card

/// The shareable composition: one giant number, then the facts that explain it.
struct StatsCard: View {
    let summary: StatsSummary?
    let importing: Double?
    let palette: StatsPalette

    static let size = CGSize(width: 960, height: 600)

    var body: some View {
        ZStack {
            if let summary, !summary.isEmpty {
                content(summary)
            } else if let importing {
                VStack(spacing: 10) {
                    Text("Counting your history…").font(.system(size: 15, weight: .medium))
                    ProgressView(value: importing).frame(width: 220)
                }
                .foregroundStyle(palette.ink2)
            } else if summary != nil {
                VStack(spacing: 6) {
                    Text("Nothing to count yet").font(.system(size: 17, weight: .semibold))
                    Text("Stats come from Claude Code and Codex logs. Run a session and they show up here.")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.ink2)
                }
                .foregroundStyle(palette.ink)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(palette.canvas)
    }

    private func content(_ s: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(summary: s, palette: palette)
            HStack(alignment: .top, spacing: 44) {
                VStack(alignment: .leading, spacing: 0) {
                    Hero(summary: s, palette: palette)
                    DailyBars(days: s.days, palette: palette)
                        .frame(height: 84)
                        .padding(.top, 20)
                    Quartet(summary: s, palette: palette)
                        .padding(.top, 24)
                }
                .frame(width: Hero.width, alignment: .leading)
                VStack(alignment: .leading, spacing: 22) {
                    HeatMap(heat: s.heat, palette: palette)
                    ToolBars(tools: s.tools, total: s.toolCalls, palette: palette)
                    ModelTable(models: s.models, palette: palette)
                }
                .frame(width: 300, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
            Spacer(minLength: 0)
            Facts(summary: s, palette: palette)
        }
        .padding(.horizontal, 36)
        .padding(.top, 26)
        .padding(.bottom, 26)
        .foregroundStyle(palette.ink)
    }

    /// The card as an image at twice its size, for the clipboard.
    @MainActor
    static func image(_ summary: StatsSummary, scheme: ColorScheme) -> NSImage? {
        let renderer = ImageRenderer(content: StatsCard(summary: summary, importing: nil, palette: StatsPalette(scheme))
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        return renderer.nsImage
    }
}

// MARK: Pieces

private struct Header: View {
    let summary: StatsSummary
    let palette: StatsPalette

    var body: some View {
        HStack(spacing: 7) {
            Text(StatsText.span(summary))
            Spacer()
            Mark(palette: palette).frame(width: 15, height: 15)
            Text("Tinybar")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.ink2)
    }
}

/// The app icon's two rings, drawn small: the same in the window and in a copied image.
private struct Mark: View {
    let palette: StatsPalette

    var body: some View {
        ZStack {
            ring(0.74, Color(red: 0.91, green: 0.45, blue: 0.27), inset: 0)
            ring(0.42, Color(red: 0.25, green: 0.53, blue: 0.94), inset: 4)
        }
    }

    private func ring(_ fraction: Double, _ color: Color, inset: CGFloat) -> some View {
        ZStack {
            Circle().stroke(palette.faint, lineWidth: 2.4)
            Circle().trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(inset + 1.2)
    }
}

/// The token count in full, its digits coloured by each subscription's share: the number is its
/// own stacked bar.
private struct Hero: View {
    let summary: StatsSummary
    let palette: StatsPalette

    var body: some View {
        let number = summary.tokens.formatted(.number)
        let size = Self.fontSize(number, width: Self.width)
        let claude = Self.split(number, share: Double(summary.tokensByProvider[.claude] ?? 0) / Double(max(summary.tokens, 1)))
        VStack(alignment: .leading, spacing: 2) {
            Text(number)
                .font(.system(size: size, weight: .heavy).width(.compressed))
                .tracking(-size * 0.01)
                .lineLimit(1)
                // The gradient spans the text's own frame, so the frame must hug the glyphs for the
                // colour split to fall where the shares say.
                .foregroundStyle(LinearGradient(
                    stops: [
                        .init(color: palette.claude, location: 0),
                        .init(color: palette.claude, location: claude),
                        .init(color: palette.ink, location: claude),
                        .init(color: palette.ink, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing))
                .fixedSize()
                // Trim the line's empty ascent, but keep the descent: comma tails hang below.
                .padding(.top, -size * 0.1)
            HStack(alignment: .firstTextBaseline) {
                Text("tokens \(StatsText.rangePhrase(summary.range))")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.ink2)
                Spacer()
                if let cost = summary.cost {
                    Text("$" + Int(cost.rounded()).formatted(.number)).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    Text("at API prices").font(.system(size: 16, weight: .medium)).foregroundStyle(palette.ink2)
                }
            }
            HStack(spacing: 14) {
                ForEach([ProviderID.claude, .codex], id: \.self) { id in
                    if let t = summary.tokensByProvider[id], t > 0 {
                        HStack(spacing: 5) {
                            Circle().fill(palette.color(id)).frame(width: 7, height: 7)
                            Text("\(id.displayName) \(StatsText.percent(Double(t) / Double(max(summary.tokens, 1))))")
                        }
                    }
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.ink2)
            .padding(.top, 6)
        }
    }

    static let width: CGFloat = 544

    private static let probe: CGFloat = 100
    private static let probeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: probe, weight: .heavy, width: .compressed), .kern: -probe * 0.01,
    ]

    /// As large as fits the column, up to a cap, measured with the same compressed face.
    static func fontSize(_ text: String, width: CGFloat) -> CGFloat {
        let measured = (text as NSString).size(withAttributes: probeAttributes).width
        return min(148, probe * width / max(measured, 1))
    }

    /// Where the colour changes, as a fraction of the number's width: the glyph boundary closest
    /// to the share, so no digit is cut in two. The legend carries the exact percentages.
    static func split(_ text: String, share: Double) -> Double {
        let total = (text as NSString).size(withAttributes: probeAttributes).width
        guard total > 0, share > 0, share < 1 else { return share <= 0 ? 0 : 1 }
        var best = 0.0
        for i in 0...text.count {
            let w = (String(text.prefix(i)) as NSString).size(withAttributes: probeAttributes).width / total
            if abs(w - share) < abs(best - share) { best = w }
        }
        return best
    }
}

private struct DailyBars: View {
    let days: [StatsSummary.Day]
    let palette: StatsPalette

    private struct Bar: Identifiable {
        var id: String { "\(day)-\(provider.rawValue)" }
        var day: String
        var provider: ProviderID
        var tokens: Int64
    }

    var body: some View {
        let bars = days.flatMap { d in [ProviderID.claude, .codex].map { Bar(day: d.day, provider: $0, tokens: d.tokens[$0] ?? 0) } }
        Chart(bars) { bar in
            BarMark(
                x: .value("Day", DayKeyDate.date(bar.day), unit: .day),
                y: .value("Tokens", bar.tokens),
                width: .ratio(days.count > 60 ? 0.9 : 0.62))
                .foregroundStyle(palette.color(bar.provider))
                .cornerRadius(days.count > 60 ? 0 : 2)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.faint).frame(height: 1)
        }
        .accessibilityLabel("Tokens per day")
    }
}

/// Four headline numbers about what the agents did.
private struct Quartet: View {
    let summary: StatsSummary
    let palette: StatsPalette

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cell(StatsText.duration(summary.agentMillis), "Agent time", StatsText.workWeeks(summary.agentMillis))
            cell(summary.toolCalls.formatted(.number), "Tool calls",
                 summary.prompts > 0 ? "\(StatsText.one(Double(summary.toolCalls) / Double(summary.prompts))) per prompt" : nil)
            cell("+" + summary.linesAdded.formatted(.number), "Lines written",
                 summary.linesRemoved > 0 ? "\u{2212}\(summary.linesRemoved.formatted(.number)) removed" : nil)
            cell(summary.prompts.formatted(.number), "Prompts",
                 summary.prompts > 0 ? "\(StatsText.one(Double(summary.responses) / Double(summary.prompts))) responses each" : nil)
        }
    }

    private func cell(_ value: String, _ label: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                // A cell is a quarter column wide: longer numbers step down instead of colliding.
                .font(.system(size: min(34, 34 * 8 / CGFloat(max(value.count, 1))), weight: .bold).width(.compressed))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .frame(height: 40, alignment: .bottomLeading)
            Text(label).font(.system(size: 12, weight: .semibold))
            Text(detail ?? " ").font(.system(size: 11)).foregroundStyle(palette.ink2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Responses by weekday and hour, Monday on top.
private struct HeatMap: View {
    let heat: [[Int64]]
    let palette: StatsPalette

    var body: some View {
        let peak = max(heat.flatMap { $0 }.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "When your agents work", palette: palette)
            HStack(alignment: .top, spacing: 5) {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(Array(StatsText.weekdayInitials.enumerated()), id: \.offset) { _, d in
                        Text(d).frame(height: 9.5)
                    }
                }
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(palette.ink3)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<7, id: \.self) { day in
                        HStack(spacing: 2) {
                            ForEach(0..<24, id: \.self) { hour in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(fill(heat[day][hour], peak: peak))
                                    .frame(width: 9.5, height: 9.5)
                            }
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach([0, 6, 12, 18], id: \.self) { h in
                            Text(String(format: "%02d", h)).frame(width: 11.5 * 6, alignment: .leading)
                        }
                    }
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(palette.ink3)
                }
            }
            if let busiest = StatsText.busiestHour(heat) {
                Text(busiest).font(.system(size: 11)).foregroundStyle(palette.ink2)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(StatsText.busiestHour(heat) ?? "Activity by hour")
    }

    private func fill(_ v: Int64, peak: Int64) -> Color {
        guard v > 0 else { return palette.faint }
        return palette.ink.opacity(0.14 + 0.8 * (Double(v) / Double(peak)).squareRoot())
    }
}

private struct ToolBars: View {
    let tools: [StatsSummary.Tool]
    let total: Int64
    let palette: StatsPalette

    var body: some View {
        let top = tools.filter { $0.category != .other }.prefix(5)
        let largest = max(top.first?.calls ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Tool calls", palette: palette)
            ForEach(Array(top)) { tool in
                HStack(spacing: 8) {
                    Text(tool.category.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: 96, alignment: .leading)
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            ForEach([ProviderID.claude, .codex], id: \.self) { id in
                                let v = tool.byProvider[id] ?? 0
                                if v > 0 {
                                    Rectangle()
                                        .fill(palette.color(id))
                                        .frame(width: geo.size.width * CGFloat(v) / CGFloat(largest))
                                }
                            }
                        }
                        .clipShape(Capsule())
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 6)
                    Text(tool.calls.formatted(.number))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .frame(width: 54, alignment: .trailing)
                }
                .frame(height: 15)
            }
        }
    }
}

private struct ModelTable: View {
    let models: [StatsSummary.Model]
    let palette: StatsPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SectionTitle(text: "Models", palette: palette)
                Spacer()
                Text("Speed").frame(width: 62, alignment: .trailing)
                    .help("Output tokens per second, from sending the request to the last token, for responses of 200 tokens or more")
                Text("Peak context").frame(width: 76, alignment: .trailing)
                    .help("The largest context one request read, cached or not")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(palette.ink3)
            ForEach(models.prefix(3)) { m in
                HStack(spacing: 6) {
                    Circle().fill(palette.color(m.provider)).frame(width: 6, height: 6)
                    Text(ModelName.display(m.name)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(Format.tokens(m.tokens)).font(.system(size: 11.5)).foregroundStyle(palette.ink2)
                    Spacer(minLength: 4)
                    Text(m.speed.map { "\(Int($0.rounded())) tok/s" } ?? "\u{2014}")
                        .frame(width: 62, alignment: .trailing)
                    Text(m.peakContext > 0 ? Format.tokens(m.peakContext) : "\u{2014}")
                        .frame(width: 76, alignment: .trailing)
                }
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
            }
        }
    }
}

/// The bottom line: smaller facts, one row.
private struct Facts: View {
    let summary: StatsSummary
    let palette: StatsPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(palette.faint).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                fact(StatsText.days(summary.currentStreak), "Current streak", "longest \(StatsText.days(summary.longestStreak))")
                if let b = summary.busiestDay {
                    fact(StatsText.shortDate(b.day), "Busiest day", "\(Format.tokens(b.tokens)) tokens")
                }
                fact(summary.cacheShare.map(StatsText.percent) ?? "\u{2014}", "Read from cache", "of all input tokens")
                fact(summary.compactions.formatted(.number), "Compactions",
                     summary.compactedTokens > 0 ? "\(Format.tokens(summary.compactedTokens)) tokens summarized" : "context resets")
                fact(summary.peakContext > 0 ? Format.tokens(summary.peakContext) : "\u{2014}", "Biggest context", "tokens in one request")
                fact(summary.projects.formatted(.number), summary.projects == 1 ? "Project" : "Projects",
                     "across \(summary.activeDays) active \(summary.activeDays == 1 ? "day" : "days")")
            }
            if !summary.activitySince.isEmpty {
                Text(StatsText.since(summary.activitySince))
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.ink3)
            }
        }
    }

    private func fact(_ value: String, _ label: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 21, weight: .bold).width(.compressed))
                .monospacedDigit()
                .lineLimit(1)
            Text(label).font(.system(size: 11, weight: .semibold))
            Text(detail).font(.system(size: 10.5)).foregroundStyle(palette.ink2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SectionTitle: View {
    let text: String
    let palette: StatsPalette

    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink)
    }
}

// MARK: Text

enum StatsText {
    static let weekdayInitials = ["M", "T", "W", "T", "F", "S", "S"]
    private static let weekdayNames = ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]

    static func rangePhrase(_ range: StatsRange) -> String {
        switch range {
        case .week: "in the last 7 days"
        case .month: "in the last 30 days"
        case .all: "since you started"
        }
    }

    static func span(_ s: StatsSummary) -> String {
        let a = DayKeyDate.date(s.firstDay), b = DayKeyDate.date(s.lastDay)
        let sameYear = Calendar.current.component(.year, from: a) == Calendar.current.component(.year, from: b)
        let start = sameYear ? a.formatted(.dateTime.month(.abbreviated).day()) : a.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(start) to \(b.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    static func shortDate(_ day: String) -> String {
        DayKeyDate.date(day).formatted(.dateTime.month(.abbreviated).day())
    }

    static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    static func one(_ x: Double) -> String {
        x >= 10 ? "\(Int(x.rounded()))" : x.formatted(.number.precision(.fractionLength(1)))
    }

    static func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    static func duration(_ ms: Int64) -> String {
        let minutes = Int(ms / 60_000)
        let h = minutes / 60, m = minutes % 60
        if h >= 100 { return "\(h) h" }
        if h > 0 { return "\(h) h \(m) m" }
        return "\(m) m"
    }

    /// Agent Time against a 40-hour week (or an 8-hour day, below one week).
    static func workWeeks(_ ms: Int64) -> String? {
        let hours = Double(ms) / 3_600_000
        if hours >= 40 { return "\(one(hours / 40)) weeks of 40 h" }
        if hours >= 8 { return "\(one(hours / 8)) days of 8 h" }
        return nil
    }

    static func busiestHour(_ heat: [[Int64]]) -> String? {
        var best: (Int, Int, Int64) = (0, 0, 0)
        for d in 0..<7 { for h in 0..<24 where heat[d][h] > best.2 { best = (d, h, heat[d][h]) } }
        guard best.2 > 0 else { return nil }
        return "Busiest: \(weekdayNames[best.0]) at \(String(format: "%02d:00", best.1))"
    }

    static func since(_ since: [ProviderID: String]) -> String {
        let parts = since.sorted { $0.key < $1.key }.map { "\($0.key.displayName) since \(shortDate($0.value))" }
        return "Activity counted from the logs still on disk: " + parts.joined(separator: ", ") + "."
    }
}
