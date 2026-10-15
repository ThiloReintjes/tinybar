import AppKit
import SwiftUI
import TinybarCore

// MARK: Page tabs

/// The Stats window's pages, in the title bar row. The current page is an ink pill that slides to
/// the next one, so the tabs read as navigation next to the range picker's native segments.
struct PageTabs: View {
    let page: StatsPage
    let palette: StatsPalette
    let select: (StatsPage) -> Void
    @Namespace private var pill
    @State private var hovered: StatsPage?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(StatsPage.allCases.enumerated()), id: \.element) { i, p in
                Button { select(p) } label: {
                    Text(p.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(p == page ? palette.canvas : hovered == p ? palette.ink : palette.ink2)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background {
                            if p == page {
                                Capsule().fill(palette.ink).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(TabPress())
                .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                .help("\(p.title) (⌘\(i + 1))")
                .onHover { inside in
                    if inside { hovered = p } else if hovered == p { hovered = nil }
                }
                .accessibilityAddTraits(p == page ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(palette.faint))
    }

    /// Answers the press, not the release.
    private struct TabPress: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

// MARK: Shared pieces

/// A page's headline number, its digits coloured by each subscription's share, like the token
/// count on the overview. Sized to every model's total, so picking a model doesn't resize it.
struct SplitNumber: View {
    let value: Int64
    let byProvider: [ProviderID: Int64]
    /// The largest this number gets in the range: all models'.
    let sizedTo: Int64
    let width: CGFloat
    let caption: String
    /// The picked model, named in place of the subscription split.
    var model: StatsSummary.Model?
    let palette: StatsPalette

    var body: some View {
        let number = value.formatted(.number)
        let size = min(96, TokensHero.fontSize(max(sizedTo, value).formatted(.number), width: width))
        let claude = TokensHero.split(number, share: Double(byProvider[.claude] ?? 0) / Double(max(value, 1)))
        VStack(alignment: .leading, spacing: 2) {
            Text(number)
                .font(.system(size: size, weight: .heavy).width(.compressed))
                .tracking(-size * 0.01)
                .lineLimit(1)
                .foregroundStyle(LinearGradient(
                    stops: [
                        .init(color: palette.claude, location: 0),
                        .init(color: palette.claude, location: claude),
                        .init(color: palette.ink, location: claude),
                        .init(color: palette.ink, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing))
                .fixedSize()
                .contentTransition(.numericText())
                .frame(height: TokensHero.lineHeight(size), alignment: .bottomLeading)
                .padding(.top, -size * 0.1)
            Text(caption)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
            HStack(spacing: 14) {
                if let model {
                    HStack(spacing: 5) {
                        Circle().fill(palette.color(model.provider)).frame(width: 7, height: 7)
                        Text("\(ModelName.display(model.name)) only")
                    }
                } else {
                    ForEach([ProviderID.claude, .codex], id: \.self) { id in
                        if let t = byProvider[id], t > 0 {
                        HStack(spacing: 5) {
                            Circle().fill(palette.color(id)).frame(width: 7, height: 7)
                                Text("\(id.displayName) \(StatsText.percent(Double(t) / Double(max(value, 1))))")
                            }
                        }
                    }
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.ink2)
            .padding(.top, 6)
            .frame(height: 20, alignment: .bottomLeading)
        }
    }
}

/// A small figure with its label and a line of detail, as in the overview's bottom row.
struct FactCell: View {
    let value: String
    let label: String
    let detail: String
    let palette: StatsPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 21, weight: .bold).width(.compressed))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 11, weight: .semibold))
            Text(detail).font(.system(size: 10.5)).foregroundStyle(palette.ink2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A bar in a list, split by subscription or filled with one colour.
private struct ListBar: View {
    let parts: [(Color, Int64)]
    let largest: Int64

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if part.1 > 0 {
                        Rectangle().fill(part.0).frame(width: geo.size.width * CGFloat(part.1) / CGFloat(max(largest, 1)))
                    }
                }
            }
            .clipShape(Capsule())
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 6)
    }
}

/// One stat ranked across models, the way the overview lists tools. Pointing at a model shows
/// its figures; clicking it picks it, and every chart lights that model's row.
struct RankedChart: View {
    let title: String
    let metric: ModelMetric
    let summary: StatsSummary
    let palette: StatsPalette
    var rows = 6
    /// What the figure means, for the tip.
    let note: String
    let format: (Double) -> String
    /// The counts behind a model's figure, for the tip.
    let detail: (StatsSummary.Model) -> [StatsTip.Row]
    @Environment(\.statsPick) private var pick
    @Environment(\.statsTipID) private var lit

    static let rowHeight: CGFloat = 17

    var body: some View {
        let ranked = metric.ranked(summary.models)
        var shown = Array(ranked.prefix(rows))
        let picked = summary.model
        let pickedHere = picked.map { p in ranked.contains { $0.model.name == p } } ?? false
        // A picked model below the top rows takes the last one.
        if let picked, pickedHere, !shown.contains(where: { $0.model.name == picked }),
           let entry = ranked.first(where: { $0.model.name == picked })
        {
            shown[shown.count - 1] = entry
        }
        let top = ranked.first?.value ?? 1
        let missing = picked.flatMap { p in pickedHere ? nil : summary.models.first { $0.name == p } }
        return VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: title, palette: palette)
                .statsTip(StatsTip(id: "chart:\(metric.rawValue)", title: title, note: note))
                .padding(.bottom, 2)
            ForEach(Array(shown.enumerated()), id: \.element.model.id) { _, entry in
                row(entry.model, entry.value, top: top, dimmed: pickedHere && entry.model.name != picked)
            }
            ForEach(shown.count..<rows, id: \.self) { i in
                if i == shown.count, let missing {
                    // The picked model, with too little data here to rank.
                    HStack(spacing: 6) {
                        Circle().fill(palette.color(missing.provider)).frame(width: 6, height: 6)
                        Text(ModelName.display(missing.name)).font(.system(size: 11.5, weight: .semibold))
                        Text("too little data").font(.system(size: 11)).foregroundStyle(palette.ink3)
                    }
                    .frame(height: Self.rowHeight)
                } else if i == 0, ranked.isEmpty {
                    Text("Not enough data in this range")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.ink3)
                        .frame(height: Self.rowHeight)
                } else {
                    Color.clear.frame(height: Self.rowHeight)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ m: StatsSummary.Model, _ value: Double, top: Double, dimmed: Bool) -> some View {
        let color = palette.color(m.provider)
        let python = metric.pythonPart(m)
        let isPicked = summary.model == m.name
        let id = "rank:\(metric.rawValue):\(m.name)"
        let label = HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(ModelName.display(m.name))
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
            GeometryReader { geo in
                let width = max(geo.size.width * CGFloat(value / max(top, .leastNonzeroMagnitude)), 2)
                HStack(spacing: 0) {
                    if let python {
                        // Inline programs: Python solid, JavaScript lighter.
                        Rectangle().fill(color).frame(width: width * CGFloat(python / max(value, .leastNonzeroMagnitude)))
                        Rectangle().fill(color.opacity(0.4))
                    } else {
                        Rectangle().fill(color)
                    }
                }
                .frame(width: width)
                .clipShape(Capsule())
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 6)
            Text(format(value))
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(width: 44, alignment: .trailing)
        }
        .frame(height: Self.rowHeight)
        .opacity(dimmed ? 0.38 : 1)
        .padding(.horizontal, 5)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(palette.ink.opacity(isPicked ? 0.08 : lit == id ? 0.05 : 0))
        }
        .padding(.horizontal, -5)
        if let pick {
            Button { pick(m.name) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .statsTip(StatsTip(
                    id: id, title: ModelName.display(m.name),
                    rows: [.init(label: title, value: format(value))] + detail(m),
                    note: isPicked ? "Click again to clear." : "Click to light this model up in every chart."))
        } else {
            label
        }
    }
}

