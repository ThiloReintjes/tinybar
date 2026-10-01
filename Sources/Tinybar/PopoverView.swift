import TinybarCore
import SwiftUI

/// Where the popover is. Every page is one click from every other through the tab bar.
enum Page: Hashable {
    case overview
    case provider(ProviderID)
    case settings
}

/// The pages sit side by side on one strip that slides under a fixed window. Switching tabs moves
/// the strip; nothing is rebuilt and the popover never changes size, so nothing jumps.
struct PopoverView: View {
    let model: AppModel
    @State private var page: Page
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 344
    /// Fixed so the popover keeps its size (and its arrow its place) across pages. Longer pages
    /// scroll inside it.
    static let contentHeight: CGFloat = 540

    init(model: AppModel, page: Page = .overview) {
        self.model = model
        _page = State(initialValue: page)
    }

    private var pages: [Page] {
        [.overview] + model.enabledProviders.map(Page.provider) + [.settings]
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                TabBar(model: model, page: page, select: go)
                    .opacity(page == .settings ? 0 : 1)
                    .allowsHitTesting(page != .settings)
                SettingsHeader { go(.overview) }
                    .opacity(page == .settings ? 1 : 0)
                    .allowsHitTesting(page == .settings)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            HStack(alignment: .top, spacing: 0) {
                ForEach(pages, id: \.self) { p in
                    ScrollView {
                        content(p)
                            .padding(.horizontal, 14)
                            .padding(.top, 6)
                            .padding(.bottom, 12)
                    }
                    .scrollIndicators(.never)
                    .frame(width: Self.width, height: Self.contentHeight)
                    .accessibilityHidden(p != page)
                }
            }
            .frame(width: Self.width, alignment: .leading)
            .offset(x: -CGFloat(pages.firstIndex(of: page) ?? 0) * Self.width)
            .clipped()
            .mask(ScrollEdgeFade())

            Footer(model: model, page: page, select: go)
        }
        .frame(width: Self.width)
        .background(GlassTint())
        .background(TabShortcuts(model: model, select: go))
        .onChange(of: model.enabledProviders) { _, enabled in
            if case let .provider(id) = page, !enabled.contains(id) { page = .overview }
        }
    }

    @ViewBuilder
    private func content(_ p: Page) -> some View {
        switch p {
        case .overview: OverviewPage(model: model, open: { go(.provider($0)) })
        case let .provider(id): ProviderPage(model: model, id: id)
        case .settings: SettingsPage(model: model)
        }
    }

    private func go(_ next: Page) {
        guard next != page else { return }
        withAnimation(reduceMotion ? nil : Motion.page) { page = next }
    }
}

/// Tints the popover's glass towards the window background. The glass alone passes through
/// whatever is behind it, so a light window under a dark popover left secondary text grey on
/// grey. The tint caps how far the backdrop can drift from the appearance while some of it still
/// shows through. Reduce Transparency already makes the glass opaque, so the tint steps aside.
private struct GlassTint: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .opacity(reduceTransparency ? 0 : 0.7)
            .ignoresSafeArea()
    }
}

/// Content softens into the chrome above and below instead of meeting a hard edge.
private struct ScrollEdgeFade: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 6)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14)
        }
    }
}

// MARK: Tab bar

/// A single glass capsule: Overview plus one tab per subscription. The selection is a lens that
/// slides between tabs.
private struct TabBar: View {
    let model: AppModel
    let page: Page
    let select: (Page) -> Void
    @Namespace private var lens

