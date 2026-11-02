import SwiftUI
import TinybarCore

/// One subscription with token history, as the Plans page shows it.
struct PlanRow: Identifiable {
    var id: ProviderID
    var plan: String?
    var value: PlanValue
    /// More than one when `value` covers a Pool.
    var accounts = 1

    fileprivate func points(in unit: TaskUnit) -> [ModelPoint] {
        value.models.map { model in
            let tasks = unit == .perDollar ? model.tasksPerDollar ?? model.tasksPerWeek : model.tasksPerWeek
            return ModelPoint(
                provider: id, model: model, tasks: tasks, hasUnpriced: value.fullHasUnpriced,
                share: value.recentShares[model.benchmark.model] ?? 0)
        }
    }
}

/// What the list and chart count Benchmark Tasks against: one unit for every plan, so a plan with
/// no known price puts them all in tasks per week.
private enum TaskUnit {
    case perDollar, perWeek

    var column: String { self == .perDollar ? "Tasks per $1" : "Tasks per week" }
    var spoken: String { self == .perDollar ? "tasks per dollar" : "tasks a week" }
}

/// What each plan gets you at API prices, and how its models compare on an outside benchmark
/// (SPEC §14). Plans sit side by side above a list and a chart of every model; the workings are one
/// click away.
struct PlansPage: View {
    let plans: [PlanRow]
    let palette: StatsPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if plans.isEmpty {
                Text("Plans show here once you've used Claude Code or Codex this month.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.ink2)
            } else {
                HStack(alignment: .top, spacing: 64) {
                    ForEach(plans) { PlanColumn(plan: $0, palette: palette) }
                    if plans.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                }
                let unit: TaskUnit = plans.flatMap(\.value.models).allSatisfy { $0.tasksPerDollar != nil } ? .perDollar : .perWeek
                let points = plans.flatMap { $0.points(in: unit) }
                if !points.isEmpty {
                    ModelComparison(points: points, unit: unit, palette: palette).padding(.top, 26)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text("Filled marks are models you used in the last 7 days. A task is one benchmark job, not one of yours.")
                Spacer()
                InfoButton(plans: plans, palette: palette)
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.ink2)
        }
    }
}

// MARK: A plan

private struct PlanColumn: View {
    let plan: PlanRow
    let palette: StatsPalette

    private var cli: String { plan.id == .claude ? "Claude Code" : "Codex" }

    private var noValueYet: String {
        let minimum = Int(PlanValue.minimumUsedPercent), used = Int(plan.value.usedPercent)
        if plan.accounts > 1, plan.value.usedPercent < PlanValue.minimumUsedPercent {
            return "This shows once your accounts have used \(minimum)% of a weekly limit between them. So far they've used \(used)%."
        }
        if plan.value.usedPercent < PlanValue.minimumUsedPercent {
            return "This shows once you've used \(minimum)% of your weekly limit. You've used \(used)%."
        }
        return "Tinybar can't work this out yet. Your plan changed this week, or your use this week isn't in your \(cli) logs."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ProviderMark(provider: plan.id, palette: palette).frame(width: 10, height: 10)
                Text(plan.id.displayName).font(.system(size: 14, weight: .semibold))
                if let name = plan.plan {
                    Text(name).font(.system(size: 14)).foregroundStyle(palette.ink2)
                }
            }
            if let full = plan.value.fullWindow {
                HStack(alignment: .top, spacing: 16) {
                    if let best = plan.value.bestValue { tasks(on: best) }
                    if let most = plan.value.perDollar {
                        figure(week(most), caption: "API usage per $1")
                    } else {
                        figure(week(full), caption: "API usage in a full week")
                    }
                }
                .padding(.top, 14)
                VStack(spacing: 8) {
                    meter(full: full)
                    HStack {
                        Text("Last 7 days").foregroundStyle(palette.ink2)
                        Spacer()
                        use(full: full)
                    }
                    .font(.system(size: 13))
                    .monospacedDigit()
                }
                .padding(.top, 14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(recent(plan.value.recentCost)) in the last 7 days, \(isOver(full: full) ? "over" : "of") a \(week(full)) week")
            } else {
                Text(noValueYet)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the plan buys on its best-value model. Per dollar when the plan's price is known.
    private func tasks(on best: PlanValue.Model) -> some View {
        let count = best.tasksPerDollar ?? best.tasksPerWeek
        let name = ModelName.display(best.benchmark.model)
        return figure(
            Format.rough(count) + (plan.value.fullHasUnpriced ? "+" : ""), unit: "tasks",
            caption: "\(best.tasksPerDollar == nil ? "a week" : "per $1") on \(name), best value")
    }

    private func figure(_ value: String, unit: String? = nil, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .tracking(-1.4)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.ink2)
                }
            }
            .lineLimit(1)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether the last 7 days went past a full week, by more than rounding hides. A full week with
    /// unpriced use is only a lower bound, so nothing can be said to have gone past it.
    private func isOver(full: Double) -> Bool {
        // As numbers, since "$10.00" and "$10" are the same amount at either side of the format's step.
        let shown = { (dollars: Double) in Double(Format.roughCost(dollars).dropFirst()) }
        return !plan.value.fullHasUnpriced && plan.value.recentCost > full
            && shown(plan.value.recentCost) != shown(full)
    }