extension StatsSummary {
    var pickedModel: Model? { model.flatMap { m in models.first { $0.name == m } } }
}

enum StatsFormat {
    /// Percent with a decimal below 10%, so small shares don't all read 0%.
    static func percent(_ f: Double) -> String {
        let p = f * 100
        if p > 0, p < 10 { return p.formatted(.number.precision(.fractionLength(1))) + "%" }
        return "\(Int(p.rounded()))%"
    }

    static func count(_ n: Int64, _ one: String, _ many: String) -> String {
        "\(n.formatted(.number)) \(n == 1 ? one : many)"
    }

    /// The range in words, after "in".
    static func range(_ r: StatsRange) -> String {
        switch r {
        case .week: "in the last 7 days"
        case .month: "in the last 30 days"
        case .all: "since you started"
        }
    }
}

// MARK: Commands

/// The shell commands the agents ran: which programs, and each model's habits.
struct CommandsPage: View {
    let summary: StatsSummary
    let palette: StatsPalette

    var body: some View {
        let c = summary.commands
        let all = summary.models.reduce(0) { $0 + $1.value(StatKey.commands) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 0) {
                    SplitNumber(value: c.count, byProvider: c.byProvider, sizedTo: all, width: 272,
                                caption: "shell commands \(StatsFormat.range(summary.range))", model: summary.pickedModel, palette: palette)
                        .statsTip(StatsTip(
                            id: "commands", title: StatsFormat.count(c.count, "shell command", "shell commands"),
                            rows: StatsText.byProvider(c.byProvider) + [
                                .init(label: "Average length", value: c.count > 0 ? "\((c.chars / c.count).formatted(.number)) characters" : "\u{2014}"),
                                .init(label: "Exited with an error", value: c.finished > 0 ? StatsFormat.percent(Double(c.failed) / Double(c.finished)) : "\u{2014}"),
                            ],
                            note: "Commands the agents ran in a shell. Codex scripts that run several count each one."))
                    Programs(commands: c, palette: palette)
                        .padding(.top, 22)
                }
                .frame(width: 272, alignment: .leading)
                Grid(alignment: .topLeading, horizontalSpacing: 32, verticalSpacing: 20) {
                    GridRow {
                        chart("Piped into head or tail", .pipedHeadTail,
                              "Commands that send their output through head or tail, to read only part of it.") { m in
                            [.init(label: "Commands", value: m.value(StatKey.commands).formatted(.number))]
                        }
                        chart("Uses grep, not rg", .grep,
                              "Of the commands that search with grep or ripgrep (rg), the share using grep. Counts grep in pipes too.") { m in
                            [.init(label: "grep", value: m.value(StatKey.program("grep")).formatted(.number)),
                             .init(label: "rg", value: m.value(StatKey.program("rg")).formatted(.number))]
                        }
                    }
                    GridRow {
                        chart("Writes a program inline", .inline,
                              "Commands that send code straight to an interpreter, like python3 - <<'PY' or node -e. Python is the solid part, JavaScript the lighter one. Running a saved script doesn't count.") { m in
                            [.init(label: "Python", value: m.value(StatKey.inlinePython).formatted(.number)),
                             .init(label: "JavaScript", value: m.value(StatKey.inlineJS).formatted(.number))]
                        }
                        chart("Average command length", .commandLength,
                              "Characters per command, heredocs and inline programs included.", format: { "\(Int($0.rounded()))" }) { m in
                            [.init(label: "Commands", value: m.value(StatKey.commands).formatted(.number))]
                        }
                    }
                    GridRow {
                        chart("Exits with an error", .failed,
                              "Commands that finished with a non-zero exit code. Commands a hook or you blocked don't count.") { m in
                            [.init(label: "Errors", value: m.value(StatKey.commandsFailed).formatted(.number)),
                             .init(label: "Finished", value: m.value(StatKey.commandsFinished).formatted(.number))]
                        }
                        chart("git status per commit", .gitStatusPerCommit,
                              "How often a model checks git status for each commit it makes. Shown from 5 commits.",
                              format: { StatsText.one($0) }) { m in
                            [.init(label: "git status", value: m.value(StatKey.git("status")).formatted(.number)),
                             .init(label: "git commit", value: m.value(StatKey.git("commit")).formatted(.number))]
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Models show up in a chart once they ran 30 commands in this range. Only program names are kept, never arguments or paths.")
                .font(.system(size: 10.5))
                .foregroundStyle(palette.ink3)
        }
    }

    private func chart(
        _ title: String, _ metric: ModelMetric, _ note: String,
        format: @escaping (Double) -> String = StatsFormat.percent,
        detail: @escaping (StatsSummary.Model) -> [StatsTip.Row]) -> some View
    {
        RankedChart(title: title, metric: metric, summary: summary, palette: palette, rows: 6, note: note, format: format, detail: detail)
            .frame(width: 274, alignment: .topLeading)
    }
}

/// The programs commands run, most first, each bar split by subscription.
private struct Programs: View {
    let commands: StatsSummary.Commands
    let palette: StatsPalette
    @Environment(\.statsTipID) private var lit

    static let rows = 11

    var body: some View {
        let top = Array(commands.programs.prefix(Self.rows))
        let largest = top.first?.total ?? 1
        let hovering = lit?.hasPrefix("program:") == true
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "Programs they run", palette: palette).padding(.bottom, 2)
            ForEach(top) { p in
                HStack(spacing: 8) {
                    Text(p.name)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .frame(width: 70, alignment: .leading)
                    ListBar(parts: [(palette.claude, p.byProvider[.claude] ?? 0), (palette.ink, p.byProvider[.codex] ?? 0)], largest: largest)
                        .opacity(!hovering || lit == "program:\(p.name)" ? 1 : 0.35)
                    Text(StatsFormat.percent(Double(p.total) / Double(max(commands.count, 1))))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(width: 42, alignment: .trailing)
                }
                .frame(height: RankedChart.rowHeight)
                .statsTip(StatsTip(
                    id: "program:\(p.name)", title: p.name,
                    rows: [.init(label: "Commands", value: p.total.formatted(.number))] + StatsText.byProvider(p.byProvider)
                        + gitRows(p.name),
                    note: p.name == "script" ? "Saved scripts the agents ran (.sh, .py, .js and the like). Their names aren't kept."
                        : "Share of all shell commands that run \(p.name), counted once per command."))
            }
            ForEach(top.count..<Self.rows, id: \.self) { _ in Color.clear.frame(height: RankedChart.rowHeight) }
        }
    }