    var body: some View {
        HStack(spacing: 2) {
            tab(.overview) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18)
                    .accessibilityLabel("Overview")
            }
            ForEach(model.enabledProviders, id: \.self) { id in
                tab(.provider(id)) {
                    HStack(spacing: 5) {
                        ProviderDot(id: id)
                            .opacity(model.providers[id]?.isStale == true ? 0.35 : 1)
                        Text(id.displayName)
                    }
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }

    private func tab(_ target: Page, @ViewBuilder label: () -> some View) -> some View {
        let selected = page == target
        return Button { select(target) } label: {
            label()
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 9)
                .frame(maxWidth: target == .overview ? nil : .infinity, minHeight: 26)
                .background {
                    if selected {
                        Capsule()
                            .fill(.background.opacity(0.9))
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                            .matchedGeometryEffect(id: "lens", in: lens)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Instant feedback on press, before the click commits.
private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// 0 for Overview, 1–4 for the subscriptions, and ← → to step through them.
private struct TabShortcuts: View {
    let model: AppModel
    let select: (Page) -> Void

    var body: some View {
        let pages = [Page.overview] + model.enabledProviders.map { Page.provider($0) }
        ZStack {
            ForEach(Array(pages.enumerated()), id: \.offset) { i, page in
                Button("") { select(page) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i))), modifiers: [])
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

private struct SettingsHeader: View {
    let back: () -> Void

    var body: some View {
        HStack {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .background(Circle().fill(.primary.opacity(0.06)))
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Back")
            Spacer()
            Text("Settings").font(.system(size: 13, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 26, height: 26)
        }
        .frame(height: 32)
    }
}

// MARK: Overview

private struct OverviewPage: View {
    let model: AppModel
    let open: (ProviderID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.enabledProviders.isEmpty {
                EmptyState()
            } else {
                VStack(spacing: 0) {
                    ForEach(model.enabledProviders, id: \.self) { id in
                        Button { open(id) } label: { OverviewRow(model: model, id: id) }
                            .buttonStyle(RowButtonStyle())
                        if id != model.enabledProviders.last {
                            Divider().padding(.leading, 64).padding(.trailing, 12).opacity(0.5)
                        }
                    }
                }
                .platter(cornerRadius: 16)
            }
            UsagePanel(model: model, summaries: model.usage)
        }
    }
}

/// One subscription at a glance: its rings, the limit closest to running out and when that
/// resets. The whole row opens the detail page.
private struct OverviewRow: View {
    let model: AppModel
    let id: ProviderID

    var body: some View {
        let state = model.providers[id]
        let snapshot = state?.snapshot
        let binding = snapshot?.bindingWindow
        let stale = state?.isStale ?? false

        HStack(spacing: 12) {
            LimitRings(windows: snapshot?.ringWindows ?? [], provider: id, lineWidth: 4, gap: 1.5, dimmed: stale)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(id.displayName).font(.system(size: 14, weight: .semibold))
                    if let plan = snapshot?.plan {
                        Text(plan).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if model.pinned?.0 == id {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Shown in the menu bar")
                    }
                }
                subtitle(state: state, binding: binding)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let binding {
                PercentText(percent: binding.remainingPercent, size: 20)
                    .opacity(stale ? 0.5 : 1)
            } else if state?.error == nil {
                ProgressView().controlSize(.small)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func subtitle(state: ProviderState?, binding: LimitWindow?) -> some View {
        if let error = state?.error {
            Label(StaleText.short(id: id, error: error), systemImage: "exclamationmark.triangle.fill")
                .labelStyle(TightLabel())
                .foregroundStyle(.orange)
        } else if let binding {
            Text(ResetText.short(binding)).foregroundStyle(.secondary)
        } else if state?.snapshot != nil {
            Text("No limits reported").foregroundStyle(.secondary)
        } else {
            Text("Checking…").foregroundStyle(.secondary)
        }
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10))
            configuration.title
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            LimitRings(windows: [], provider: nil, lineWidth: 5)
                .frame(width: 44, height: 44)
            Text("No subscriptions found").font(.system(size: 13, weight: .semibold))
            Text("Sign in with `claude`, `codex` or `agy`, or open Cursor. Tinybar picks them up on its next check.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .platter(cornerRadius: 16)
    }
}

enum StaleText {
    static func short(id: ProviderID, error: ProviderError) -> String {
        switch error {
        case .loginExpired, .notConfigured: "Login expired"
        case .rateLimited: "Paused, provider asked to slow down"
        case .network: "Offline"
        case .unexpected: "Couldn't read limits"
        }
    }

    static func long(id: ProviderID, error: ProviderError) -> String {
        switch error {
        case .loginExpired, .notConfigured:
            "Login expired. To refresh it, \(id.loginHint.replacingOccurrences(of: " once to refresh", with: " once"))."
        case .rateLimited: "\(id.displayName) asked Tinybar to slow down. It tries again on the next check."
        case let .network(message): "Couldn't reach \(id.displayName): \(message)"
        case let .unexpected(message): message
        }
    }
}

// MARK: Provider detail

private struct ProviderPage: View {
    let model: AppModel
    let id: ProviderID

    var body: some View {
        let state = model.providers[id]
        let snapshot = state?.snapshot
        let stale = state?.isStale ?? false

        VStack(alignment: .leading, spacing: 14) {
            Hero(id: id, state: state)

            if let error = state?.error {
                StaleBanner(id: id, error: error, since: snapshot?.fetchedAt)
            }

            if let windows = snapshot?.windows, !windows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(windows) { window in
                        WindowRow(
                            window: window, provider: id,
                            pinned: model.isPinned(id, window), dimmed: stale
                        ) { model.pin(id, window) }
                        if window.id != windows.last?.id {
                            Divider().padding(.horizontal, 14).opacity(0.5)
                        }
                    }
                }
                .platter(cornerRadius: 16)
            }

            if let snapshot, snapshot.hasExtras {
                Extras(snapshot: snapshot)
            }

            if let summaries = model.providerUsage[id] {
                UsagePanel(model: model, summaries: summaries)
            }
        }
    }
}

/// The detail page's one large element: the rings, with the tightest limit set beside them.
private struct Hero: View {
    let id: ProviderID
    let state: ProviderState?

    var body: some View {
        let snapshot = state?.snapshot
        let binding = snapshot?.bindingWindow
        HStack(spacing: 16) {
            ZStack {
                LimitRings(
                    windows: snapshot?.ringWindows ?? [], provider: id,
                    lineWidth: 9, gap: 3, dimmed: state?.isStale ?? false)
                if let binding {
                    PercentText(percent: binding.remainingPercent, size: 17)
                }
            }
            .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 3) {
                Text(id.displayName)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .tracking(-0.4)
                if let plan = snapshot?.plan {
                    Text(plan).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

private struct StaleBanner: View {
    let id: ProviderID
    let error: ProviderError
    let since: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(StaleText.long(id: id, error: error))
                    .fixedSize(horizontal: false, vertical: true)
                if let since {
                    Text("Showing the numbers from \(since.formatted(date: .omitted, time: .shortened)).")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// One Limit Window. Clicking it pins it to the menu bar.
private struct WindowRow: View {
    let window: LimitWindow
    let provider: ProviderID
    let pinned: Bool
    let dimmed: Bool
    let onPin: () -> Void

    var body: some View {
        Button(action: onPin) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(window.title).font(.system(size: 13, weight: .medium))
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(pinned ? AnyShapeStyle(provider.color) : AnyShapeStyle(.quaternary))
                    Spacer()
                    PercentText(percent: window.remainingPercent, size: 17)
                }
                RemainingBar(fraction: window.remainingPercent / 100, provider: provider)
                if let resetsAt = window.resetsAt {
                    Text(ResetText.long(resetsAt))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .opacity(dimmed ? 0.55 : 1)
        .help(pinned ? "Shown in the menu bar" : "Click to show in the menu bar")
        .accessibilityHint(pinned ? "Shown in the menu bar" : "Shows this limit in the menu bar")
    }
}

extension ProviderSnapshot {
    var hasExtras: Bool {
        extraUsage != nil
            || credits?.hasCredits == true
            || bankedResets?.contains(where: \.isAvailable) == true
    }
}

/// Everything beyond the windows: credits, banked resets, pay-as-you-go spend.
private struct Extras: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        VStack(spacing: 0) {
            if let credits = snapshot.credits, credits.hasCredits {
                line("Credits", icon: "circle.hexagongrid", value: credits.unlimited
                    ? "Unlimited"
                    : credits.balance.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—")
            }
            if let banked = snapshot.bankedResets?.filter(\.isAvailable), !banked.isEmpty {
                let next = banked.compactMap(\.expiresAt).min()
                line(
                    "\(banked.count) banked reset\(banked.count == 1 ? "" : "s")",
                    icon: "arrow.counterclockwise",
                    value: next.map { "next expires \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "")
            }
            if let extra = snapshot.extraUsage {
                line(snapshot.provider == .cursor ? "On-demand spend" : "Extra usage", icon: "creditcard", value: extra.formatted)
            }
        }
        .padding(.vertical, 4)
        .platter(cornerRadius: 16)
    }

    private func line(_ title: String, icon: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(snapshot.provider.color)
                .frame(width: 16)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

// MARK: Usage

/// Tokens, Theoretical Cost, top models and projects over a range. The overview shows all
/// subscriptions stacked; a detail page shows only its own.
private struct UsagePanel: View {
    let model: AppModel
    let summaries: [UsageRange: UsageSummary]
    @AppStorage("usageRange") private var rangeRaw = UsageRange.week.rawValue

    var body: some View {
        let range = UsageRange(rawValue: rangeRaw) ?? .week
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("Usage").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("Range", selection: $rangeRaw) {
                    ForEach(UsageRange.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 140)
            }
            .padding(.horizontal, 4)

            if let progress = model.importProgress {
                ProgressView(value: progress) {
                    Text("Reading your history…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .controlSize(.small)
                .padding(.horizontal, 4)
            }

            if let summary = summaries[range] {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Format.tokens(summary.totalTokens))
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .tracking(-0.5)
                                .monospacedDigit()
                            Text("tokens").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Format.cost(summary.cost))
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .tracking(-0.5)
                                .monospacedDigit()
                            Text(range == .today ? "at API prices, so far today" : "at API prices")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if range != .today, !summary.days.isEmpty {
                        UsageBars(days: summary.days, range: range)
                            .frame(height: 80)
                    }
                    Breakdown(title: "Models", lines: summary.models, total: summary.totalTokens)
                    Breakdown(
                        title: "Projects", lines: PopoverSnapshotOptions.projects(summary.projects),
                        total: summary.totalTokens)
                }
                .padding(14)
                .platter(cornerRadius: 16)
            } else if model.importProgress == nil {
                Text("Nothing used yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: Footer

private struct Footer: View {
    let model: AppModel
    let page: Page
    let select: (Page) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if model.isRefreshing {
                    Text("Checking…")
                } else if let updated = model.lastUpdated {
                    Text("Checked \(updated.formatted(date: .omitted, time: .shortened))")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            Spacer()
            FooterButton(icon: "arrow.clockwise", label: "Check now") {
                Task { await model.refresh(force: false, throttle: AppModel.openThrottle) }
            }
            .disabled(model.isRefreshing)
            .keyboardShortcut("r")
            FooterButton(icon: "gearshape", label: "Settings") {
                select(page == .settings ? .overview : .settings)
            }
            .keyboardShortcut(",")
            FooterButton(icon: "power", label: "Quit Tinybar") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct FooterButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: Settings

private struct SettingsPage: View {
    let model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Subscriptions") {
                ForEach(ProviderID.allCases, id: \.self) { id in
                    SettingsToggle(isOn: Binding(
                        get: { model.providers[id] != nil },
                        set: { model.setEnabled(id, $0) }),
                        first: id == ProviderID.allCases.first)
                    {
                        HStack(spacing: 8) {
                            ProviderDot(id: id, size: 7)
                            Text(id.displayName)
                        }
                    }
                }
            }
            SettingsSection(
                "Browser fallback",
                footer: "When a CLI login is missing or expired, read your signed-in browser session instead. Chromium browsers ask once for Keychain access.")
            {
                let _ = settings.browserFallbackRevision
                let ids = ProviderID.allCases.filter(\.hasBrowserFallback)
                ForEach(ids, id: \.self) { id in
                    SettingsToggle(isOn: Binding(
                        get: { settings.isBrowserFallbackEnabled(id) },
                        set: {
                            settings.setBrowserFallback(id, $0)
                            if $0 { Task { await model.refresh(force: true) } }
                        }),
                        first: id == ids.first)
                    {
                        Text("\(id.displayName) via \(id.webDomain)")
                    }
                }
            }
            SettingsSection("General") {
                SettingsToggle(isOn: $settings.launchAtLogin, first: true) { Text("Launch at login") }
                SettingsToggle(isOn: $settings.notificationsEnabled) { Text("Notify when a limit is nearly used up") }
                SettingsToggle(isOn: Binding(
                    get: { !settings.hidePercentage }, set: { settings.hidePercentage = !$0 }))
                {
                    Text("Show percentage in menu bar")
                }
            }
        }
        .padding(.top, 4)
    }
}

/// A titled platter of rows, like the limit cards. Drawn by hand
/// rather than with a grouped `Form`, whose section backgrounds mis-measure in the fixed-size
/// popover and leave the last row outside its card.
private struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .platter()
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A row with a hairline above it, except the first in its section.
private struct SettingsToggle<Label: View>: View {
    @Binding var isOn: Bool
    var first = false
    @ViewBuilder let label: Label

    var body: some View {
        VStack(spacing: 0) {
            if !first { Divider().padding(.leading, 14) }
            HStack {
                label.font(.system(size: 13))
                Spacer(minLength: 8)
                Toggle(isOn: $isOn) { label }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}