    /// The last 7 days against a full week. Past one, the whole bar is the last 7 days and a notch
    /// marks where a full week ends.
    private func meter(full: Double) -> some View {
        let share = plan.value.usedShareOfWeek ?? 0
        return Capsule()
            .fill(palette.faint)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(palette.color(plan.id)).frame(width: max(g.size.width * min(share, 1), 6))
                    if isOver(full: full) {
                        Rectangle().fill(palette.canvas).frame(width: 2).offset(x: g.size.width / share - 1)
                    }
                }
            }
    }

    private func use(full: Double) -> Text {
        let dollars = { (text: String) in Text(text).foregroundColor(palette.ink).fontWeight(.medium) }
        let plain = { (text: String) in Text(text).foregroundColor(palette.ink2) }
        return dollars(recent(plan.value.recentCost))
            + plain(isOver(full: full) ? ", over a " : " of a ")
            + dollars(week(full))
            + plain(" week")
    }

    /// A + marks a lower bound, as Usage does: some of the use has no known price.
    private func recent(_ dollars: Double) -> String {
        Format.roughCost(dollars) + (plan.value.recentHasUnpriced ? "+" : "")
    }

    private func week(_ dollars: Double) -> String {
        Format.roughCost(dollars) + (plan.value.fullHasUnpriced ? "+" : "")
    }
}

/// A circle for Claude and a square for Codex, so the two read apart without their colours.
private struct ProviderMark: View {
    let provider: ProviderID
    let palette: StatsPalette
    /// Outlined rather than filled: a model the user hasn't been using.
    var hollow = false

    var body: some View {
        let color = palette.color(provider)
        let shape = RoundedRectangle(cornerRadius: provider == .claude ? 99 : 2, style: .continuous)
        Group {
            if hollow { shape.strokeBorder(color, lineWidth: 1.5) } else { shape.fill(color) }
        }
        // A thin ring of the canvas keeps the grid from showing through a hollow mark.
        .background { shape.fill(palette.canvas).padding(-1.5) }
    }
}

// MARK: Models

private struct ModelPoint: Identifiable {
    var provider: ProviderID
    var model: PlanValue.Model
    /// Benchmark Tasks in the page's unit.
    var tasks: Double
    /// The full week behind every task figure is a lower bound.
    var hasUnpriced: Bool
    /// This model's share of its plan's last 7 days.
    var share: Double

    /// Small shares are a stray subagent or a quick try, not a model the user runs.
    var isUsed: Bool { share >= 0.05 }
    var id: String { model.benchmark.model }
    var name: String { ModelName.display(id) }
    var score: Double { model.benchmark.score }
    var tipID: String { "plan-\(id)" }