    private func gitRows(_ name: String) -> [StatsTip.Row] {
        guard name == "git" else { return [] }
        return commands.git.prefix(5).map { .init(label: "git \($0.name)", value: $0.value.formatted(.number)) }
    }
}

// MARK: Models

/// Each model's working style, side by side.
struct ModelsPage: View {
    let summary: StatsSummary
    let palette: StatsPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .topLeading, horizontalSpacing: 36, verticalSpacing: 26) {
                GridRow {
                    chart("Avg speed, tok/s", .speed, StatsText.speedNote, format: { "\(Int($0.rounded()))" }) { m in
                        [.init(label: "Timed responses", value: m.speedSamples.formatted(.number))]
                    }
                    chart("Responses per prompt", .responsesPerPrompt,
                          "Model responses for each prompt you typed: how many steps a model takes before it hands back.",
                          format: StatsText.one) { m in
                        [.init(label: "Responses", value: m.responses.formatted(.number)),
                         .init(label: "Prompts", value: m.value(StatKey.prompts).formatted(.number))]
                    }
                    chart("Agent time per prompt", .agentPerPrompt,
                          "How long a model works on each prompt, tools included. Gaps over 30 minutes don't count.",
                          format: { StatsText.duration(Int64($0)) }) { m in
                        [.init(label: "Agent time", value: StatsText.duration(m.value(StatKey.agentMillis))),
                         .init(label: "Prompts", value: m.value(StatKey.prompts).formatted(.number))]
                    }
                }
                GridRow {
                    chart("Runs tools in parallel", .parallel,
                          "Responses that run several tools at once: more than one tool call in a Claude response, or a Codex script that awaits several together.") { m in
                        [.init(label: "In parallel", value: m.value(StatKey.parallel).formatted(.number)),
                         .init(label: "Responses", value: m.responses.formatted(.number))]
                    }
                    chart("Lines added per prompt", .linesPerPrompt,
                          "Lines a model's file edits added, for each prompt you typed.",
                          format: { StatsText.one($0) }) { m in
                        [.init(label: "Lines added", value: m.value(StatKey.linesAdded).formatted(.number)),
                         .init(label: "Prompts", value: m.value(StatKey.prompts).formatted(.number))]
                    }
                    chart("Peak context", .peakContext,
                          "The most tokens one request to this model sent, cached or not.",
                          format: { Format.tokens(Int64($0)) }) { _ in [] }
                }
            }
            Spacer(minLength: 0)
            Text("Speed compares best within one provider: Codex starts its clock before the first token. Models show up in a chart once they have 10 prompts or 50 responses in this range.")
                .font(.system(size: 10.5))
                .foregroundStyle(palette.ink3)
        }
    }

    private func chart(
        _ title: String, _ metric: ModelMetric, _ note: String,
        format: @escaping (Double) -> String = StatsFormat.percent,
        detail: @escaping (StatsSummary.Model) -> [StatsTip.Row]) -> some View
    {
        RankedChart(title: title, metric: metric, summary: summary, palette: palette, rows: 9, note: note, format: format, detail: detail)
            .frame(width: 272, alignment: .topLeading)
    }
}

