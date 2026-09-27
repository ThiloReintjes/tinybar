import Charts
import SubarCore
import SwiftUI

struct PopoverView: View {
    let model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if showSettings {
                SettingsView(model: model, done: { showSettings = false })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.enabledProviders.isEmpty {
                            Text("No subscriptions detected. Sign in with `claude` or `codex login`, or turn on the browser fallback in Settings.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.enabledProviders, id: \.self) { id in
                            ProviderCard(model: model, id: id)
                        }
                        UsageSection(model: model)
                    }
                    .padding(14)
                }
                .frame(maxHeight: 620)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                Footer(model: model, openSettings: { showSettings = true })
            }
        }
        .frame(width: 340)
    }
}

// MARK: Provider card

private struct ProviderCard: View {
    let model: AppModel
    let id: ProviderID

    var body: some View {
        let state = model.providers[id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(id.displayName).font(.headline)
                if let plan = state?.snapshot?.plan {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                }
                if let source = state?.snapshot?.source, source != .cli {
                    Image(systemName: source == .browser ? "globe" : "terminal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(source == .browser ? "Read from your browser session" : "Read via the \(id.cliCommand) CLI")
                }
                Spacer()
                if let credits = state?.snapshot?.credits, credits.hasCredits, let balance = credits.balance {
                    Text("\(balance, format: .number.precision(.fractionLength(0))) credits")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let state, state.isStale {
                StaleLine(id: id, state: state)
            }

            if let windows = state?.snapshot?.windows, !windows.isEmpty {
                ForEach(windows) { window in
                    WindowRow(window: window, pinned: model.isPinned(id, window), dimmed: state?.isStale ?? false) {
                        model.pin(id, window)
                    }
                }
            } else if state?.snapshot == nil, state?.error == nil {
                ProgressView().controlSize(.small)
            }

            if let banked = state?.snapshot?.bankedResets?.filter(\.isAvailable), !banked.isEmpty {
                BankedResetsRow(resets: banked)
            }

            if let extra = state?.snapshot?.extraUsage {
                HStack {
                    Image(systemName: "creditcard")
                    Text("Extra usage")
                    Spacer()
                    Text(extra.formatted).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct StaleLine: View {
    let id: ProviderID
    let state: ProviderState

    var body: some View {
        let since = state.snapshot?.fetchedAt
        let hint: String = switch state.error {
        case .loginExpired, .notConfigured: "run `\(id.cliCommand)` once to refresh"
        case .rateLimited: "provider asked to slow down"
        default: state.error?.localizedDescription ?? ""
        }
        Label {
            Text(since.map { "Stale since \($0.formatted(date: .omitted, time: .shortened)) — \(hint)" } ?? hint.prefix(1).uppercased() + hint.dropFirst())
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(.orange)
    }
}

private struct WindowRow: View {
    let window: LimitWindow
    let pinned: Bool
    let dimmed: Bool
    let onPin: () -> Void

    var body: some View {
        Button(action: onPin) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.caption2)
                        .foregroundStyle(pinned ? Color.accentColor : Color.secondary.opacity(0.5))
                    Text(window.title).font(.subheadline)
                    Spacer()
                    Text("\(Int(window.remainingPercent.rounded()))% left")
                        .font(.subheadline.monospacedDigit())
                    if let resetsAt = window.resetsAt {
                        Text("· \(Format.countdown(to: resetsAt))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                RemainingBar(fraction: window.remainingPercent / 100)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.5 : 1)
        .help(pinned ? "Shown in the menu bar" : "Show in the menu bar")
    }
}

/// Fills with what is left: full at the start of a window, empty when the limit is reached.
private struct RemainingBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }

    private var color: Color {
        switch fraction {
        case ..<0.05: .red
        case ..<0.2: .orange
        default: .accentColor
        }
    }
}

private struct BankedResetsRow: View {
    let resets: [BankedReset]

    var body: some View {
        let nextExpiry = resets.compactMap(\.expiresAt).min()
        HStack {
            Image(systemName: "arrow.counterclockwise.circle")
            Text("\(resets.count) banked reset\(resets.count == 1 ? "" : "s")")
            Spacer()
            if let nextExpiry {
                Text("next expires \(nextExpiry.formatted(.dateTime.month(.abbreviated).day()))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .help(resets.map { "\($0.title ?? "Reset") — expires \($0.expiresAt?.formatted(date: .abbreviated, time: .omitted) ?? "never")" }.joined(separator: "\n"))
    }
}

// MARK: Usage section

private struct UsageSection: View {
    let model: AppModel
    @AppStorage("usageRange") private var rangeRaw = UsageRange.today.rawValue

    var body: some View {
        let range = UsageRange(rawValue: rangeRaw) ?? .today
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Usage").font(.headline)
                Spacer()
                Picker("", selection: $rangeRaw) {
                    ForEach(UsageRange.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            if let progress = model.importProgress {
                ProgressView(value: progress) {
                    Text("Importing history…").font(.caption).foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }

            if let summary = model.usage[range] {
                SummaryView(summary: summary, model: model)
            } else if model.importProgress == nil {
                Text("No local usage yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SummaryView: View {
    let summary: UsageSummary
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.tokens(summary.totalTokens)).font(.title2.monospacedDigit().weight(.semibold))
                Text("tokens").foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Format.cost(summary.cost)).font(.title3.monospacedDigit())
                    Text(summary.range == .today ? "API-equivalent · provisional" : "API-equivalent")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if summary.range != .today, !summary.days.isEmpty {
                Chart(summary.days) { bar in
                    BarMark(
                        x: .value("Day", DayKeyDate.date(bar.day), unit: .day),
                        y: .value("Tokens", bar.tokens))
                        .foregroundStyle(by: .value("Provider", bar.provider.displayName))
                }
                .chartForegroundStyleScale(domain: ProviderID.allCases.map(\.displayName), range: ProviderID.allCases.map(\.color))
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine()
                        AxisValueLabel { Text(Format.tokens(value.as(Int64.self) ?? 0)) }
                    }
                }
                .frame(height: 90)
            }

            ProviderFilter(model: model)

            BreakdownList(title: "Models", lines: summary.models)
            BreakdownList(title: "Projects", lines: summary.projects)
        }
    }
}

/// The chart legend, doubling as the filter: click a Provider to show only it, click it again
/// (or "All") to show everything.
private struct ProviderFilter: View {
    let model: AppModel

    var body: some View {
        if model.usageProviders.count > 1 || model.usageFilter != nil {
            HStack(spacing: 6) {
                chip("All", color: nil, selected: model.usageFilter == nil) { model.usageFilter = nil }
                ForEach(model.usageProviders, id: \.self) { id in
                    chip(id.displayName, color: id.color, selected: model.usageFilter == id) {
                        model.usageFilter = model.usageFilter == id ? nil : id
                    }
                }
                Spacer()
            }
        }
    }

    private func chip(_ title: String, color: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                Text(title)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: selected ? 0 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
    }
}

private struct BreakdownList: View {
    let title: String
    let lines: [UsageSummary.Line]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(lines.prefix(5)) { line in
                    HStack {
                        Text(line.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Format.tokens(line.tokens)).foregroundStyle(.secondary)
                        Text(Format.cost(line.cost)).frame(width: 64, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }
}

enum DayKeyDate {
    static func date(_ key: String) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date() }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
    }
}

// MARK: Footer

private struct Footer: View {
    let model: AppModel
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let updated = model.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh(force: false, throttle: AppModel.openThrottle) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)
            .help("Refresh")
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit Subar")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: Settings

private struct SettingsView: View {
    let model: AppModel
    let done: () -> Void

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: done) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("Settings").font(.headline)
                Spacer()
            }
            Form {
                Section("Providers") {
                    ForEach(ProviderID.allCases, id: \.self) { id in
                        Toggle(id.displayName, isOn: Binding(
                            get: { model.providers[id] != nil },
                            set: { model.setEnabled(id, $0) }))
                    }
                }
                Section {
                    let _ = settings.browserFallbackRevision
                    ForEach(ProviderID.allCases, id: \.self) { id in
                        Toggle("\(id.displayName) (\(id.webDomain))", isOn: Binding(
                            get: { settings.isBrowserFallbackEnabled(id) },
                            set: {
                                settings.setBrowserFallback(id, $0)
                                if $0 { Task { await model.refresh(force: true) } }
                            }))
                    }
                } header: {
                    Text("Browser fallback")
                } footer: {
                    Text("If a CLI login is missing or expired, read your signed-in browser session instead. Chromium browsers ask once for Keychain access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("General") {
                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    Toggle("Limit notifications", isOn: $settings.notificationsEnabled)
                    Toggle("Hide percentage in menu bar", isOn: $settings.hidePercentage)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}

extension ProviderID {
    var webDomain: String {
        switch self {
        case .claude: "claude.ai"
        case .codex: "chatgpt.com"
        }
    }

    var color: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: .accentColor
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