    func taskFigure(_ count: Double) -> String { Format.rough(count) + (hasUnpriced ? "+" : "") }

    var tip: StatsTip {
        let perDollar = model.tasksPerDollar.map {
            StatsTip.Row(label: "Tasks per $1", value: taskFigure($0), provider: provider)
        }
        return StatsTip(
            id: tipID, title: name,
            rows: [
                .init(label: "Intelligence Index score", value: "\(Int(score.rounded()))"),
                perDollar,
                .init(label: "Tasks per week", value: taskFigure(model.tasksPerWeek), provider: perDollar == nil ? provider : nil),
                .init(label: "Cost per task at API prices", value: String(format: "$%.2f", model.benchmark.cost)),
                .init(label: "Minutes per task", value: "\(Int(model.benchmark.minutes.rounded()))"),
                .init(label: "Your last 7 days", value: "\(Int((share * 100).rounded()))%"),
            ].compactMap { $0 },
            note: "A task is one job from the benchmark, not one of yours.")
    }
}

/// Every model of every plan, as a plain list for the exact numbers and a chart for the comparison.
private struct ModelComparison: View {
    let points: [ModelPoint]
    let unit: TaskUnit
    let palette: StatsPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Link(destination: ModelBenchmark.sourceURL) {
                HStack(spacing: 4) {
                    Text("Artificial Analysis Intelligence Index")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.ink2)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.ink)
            }
            .buttonStyle(.plain)
            .help("Open the Intelligence Index on artificialanalysis.ai")

            HStack(alignment: .top, spacing: 28) {
                ModelList(points: points, unit: unit, palette: palette).frame(width: 270)
                ModelChart(points: points, unit: unit, palette: palette)
                    .frame(maxWidth: .infinity)
                    .frame(height: 262)
            }
        }
    }
}

private struct ModelList: View {
    let points: [ModelPoint]
    let unit: TaskUnit
    let palette: StatsPalette
    @Environment(\.statsTipID) private var tipID

    private static let scoreWidth: CGFloat = 44
    private static let tasksWidth: CGFloat = 90

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Score").frame(width: Self.scoreWidth, alignment: .trailing)
                Text(unit.column).frame(width: Self.tasksWidth, alignment: .trailing)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(palette.ink2)
            .lineLimit(1)
            .padding(.bottom, 7)
            ForEach(points) { row($0) }
        }
    }

    private func row(_ p: ModelPoint) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(palette.faint).frame(height: 1)
            HStack(spacing: 0) {
                ProviderMark(provider: p.provider, palette: palette, hollow: !p.isUsed)
                    .frame(width: 8, height: 8)
                    .padding(.trailing, 8)
                Text(p.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text("\(Int(p.score.rounded()))").frame(width: Self.scoreWidth, alignment: .trailing)
                Text(p.taskFigure(p.tasks)).frame(width: Self.tasksWidth, alignment: .trailing)
            }
            .monospacedDigit()
            .frame(height: 29)
        }
        .font(.system(size: 12.5, weight: p.isUsed ? .medium : .regular))
        .foregroundStyle(p.isUsed ? palette.ink : palette.ink2)
        .opacity(tipID == nil || tipID == p.tipID ? 1 : 0.3)
        .statsTip(p.tip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(p.name): score \(Int(p.score.rounded())), \(p.taskFigure(p.tasks)) \(unit.spoken)")
    }
}

/// Score against tasks, one scale for every plan. Tasks are on a log scale, since they span a factor
/// of fifty. The list beside it says the same for VoiceOver.
private struct ModelChart: View {
    let points: [ModelPoint]
    let unit: TaskUnit
    let palette: StatsPalette
    @Environment(\.statsTipID) private var tipID

    private static let scores: ClosedRange<Double> = 20...60
    private static let inset = EdgeInsets(top: 18, leading: 24, bottom: 20, trailing: 8)