// MARK: Languages

/// Lines the agents wrote, by the language of the file.
struct LanguagesPage: View {
    let summary: StatsSummary
    let palette: StatsPalette

    var body: some View {
        let added = summary.languages.reduce(into: [ProviderID: Int64]()) { a, l in l.added.forEach { a[$0.key, default: 0] += $0.value } }
        let total = added.values.reduce(0, +)
        let all = summary.models.reduce(0) { $0 + $1.value(StatKey.linesAdded) }
        // File kinds without a language name (`.body`) are listed but not counted as languages.
        let named = summary.languages.filter { $0.totalAdded > 0 && !$0.name.hasPrefix(".") && !["Other", "No extension"].contains($0.name) }.count
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 0) {
                SplitNumber(value: total, byProvider: added, sizedTo: all, width: 272,
                            caption: "lines added in \(StatsFormat.count(Int64(named), "language", "languages"))", model: summary.pickedModel, palette: palette)
                    .statsTip(StatsTip(
                        id: "lines", title: StatsFormat.count(total, "line added", "lines added"),
                        rows: StatsText.byProvider(added),
                        note: "Lines the agents' file edits added \(StatsFormat.range(summary.range)), by the edited file's extension. Files changed through shell commands aren't seen."))
                LanguageList(summary: summary, palette: palette)
                    .padding(.top, 22)
            }
            .frame(width: 272, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                LanguageMix(summary: summary, palette: palette)
                Spacer(minLength: 0)
                LanguageFacts(summary: summary, palette: palette)
            }
        }
    }
}

