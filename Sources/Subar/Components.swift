import Charts
import SubarCore
import SwiftUI

// MARK: Surfaces
//
// The popover itself is the Liquid Glass layer on macOS 26. Everything inside is a tinted fill
// on that glass, never a second glass layer: glass on glass loses its legibility.

extension View {
    /// The quiet surface content sits on: a faint fill, so it never competes with the glass.
    func platter(cornerRadius: CGFloat = 14) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.primary.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                }
        }
    }
}

enum Motion {
    /// Critically damped: pages and selection move without overshoot.
    static let page = Animation.spring(response: 0.35, dampingFraction: 1)
    static let reduced = Animation.easeOut(duration: 0.15)
}

// MARK: Rings

/// Concentric rings, one per Limit Window, longest outside. Each ring is full when the window is
/// untouched and empties as it is used, like the ring in the menu bar.
struct LimitRings: View {
    let windows: [LimitWindow]
    /// nil draws neutral grey rings (empty state).
    let provider: ProviderID?
    var lineWidth: CGFloat = 4.5
    var gap: CGFloat = 2
    var dimmed = false

    var body: some View {
        let track = (provider?.color ?? .secondary).opacity(0.16)
        ZStack {
            if windows.isEmpty {
                Circle().stroke(track, lineWidth: lineWidth).padding(lineWidth / 2)
            }
            ForEach(Array(windows.enumerated()), id: \.element.id) { i, window in
                Ring(fraction: window.remainingPercent / 100, provider: provider, track: track, lineWidth: lineWidth)
                    .padding(CGFloat(i) * (lineWidth + gap) + lineWidth / 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.55 : 1)
        .accessibilityElement()
        .accessibilityLabel(windows.map { "\($0.title) \(Int($0.remainingPercent.rounded()))% left" }.joined(separator: ", "))
    }

    private struct Ring: View {
        let fraction: Double
        let provider: ProviderID?
        let track: Color
        let lineWidth: CGFloat

        var body: some View {
            let f = min(max(fraction, 0), 1)
            ZStack {
                Circle().stroke(track, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: f)
                    .stroke(
                        provider?.ringFill(fraction: f) ?? AnyShapeStyle(Color.secondary),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .animation(.smooth(duration: 0.5), value: f)
        }
    }
}

extension ProviderSnapshot {
    private var generalWindows: [LimitWindow] {
        let general = windows.filter { !$0.isModelSpecific }
        return general.isEmpty ? windows : general
    }

    /// What the rings show: the account-wide windows, longest (outermost) first.
    var ringWindows: [LimitWindow] {
        Array(generalWindows.sorted { ($0.durationSeconds ?? .max) > ($1.durationSeconds ?? .max) }.prefix(2))
    }

    /// The account-wide window closest to running out; ties go to the one that resets first.
    var bindingWindow: LimitWindow? {
        generalWindows.min {
            ($0.remainingPercent, $0.resetsAt ?? .distantFuture) < ($1.remainingPercent, $1.resetsAt ?? .distantFuture)
        }
    }
}

// MARK: Numbers

/// A percentage set the way the rings are read: rounded numerals, a smaller percent sign.
struct PercentText: View {
    let percent: Double
    var size: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(Int(percent.rounded()))")
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .tracking(size > 18 ? -0.4 : 0)
            Text("%")
                .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .foregroundStyle(Self.color(percent))
        .accessibilityElement()
        .accessibilityLabel("\(Int(percent.rounded()))% left")
    }

    /// Only a limit that is nearly gone gets a colour; everything else stays neutral.
    static func color(_ percent: Double) -> Color {
        switch percent {
        case ..<5: .red
        case ..<20: .orange
        default: .primary
        }
    }
}

/// Fills with what is left: full at the start of a window, empty when the limit is reached.
struct RemainingBar: View {
    let fraction: Double
    let provider: ProviderID

    var body: some View {
        GeometryReader { geo in
            let f = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(provider.color.opacity(0.14))
                Capsule()
                    .fill(provider.barFill)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: f > 0 ? max(6, geo.size.width * f) : 0)
                    }
            }
        }
        .frame(height: 6)
        .animation(.smooth(duration: 0.5), value: fraction)
    }
}

enum ResetText {
    /// "Resets in 4h 7m" for the compact overview.
    static func short(_ window: LimitWindow, now: Date = Date()) -> String {
        guard let resetsAt = window.resetsAt else { return window.title }
        return "\(window.title) resets in \(Format.countdown(to: resetsAt, now: now))"
    }

    /// "Resets at 18:39, in 4h 7m" or "Resets Fri 09:00, in 3d 18h".
    static func long(_ resetsAt: Date, now: Date = Date()) -> String {
        let sameDay = Calendar.current.isDate(resetsAt, inSameDayAs: now)
        let when = sameDay
            ? "at \(resetsAt.formatted(date: .omitted, time: .shortened))"
            : resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "Resets \(when), in \(Format.countdown(to: resetsAt, now: now))"
    }
}

// MARK: Charts