    /// Log10 of the tasks shown, with room on the left for a label beside the leftmost mark.
    private var decades: ClosedRange<Double> {
        let logs = points.map { log10($0.tasks) }
        return (logs.min() ?? 1) - 0.25 ... (logs.max() ?? 4) + 0.1
    }

    private var ticks: [Double] {
        let span = decades, width = span.upperBound - span.lowerBound
        return stride(from: floor(span.lowerBound), through: ceil(span.upperBound), by: 1).flatMap { power in
            [1.0, 2, 5].map { $0 * pow(10, power) }
        }
        .filter { (0.02...0.99).contains((log10($0) - span.lowerBound) / width) }
    }

    var body: some View {
        GeometryReader { g in
            let plot = CGRect(
                x: Self.inset.leading, y: Self.inset.top,
                width: g.size.width - Self.inset.leading - Self.inset.trailing,
                height: g.size.height - Self.inset.top - Self.inset.bottom)
            let scoreTicks = stride(from: Self.scores.lowerBound, through: Self.scores.upperBound, by: 10).map { $0 }

            Path { path in
                for score in scoreTicks {
                    let y = self.y(score, in: plot)
                    path.move(to: CGPoint(x: plot.minX, y: y))
                    path.addLine(to: CGPoint(x: plot.maxX, y: y))
                }
                for tick in ticks {
                    let x = self.x(tick, in: plot)
                    path.move(to: CGPoint(x: x, y: plot.minY))
                    path.addLine(to: CGPoint(x: x, y: plot.maxY))
                }
            }
            .stroke(palette.faint, lineWidth: 1)

            ForEach(scoreTicks, id: \.self) { score in
                Text("\(Int(score))")
                    .frame(width: 20, alignment: .trailing)
                    .position(x: plot.minX - 14, y: y(score, in: plot))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(palette.ink3)
            ForEach(ticks, id: \.self) { tick in
                // Ticks are round, so "5" rather than the "5.0" an estimate would show.
                Text(tick < 10 ? String(format: "%g", tick) : Format.rough(tick))
                    .position(x: x(tick, in: plot), y: plot.maxY + 11)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(palette.ink3)

            Text("Smarter ↑")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.ink2)
                .fixedSize()
                .position(x: plot.minX + 26, y: plot.minY - 10)
            Text("More \(unit.column.lowercased()) →")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.ink2)
                .fixedSize()
                .frame(width: 160, alignment: .trailing)
                .position(x: plot.maxX - 80, y: plot.minY - 10)

            let spots = placement(in: plot)
            ForEach(points) { p in
                let lit = tipID == nil || tipID == p.tipID
                let side: CGFloat = p.isUsed ? 9 : 8
                if let spot = spots[p.id] {
                    Text(p.name)
                        .font(.system(size: 12, weight: p.isUsed ? .medium : .regular))
                        .foregroundStyle(p.isUsed ? palette.ink : palette.ink2)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: spot.rect.width, alignment: spot.alignment)
                        .position(x: spot.rect.midX, y: spot.rect.midY)
                        .opacity(lit ? 1 : 0.3)
                }
                ProviderMark(provider: p.provider, palette: palette, hollow: !p.isUsed)
                    .frame(width: side, height: side)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .statsTip(p.tip)
                    .position(self.point(p, in: plot))
                    .opacity(lit ? 1 : 0.3)
            }
        }
        .accessibilityHidden(true)
    }

    private func x(_ tasks: Double, in plot: CGRect) -> CGFloat {
        let span = decades
        return plot.minX + plot.width * (log10(tasks) - span.lowerBound) / (span.upperBound - span.lowerBound)
    }

    private func y(_ score: Double, in plot: CGRect) -> CGFloat {
        plot.maxY - plot.height * (score - Self.scores.lowerBound) / (Self.scores.upperBound - Self.scores.lowerBound)
    }

    private func point(_ p: ModelPoint, in plot: CGRect) -> CGPoint {
        CGPoint(x: x(p.tasks, in: plot), y: y(p.score, in: plot))
    }

    private struct Spot {
        var rect: CGRect
        var alignment: Alignment
    }

    /// A label beside each mark, clear of the marks and of other labels. Models in use choose first.
    private func placement(in plot: CGRect) -> [String: Spot] {
        var taken = points.map { p -> CGRect in
            let at = point(p, in: plot)
            return CGRect(x: at.x - 6, y: at.y - 6, width: 12, height: 12)
        }
        var spots: [String: Spot] = [:]
        let order = points.sorted { ($0.isUsed ? 1 : 0, $0.score) > ($1.isUsed ? 1 : 0, $1.score) }
        for p in order {
            let at = point(p, in: plot)
            let width = CGFloat(p.name.count) * 6.6, height: CGFloat = 15, gap: CGFloat = 9
            let options = [
                Spot(rect: CGRect(x: at.x + gap, y: at.y - height / 2, width: width, height: height), alignment: .leading),
                Spot(rect: CGRect(x: at.x - gap - width, y: at.y - height / 2, width: width, height: height), alignment: .trailing),
                Spot(rect: CGRect(x: at.x - width / 2, y: at.y - gap - height, width: width, height: height), alignment: .center),
                Spot(rect: CGRect(x: at.x - width / 2, y: at.y + gap, width: width, height: height), alignment: .center),
            ].filter { plot.contains($0.rect) }
            guard let spot = options.first(where: { o in !taken.contains { $0.intersects(o.rect) } }) ?? options.first
            else { continue }
            spots[p.id] = spot
            taken.append(spot.rect)
        }
        return spots
    }
}