/// Fixed colours for common languages, so a language keeps its colour whatever the range or model.
/// Close to the colours code hosts use for them, nudged apart where two would look alike.
enum LanguageColor {
    static func color(_ name: String, _ palette: StatsPalette) -> Color {
        let hex: UInt32? = switch name {
        case "Swift": 0xF05138
        case "TypeScript": 0x3178C6
        case "JavaScript": 0xE2B714
        case "Python": 0x3BA55C
        case "Markdown": 0x7C5CD6
        case "JSON": 0x14A3A0
        case "HTML": 0xE8608F
        case "CSS": 0xC026D3
        case "Shell": 0x8BC34A
        case "YAML": 0xD9363E
        case "Rust": 0xB45F2B
        case "Go": 0x2EB4E0
        case "SQL": 0xE38C00
        case "Ruby": 0x9F1239
        case "Kotlin": 0x8B6CF6
        case "TOML": 0x9C6B4E
        default: nil
        }
        guard let hex else { return palette.ink.opacity(0.32) }
        return Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Languages by lines added, each bar in the language's colour: the key for the mix beside it.
private struct LanguageList: View {
    let summary: StatsSummary
    let palette: StatsPalette
    @Environment(\.statsTipID) private var lit

    static let rows = 11

    var body: some View {
        let top = Array(summary.languages.filter { $0.totalAdded > 0 }.prefix(Self.rows))
        let largest = top.first?.totalAdded ?? 1
        let hovering = lit?.hasPrefix("language:") == true
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "Languages", palette: palette).padding(.bottom, 2)
            ForEach(top) { l in
                HStack(spacing: 8) {
                    Text(l.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .frame(width: 84, alignment: .leading)
                    ListBar(parts: [(LanguageColor.color(l.name, palette), l.totalAdded)], largest: largest)
                        .opacity(!hovering || lit == "language:\(l.name)" ? 1 : 0.35)
                    Text(Format.tokens(l.totalAdded))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(width: 44, alignment: .trailing)
                }
                .frame(height: RankedChart.rowHeight)
                .statsTip(StatsTip(
                    id: "language:\(l.name)", title: l.name,
                    rows: [.init(label: "Lines added", value: l.totalAdded.formatted(.number)),
                           .init(label: "Lines removed", value: l.removed.formatted(.number)),
                           .init(label: "File edits", value: l.edits.formatted(.number))]
                        + StatsText.byProvider(l.added).map { .init(label: "Added by \($0.label)", value: $0.value, provider: $0.provider) }))
            }
            ForEach(top.count..<Self.rows, id: \.self) { _ in Color.clear.frame(height: RankedChart.rowHeight) }
        }
    }
}

/// What each model writes: its lines added split by language, the most used languages in their
/// colours and the rest together.
private struct LanguageMix: View {
    let summary: StatsSummary
    let palette: StatsPalette
    @Environment(\.statsPick) private var pick
    @Environment(\.statsTipID) private var lit