/// Daily tokens, stacked by Provider in the same colours as the rings.
struct UsageBars: View {
    let days: [UsageSummary.DayBar]
    let range: UsageRange
    var showAxis = true

    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let start = Calendar.current.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today
        let end = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        Chart(days) { bar in
            BarMark(
                x: .value("Day", DayKeyDate.date(bar.day), unit: .day),
                y: .value("Tokens", bar.tokens),
                width: .ratio(range == .month ? 0.7 : 0.55))
                .foregroundStyle(by: .value("Provider", bar.provider.displayName))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale(
            domain: ProviderID.allCases.map(\.displayName), range: ProviderID.allCases.map(\.color))
        .chartLegend(.hidden)
        .chartXScale(domain: start...end)
        .chartXAxis {
            if showAxis {
                AxisMarks(values: .stride(by: .day, count: range == .month ? 7 : 1)) { _ in
                    AxisValueLabel(format: range == .month ? .dateTime.day().month(.abbreviated) : .dateTime.weekday(.narrow), centered: true)
                }
            }
        }
        .chartYAxis {
            if showAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                    AxisValueLabel { Text(Format.tokens(value.as(Int64.self) ?? 0)) }
                }
            }
        }
        .accessibilityLabel("Tokens per day")
    }
}

/// Top models or projects. Each row is backed by a faint bar showing its share of all tokens,
/// split by subscription in their colours.
struct Breakdown: View {
    let title: String
    let lines: [UsageSummary.Line]
    let total: Int64

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                ForEach(lines.prefix(5)) { line in
                    HStack(spacing: 8) {
                        Text(line.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Format.tokens(line.tokens)).foregroundStyle(.secondary)
                        Text(Format.cost(line.cost)).frame(width: 58, alignment: .trailing)
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(alignment: .leading) { ShareBar(line: line, total: total) }
                }
            }
        }
    }

    private struct ShareBar: View {
        let line: UsageSummary.Line
        let total: Int64

        var body: some View {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(line.byProvider.keys.sorted(), id: \.self) { id in
                        Rectangle()
                            .fill(id.color.opacity(0.16))
                            .frame(width: geo.size.width * share(line.byProvider[id] ?? 0))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .animation(.smooth(duration: 0.4), value: line.tokens)
        }

        private func share(_ tokens: Int64) -> CGFloat {
            guard total > 0 else { return 0 }
            return CGFloat(min(max(Double(tokens) / Double(total), 0), 1))
        }
    }
}

/// A subscription's colour as a small dot; Gemini's is its four-colour spark.
struct ProviderDot: View {
    let id: ProviderID
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(id == .gemini
                ? AnyShapeStyle(AngularGradient(colors: ProviderID.Gemini.clockwise, center: .center))
                : AnyShapeStyle(id.color))
            .frame(width: size, height: size)
    }
}

enum DayKeyDate {
    static func date(_ key: String) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date() }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
    }
}

// MARK: Buttons

/// A full-width row: highlights on hover and the instant it is pressed.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.05 : 0))
                        .padding(3)
                }
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: Provider presentation

extension ProviderID {
    var webDomain: String {
        switch self {
        case .claude: "claude.ai"
        case .codex: "chatgpt.com"
        case .gemini: "antigravity.google"
        case .cursor: "cursor.com"
        }
    }

    /// One colour per subscription for dots, charts and tracks, taken from its logo. Codex follows
    /// OpenAI's monochrome mark, so it is black in light mode and white in dark mode.
    var color: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: .primary
        case .gemini: Gemini.blue
        case .cursor: .gray
        }
    }

    /// The Gemini spark's colours, clockwise from its top point.
    enum Gemini {
        static let red = Color(red: 0.97, green: 0.38, blue: 0.35)     // #F7615A
        static let blue = Color(red: 0.24, green: 0.62, blue: 1.0)     // #3E9DFF
        static let green = Color(red: 0.07, green: 0.76, blue: 0.49)   // #11C27C
        static let yellow = Color(red: 0.96, green: 0.77, blue: 0.12)  // #F5C51F
        static let clockwise = [red, blue, green, yellow, red]
    }

    /// Gemini's ring runs through its logo's colours, fixed in place like the spark: red at the
    /// top, blue right, green bottom, yellow left. The others deepen towards the end of the arc.
    func ringFill(fraction: Double) -> AnyShapeStyle {
        switch self {
        case .gemini:
            AnyShapeStyle(AngularGradient(colors: Gemini.clockwise, center: .center))
        default:
            AnyShapeStyle(AngularGradient(
                colors: [color.opacity(0.7), color], center: .center,
                startAngle: .zero, endAngle: .degrees(360 * max(fraction, 0.01))))
        }
    }

    var barFill: AnyShapeStyle {
        switch self {
        case .gemini: AnyShapeStyle(LinearGradient(colors: [Gemini.yellow, Gemini.green, Gemini.blue], startPoint: .leading, endPoint: .trailing))
        default: AnyShapeStyle(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
        }
    }

    func sourceDescription(_ source: DataSource) -> String {
        switch (self, source) {
        case (_, .browser): "from your \(webDomain) browser session"
        case (.claude, _): "from your Claude Code login"
        case (.codex, .cli): "from your Codex login"
        case (.codex, .cliProcess): "from the Codex app server"
        case (.gemini, _): "from the Antigravity CLI"
        case (.cursor, _): "from the Cursor app"
        }
    }
}

extension ExtraUsageSpend {
    var formatted: String {
        let used = used.formatted(.currency(code: currency))
        guard let limit else { return used }
        return "\(used) of \(limit.formatted(.currency(code: currency)))"
    }
}

/// Developer snapshot switches (`--snapshot … --redact-projects` for public screenshots).
enum PopoverSnapshotOptions {
    static let redactProjects = CommandLine.arguments.contains("--redact-projects")

    static func projects(_ lines: [UsageSummary.Line]) -> [UsageSummary.Line] {
        guard redactProjects else { return lines }
        let names = ["acme-web", "billing-service", "No project", "docs-site", "ml-pipeline"]
        return lines.enumerated().map { i, l in
            UsageSummary.Line(name: names[i % names.count], tokens: l.tokens, cost: l.cost, byProvider: l.byProvider)
        }
    }
}