// MARK: Workings

/// How the figures come about, a click away so the page itself stays quiet. Not in the copied image.
private struct InfoButton: View {
    let plans: [PlanRow]
    let palette: StatsPalette
    @Environment(\.statsTip) private var interactive
    @State private var showing = false

    var body: some View {
        if interactive != nil {
            Button { showing.toggle() } label: {
                HStack(spacing: 4) {
                    Text("How this is worked out")
                    Image(systemName: "info.circle")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showing, arrowEdge: .top) {
                PlansWorkings(plans: plans)
            }
        }
    }
}

struct PlansWorkings: View {
    let plans: [PlanRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            note("A full week", fullWeek)
            note("Per $1", "A full week, multiplied by \(String(format: "%.2f", PlanValue.weeksPerMonth)) weeks a month and divided by the plan's US list price. It assumes you use your whole limit. A + means some of the use has no known API price.")
            note("Why it can be higher", "Use outside Claude Code and Codex takes up your limit but isn't logged. Going over a full week can follow an early reset.")
            note("Scores and tasks", "These come from the Artificial Analysis Intelligence Index at maximum effort, not your work. Tasks are API usage divided by the model's cost per task, which assumes your limit charges each model its API price. The chart's task axis is a log scale.")
            note("Best value", "The model with the most tasks among those within \(Int(PlanValue.bestValuePoints)) points of the top score on the benchmark. If tasks are close, the smarter model shows. It may not be a model you use.")
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private var fullWeek: String {
        let parts = plans.compactMap { plan -> String? in
            let v = plan.value, name = plan.id.displayName
            if v.windows > 1, let low = v.low, let high = v.high {
                return "\(name) is the middle of your last \(v.windows) weeks, \(Format.roughCost(low)) to \(Format.roughCost(high))."
            }
            guard let cost = v.measuredCost, let percent = v.measuredPercent else { return nil }
            if plan.accounts > 1 {
                return "\(name): \(Format.roughCost(cost)) took \(Int(percent))% of a weekly limit across its \(plan.accounts) accounts, which is multiplied up to all of them."
            }
            return "\(name): \(Format.roughCost(cost)) took \(Int(percent))% of the limit."
        }
        return (["Your logged cost at API prices, divided by the share of your weekly limit it took."] + parts).joined(separator: " ")
    }

    private func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