    static let rows = 9
    static let coloured = 6
    static let minimumLines: Int64 = 50
    static let rowHeight: CGFloat = 27

    var body: some View {
        // Coloured languages come from all models together, so picking one doesn't recolour them.
        var totals: [String: Int64] = [:]
        var mixes: [(model: StatsSummary.Model, parts: [String: Int64], total: Int64)] = []
        for m in summary.models {
            var parts: [String: Int64] = [:]
            for (key, v) in m.values where key.hasPrefix(StatKey.extAddedPrefix) {
                parts[FileKind.language(String(key.dropFirst(StatKey.extAddedPrefix.count))), default: 0] += v
            }
            parts.forEach { totals[$0.key, default: 0] += $0.value }
            let total = parts.values.reduce(0, +)
            if total >= Self.minimumLines { mixes.append((m, parts, total)) }
        }
        let keyLanguages = totals.filter { LanguageColor.color($0.key, palette) != palette.ink.opacity(0.32) }
            .sorted { $0.value > $1.value }.prefix(Self.coloured).map(\.key)
        mixes.sort { $0.total > $1.total }
        var shown = Array(mixes.prefix(Self.rows))
        if let picked = summary.model, !shown.contains(where: { $0.model.name == picked }),
           let entry = mixes.first(where: { $0.model.name == picked }), !shown.isEmpty
        {
            shown[shown.count - 1] = entry
        }
        let pickedHere = summary.model.map { p in shown.contains { $0.model.name == p } } ?? false
        return VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "What each model writes", palette: palette)
                .statsTip(StatsTip(
                    id: "mix", title: "What each model writes",
                    note: "Each model's lines added, split by language. The six most written languages have their colour; the rest are grey. Shown from 50 lines."))
                .padding(.bottom, 2)
            ForEach(shown, id: \.model.id) { entry in
                row(entry.model, entry.parts, entry.total, keyLanguages, dimmed: pickedHere && entry.model.name != summary.model)
            }
            ForEach(shown.count..<Self.rows, id: \.self) { i in
                if i == 0 {
                    Text("Not enough edits in this range").font(.system(size: 11)).foregroundStyle(palette.ink3)
                        .frame(height: Self.rowHeight)
                } else {
                    Color.clear.frame(height: Self.rowHeight)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ m: StatsSummary.Model, _ parts: [String: Int64], _ total: Int64, _ keys: [String], dimmed: Bool) -> some View {
        let rest = total - keys.reduce(0) { $0 + (parts[$1] ?? 0) }
        let segments = keys.map { (LanguageColor.color($0, palette), parts[$0] ?? 0) } + [(palette.ink.opacity(0.16), rest)]
        let isPicked = summary.model == m.name
        let id = "mix:\(m.name)"
        let label = HStack(spacing: 6) {
            Circle().fill(palette.color(m.provider)).frame(width: 6, height: 6)
            Text(ModelName.display(m.name))
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            GeometryReader { geo in
                // A hairline between languages; every bar still spans the full width.
                let room = geo.size.width - CGFloat(max(segments.filter { $0.1 > 0 }.count - 1, 0))
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                        if s.1 > 0 {
                            Rectangle().fill(s.0).frame(width: max(room * CGFloat(s.1) / CGFloat(max(total, 1)), 1))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 13)
            Text(Format.tokens(total))
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .frame(height: Self.rowHeight)
        .opacity(dimmed ? 0.38 : 1)
        .padding(.horizontal, 5)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(palette.ink.opacity(isPicked ? 0.08 : lit == id ? 0.05 : 0))
        }
        .padding(.horizontal, -5)
        if let pick {
            let top = parts.sorted { $0.value > $1.value }.prefix(5)
            Button { pick(m.name) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .statsTip(StatsTip(
                    id: id, title: ModelName.display(m.name),
                    rows: [.init(label: "Lines added", value: total.formatted(.number))]
                        + top.map { .init(label: $0.key, value: StatsFormat.percent(Double($0.value) / Double(max(total, 1)))) },
                    note: isPicked ? "Click again to show all models." : "Click to show only this model."))
        } else {
            label
        }
    }
}

private struct LanguageFacts: View {
    let summary: StatsSummary
    let palette: StatsPalette

    var body: some View {
        let edits = summary.languages.reduce(0) { $0 + $1.edits }
        let removed = summary.languages.reduce(0) { $0 + $1.removed }
        let added = summary.languages.reduce(0) { $0 + $1.totalAdded }
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(palette.faint).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                FactCell(value: edits.formatted(.number), label: "File edits", detail: "edits and new files", palette: palette)
                    .statsTip(StatsTip(id: "edits", title: "File edits",
                                       note: "Each edit or new file an agent wrote through its edit tools. One Codex change to several files counts once per file."))
                FactCell(value: removed.formatted(.number), label: "Lines removed", detail: "by the same edits", palette: palette)
                FactCell(value: edits > 0 ? StatsText.one(Double(added) / Double(edits)) : "\u{2014}", label: "Lines per edit",
                         detail: "added, on average", palette: palette)
                FactCell(value: summary.languages.first.map(\.name) ?? "\u{2014}", label: "Most written",
                         detail: summary.languages.first.map { StatsFormat.percent(Double($0.totalAdded) / Double(max(added, 1))) + " of lines added" } ?? "no edits yet",
                         palette: palette)
            }
        }
    }
}
