import AppKit
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
        // The hosting controller initially gives the window a zero-sized frame. Establish its
        // content size, then measure again with the title bar's safe area before positioning it.
        window.setContentSize(host.view.fittingSize)
        host.view.layoutSubtreeIfNeeded()
        window.setContentSize(host.view.fittingSize)
        window.center()
        window.setFrameAutosaveName("Stats")
        // Recover positions saved by the old zero-sized layout or a disconnected display.
        if let screen = window.screen, !screen.visibleFrame.contains(window.frame) {
            window.center()
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // AppKit may retain the closed window. Free the name so the next one can restore it.
        window?.setFrameAutosaveName("")
        // Drop the SwiftUI tree with the window; the next open builds it fresh.
        window?.contentViewController = nil
        window = nil
    }
}

/// The Stats window's cards: the overview, and a closer look at one kind of activity each.
enum StatsPage: String, CaseIterable, Identifiable {
    case overview, commands, models, languages, plans

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .commands: "Commands"
        case .models: "Models"
        case .languages: "Languages"
        case .plans: "Plans"
        }
    }
}

/// Window chrome around the card: the pages, the range picker and the copy button sit in the title
/// bar row, outside what gets copied.
struct StatsView: View {
    let model: AppModel
    @AppStorage("statsRange") private var rangeRaw = StatsRange.month.rawValue
    @AppStorage("statsPage") private var pageRaw = StatsPage.overview.rawValue
    /// The one model the card is filtered to, if any. Not remembered: the window opens on all models.
    @State private var picked: String?
    @State private var summary: StatsSummary?
    @State private var summaryRevision = 0
    @State private var loadFailed = false
    @State private var copied = false
    /// Which way the last page change went, so the new card comes in from that side.
    @State private var forward = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, picked: String? = nil) {
        self.model = model
        _picked = State(initialValue: picked)
    }

    private var range: StatsRange { StatsRange(rawValue: rangeRaw) ?? .month }
    private var page: StatsPage { StatsPage(rawValue: pageRaw) ?? .overview }

    var body: some View {
        let palette = StatsPalette(scheme)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PageTabs(page: page, palette: palette, select: show)
                Spacer()
                Picker("Range", selection: $rangeRaw) {
                    ForEach(StatsRange.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                // Plans are about the current week, whatever the range.
                .opacity(page == .plans ? 0 : 1)
                .disabled(page == .plans)
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy image", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 96)
                }
                .disabled(summary.map { $0.isEmpty && page != .plans } ?? true)
                .keyboardShortcut("c")
                .help("Copy this card as an image, ready to paste")
            }
            // Clear of the window buttons.
            .padding(.leading, 84)
            .padding(.trailing, 20)
            .frame(height: 52)

            StatsCard(summary: summary, importing: model.importProgress, palette: palette, page: page, plans: model.plans,
                      forward: forward, loadFailed: loadFailed, summaryRevision: summaryRevision) { name in
                picked = picked == name ? nil : name
            }
        }
        .background(palette.canvas)
        // AppStorage can deliver an update outside the button action's transaction. Tie motion
        // to the rendered selection so clicks, shortcuts and preference updates animate alike.
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35), value: page)
        .onExitCommand { picked = nil }
        .task(id: "\(rangeRaw)|\(picked ?? "")|\(model.lastUpdated?.timeIntervalSince1970 ?? 0)|\(model.isRefreshing)") {
            guard !model.isRefreshing else { return }
            let next = await model.statsSummary(range, model: picked)
            guard !Task.isCancelled else { return }
            guard let next else { loadFailed = true; return }
            loadFailed = false
            // A model not used in the new range has nothing to show: fall back to all models.
            if let p = picked, !next.models.contains(where: { $0.name == p }) {
                picked = nil
                return
            }
            // Everything stays in place and the figures move to their new values.
            withAnimation(summary == nil || reduceMotion ? nil : .smooth(duration: 0.35)) {
                summary = next
                summaryRevision += 1
            }
        }
    }

    private func show(_ next: StatsPage) {
        guard next != page else { return }
        let all = StatsPage.allCases
        forward = all.firstIndex(of: next)! > all.firstIndex(of: page)!
        // A turn later, so the card leaving already knows which way to go.
        DispatchQueue.main.async {
            pageRaw = next.rawValue
        }
    }

    private func copy() {
        guard let summary, let image = StatsCard.image(summary, page: page, plans: model.plans, scheme: scheme) else { return }
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
    /// Hover details float on this, a step above the canvas.
    let raised: Color
    let ink: Color
    let ink2: Color
    let ink3: Color
    let faint: Color
    let claude: Color

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            canvas = Color(red: 0.11, green: 0.11, blue: 0.12)
            raised = Color(red: 0.17, green: 0.17, blue: 0.18)
            ink = Color(white: 0.96)
            claude = Color(red: 0.91, green: 0.53, blue: 0.40)
        } else {
            canvas = .white
            raised = .white
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

/// The shareable composition: one giant number, then the facts that explain it. In the window,
/// pointing at a piece shows its details and clicking a model filters to it; the copied image
/// has neither.
struct StatsCard: View {
    let summary: StatsSummary?
    let importing: Double?
    let palette: StatsPalette
    var page: StatsPage = .overview
    var plans: [PlanRow] = []
    /// The page came after the previous one: it enters from the right.
    var forward = true
    var loadFailed = false
    var summaryRevision = 0
    /// Filters to a model, or back to all. Nil for the copied image, which is not interactive.
    var pick: ((String) -> Void)?
    @State private var tip: StatsTip?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 960, height: 600)
    nonisolated static let space = "statsCard"
    /// Developer snapshots: a point in the card treated as pointed at (`--snapshot --hover x,y`).
    nonisolated(unsafe) static var snapshotHover: CGPoint?
    static let snapshotHoverNotification = Notification.Name("TinybarStatsSnapshotHover")

    var body: some View {
        ZStack {
            // Plans don't depend on the range, which an empty summary would strand you in.
            if let summary, !summary.isEmpty || page == .plans {
                content(summary)
            } else if let importing {
                VStack(spacing: 10) {
                    Text("Counting your history…").font(.system(size: 15, weight: .medium))
                    ProgressView(value: importing).frame(width: 220)
                }
                .foregroundStyle(palette.ink2)
            } else if loadFailed {
                VStack(spacing: 6) {
                    Text("Couldn't load stats").font(.system(size: 17, weight: .semibold))
                    Text("Try again after the next refresh.")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.ink2)
                }
                .foregroundStyle(palette.ink)
            } else if summary != nil {
                VStack(spacing: 6) {
                    Text("Nothing to count yet").font(.system(size: 17, weight: .semibold))
                    Text("Stats come from Claude Code and Codex logs. Run a session and they show up here.")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.ink2)
                }
                .foregroundStyle(palette.ink)
            } else {
                Text("Loading stats…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.ink2)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(palette.canvas)
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .top) {
            if loadFailed, summary?.isEmpty == false {
                Text("Couldn't update stats. Showing the last loaded numbers.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink2)
                    .padding(.top, 5)
            }
        }
        .overlay {
            if let tip {
                TipLayout(anchor: tip.anchor, beside: tip.beside) { TipView(tip: tip, palette: palette) }
                    .allowsHitTesting(false)
            }
        }
        .environment(\.statsTip, pick == nil ? nil : TipSink { new in
            if tip != new { tip = new }
        })
        .environment(\.statsTipID, tip?.id)
        .environment(\.statsPick, pick.map { pick in { name in tip = nil; pick(name) } })
        .onChange(of: summaryRevision) { tip = nil }
        .onChange(of: page) { tip = nil }
    }

    private func content(_ s: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(summary: s, page: page, palette: palette)
            ZStack(alignment: .topLeading) {
                Group {
                    switch page {
                    case .overview: overview(s)
                    case .commands: CommandsPage(summary: s, palette: palette).padding(.top, 18)
                    case .models: ModelsPage(summary: s, palette: palette).padding(.top, 22)
                    case .languages: LanguagesPage(summary: s, palette: palette).padding(.top, 18)
                    case .plans: PlansPage(plans: plans, palette: palette).padding(.top, 18)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(page)
                .transition(pageTransition)
            }
            .clipped()
        }
        .padding(.horizontal, 36)
        .padding(.top, 26)
        .padding(.bottom, 26)
        .foregroundStyle(palette.ink)
    }

    /// The next page slides in from the side it sits on in the tabs, the old one out the other way.
    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let shift: CGFloat = forward ? 36 : -36
        return .asymmetric(
            insertion: .offset(x: shift).combined(with: .opacity),
            removal: .offset(x: -shift).combined(with: .opacity))
    }

    private func overview(_ s: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 44) {
                VStack(alignment: .leading, spacing: 0) {
                    TokensHero(summary: s, palette: palette)
                    Bars(summary: s, palette: palette)
                        .padding(.top, 20)
                    Quartet(summary: s, palette: palette)
                        .padding(.top, 22)
                }
                .frame(width: TokensHero.width, alignment: .leading)
                VStack(alignment: .leading, spacing: 22) {
                    HeatMap(summary: s, palette: palette)
                    ToolBars(tools: s.tools, palette: palette)
                    ModelTable(summary: s, palette: palette)
                }
                .frame(width: 300, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
            Spacer(minLength: 0)
            Facts(summary: s, palette: palette)
        }
    }

    /// The card as an image at twice its size, for the clipboard.
    @MainActor
    static func image(_ summary: StatsSummary, page: StatsPage = .overview, plans: [PlanRow] = [], scheme: ColorScheme) -> NSImage? {
        let renderer = ImageRenderer(content: StatsCard(summary: summary, importing: nil, palette: StatsPalette(scheme), page: page, plans: plans)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        return renderer.nsImage
    }
}

// MARK: Hover details

/// What pointing at a piece of the card shows: a title, figures, and a plain-words definition.
struct StatsTip: Equatable {
    struct Row: Equatable {
        var label: String
        var value: String
        var provider: ProviderID?
    }

    /// Which piece it belongs to, so that piece can light up.
    var id: String
    var title: String
    var rows: [Row] = []
    var note: String?
    /// What the tip points at, in the card's coordinates.
    var anchor: CGRect = .zero
    /// Beside rather than above, for small targets packed together (heat map cells), so the tip
    /// doesn't cover their neighbours.
    var beside = false
}

struct TipSink {
    let set: (StatsTip?) -> Void
    init(_ set: @escaping (StatsTip?) -> Void) { self.set = set }
}

extension EnvironmentValues {
    @Entry var statsTip: TipSink?
    @Entry var statsTipID: String?
    @Entry var statsPick: ((String) -> Void)?
}

extension View {
    /// Shows a tip while the pointer is over this view. `make` gets the pointer and the view's size,
    /// and returns the tip anchored in the view's own coordinates (nil for none).
    func statsTip(_ make: @escaping (CGPoint, CGSize) -> StatsTip?) -> some View {
        modifier(TipArea(make: make))
    }

    /// A tip for the whole view.
    func statsTip(_ tip: @autoclosure @escaping () -> StatsTip) -> some View {
        statsTip { _, size in
            var t = tip()
            t.anchor = CGRect(origin: .zero, size: size)
            return t
        }
    }
}

private struct TipArea: ViewModifier {
    @Environment(\.statsTip) private var sink
    @State private var frame: CGRect = .zero
    let make: (CGPoint, CGSize) -> StatsTip?

    func body(content: Content) -> some View {
        if let sink {
            content
                .contentShape(Rectangle())
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(StatsCard.space)) } action: { frame = $0 }
                .onReceive(NotificationCenter.default.publisher(for: StatsCard.snapshotHoverNotification)) { _ in
                    if let p = StatsCard.snapshotHover, frame.contains(p) { point(at: p, sink) }
                }
                .onContinuousHover(coordinateSpace: .named(StatsCard.space)) { phase in
                    switch phase {
                    case let .active(p): point(at: p, sink)
                    case .ended: sink.set(nil)
                    }
                }
        } else {
            content
        }
    }

    /// `p` is in the card's coordinates.
    private func point(at p: CGPoint, _ sink: TipSink) {
        let tip = make(CGPoint(x: p.x - frame.minX, y: p.y - frame.minY), frame.size).map { t in
            var t = t
            t.anchor = t.anchor.offsetBy(dx: frame.minX, dy: frame.minY)
            return t
        }
        sink.set(tip)
    }
}

/// Places the tip above what it points at, or below when there's no room; or, `beside` it, to the
/// left or right. Always inside the card.
private struct TipLayout: Layout {
    var anchor: CGRect
    var beside: Bool
    static let width: CGFloat = 250
    static let margin: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tip = subviews.first else { return }
        let size = tip.sizeThatFits(ProposedViewSize(width: Self.width, height: nil))
        let m = Self.margin
        var x: CGFloat, y: CGFloat
        if beside {
            x = anchor.minX - size.width - m * 1.5
            if x < m { x = anchor.maxX + m * 1.5 }
            y = anchor.midY - size.height / 2
        } else {
            x = anchor.midX - size.width / 2
            y = anchor.minY - size.height - m
            if y < m { y = anchor.maxY + m }
        }
        x = min(max(x, m), bounds.width - size.width - m)
        y = min(max(y, m), bounds.height - size.height - m)
        tip.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
    }
}

private struct TipView: View {
    let tip: StatsTip
    let palette: StatsPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tip.title).font(.system(size: 12, weight: .semibold))
            if !tip.rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    ForEach(Array(tip.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            HStack(spacing: 5) {
                                if let p = row.provider {
                                    Circle().fill(palette.color(p)).frame(width: 6, height: 6)
                                }
                                Text(row.label)
                            }
                            .foregroundStyle(palette.ink2)
                            Text(row.value)
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            if let note = tip.note {
                Text(note)
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.raised)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(palette.ink.opacity(0.1), lineWidth: 0.5)
        }
    }
}

// MARK: Pieces

private struct Header: View {
    let summary: StatsSummary
    let page: StatsPage
    let palette: StatsPalette

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Mark(palette: palette).frame(width: 22, height: 22)
            Text("Tinybar").font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.ink)
            // The copied image says which card it is; the overview is just Tinybar.
            if page != .overview {
                Text(page.title).font(.system(size: 17, weight: .regular)).foregroundStyle(palette.ink3)
                    .transition(.opacity)
            }
            Spacer()
            Text(page == .plans ? "Benchmark from \(ModelBenchmark.asOf)" : StatsText.span(summary))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.ink2)
        }
    }
}

/// The app icon's two rings, drawn in vector: the same in the window and in a copied image. Strokes
/// scale with the frame.
private struct Mark: View {
    let palette: StatsPalette

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let line = side * 0.16
            ZStack {
                ring(0.74, Color(red: 0.91, green: 0.45, blue: 0.27), line: line, inset: 0)
                ring(0.42, Color(red: 0.25, green: 0.53, blue: 0.94), line: line, inset: side * 0.27)
            }
            .frame(width: side, height: side)
        }
    }

    private func ring(_ fraction: Double, _ color: Color, line: CGFloat, inset: CGFloat) -> some View {
        ZStack {
            Circle().stroke(palette.faint, lineWidth: line)
            Circle().trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(inset + line / 2)
    }
}

/// The token count in full, its digits coloured by each subscription's share: the number is its
/// own stacked bar.
struct TokensHero: View {
    let summary: StatsSummary
    let palette: StatsPalette

    var body: some View {
        let number = summary.tokens.formatted(.number)
        // Sized to every model's total, so picking a model changes the digits but not their size.
        let size = Self.fontSize(summary.allTokens.formatted(.number), width: Self.width)
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
                .contentTransition(.numericText())
                // The line's height from the font, not the glyphs, so other digits can't move what's below.
                .frame(height: Self.lineHeight(size), alignment: .bottomLeading)
                .statsTip(StatsTip(id: "tokens", title: "\(number) tokens", rows: [
                    .init(label: "Input", value: summary.tokenCounts.input.formatted(.number)),
                    .init(label: "Output", value: summary.tokenCounts.output.formatted(.number)),
                    .init(label: "Cache writes", value: summary.tokenCounts.cacheWrite.formatted(.number)),
                    .init(label: "Cache reads", value: summary.tokenCounts.cacheRead.formatted(.number)),
                ], note: "Everything the models read and wrote. Cache reads are context sent again and served from the provider's cache."))
                // Trim the line's empty ascent, but keep the descent: comma tails hang below.
                .padding(.top, -size * 0.1)
            HStack(alignment: .firstTextBaseline) {
                Text(StatsText.tokensCaption(summary))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.ink2)
                Spacer()
                if summary.tokens > 0 {
                    HStack(alignment: .firstTextBaseline) {
                        Text(StatsText.headlineCost(summary.cost, partial: summary.hasUnpriced))
                            .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("at API prices").font(.system(size: 16, weight: .medium)).foregroundStyle(palette.ink2)
                    }
                    .statsTip(StatsTip(
                        id: "cost", title: "At API prices",
                        note: StatsText.costNote(summary.cost, partial: summary.hasUnpriced)))
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

    static func lineHeight(_ size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: .heavy, width: .compressed)
        return ceil(font.ascender - font.descender + font.leading)
    }

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

/// Tokens per day, week or month, stacked by subscription. Pointing at a bar shows its figures.
private struct Bars: View {
    let summary: StatsSummary
    let palette: StatsPalette
    @Environment(\.statsTipID) private var lit

    var body: some View {
        let bars = summary.bars
        let peak = CGFloat(max(bars.map(\.totalTokens).max() ?? 0, 1))
        let dense = bars.count > 60
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { g in
                let slot = g.size.width / CGFloat(max(bars.count, 1))
                let width = max(slot * (dense ? 0.8 : 0.62), 1)
                let hovering = lit?.hasPrefix("bar:") == true
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(bars) { bar in
                        VStack(spacing: 0) {
                            ForEach([ProviderID.codex, .claude], id: \.self) { id in
                                let t = bar.tokens[id] ?? 0
                                if t > 0 {
                                    Rectangle().fill(palette.color(id)).frame(height: g.size.height * CGFloat(t) / peak)
                                }
                            }
                        }
                        .frame(width: width)
                        .clipShape(RoundedRectangle(cornerRadius: dense ? 1 : 2, style: .continuous))
                        .frame(width: slot, height: g.size.height, alignment: .bottom)
                        .opacity(!hovering || lit == "bar:\(bar.start)" ? 1 : 0.35)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(StatsText.barTip(bar, summary.bucket).title)
                        .accessibilityValue("\(bar.totalTokens.formatted(.number)) tokens. " + StatsText.byProvider(bar.tokens).map { "\($0.label): \($0.value)" }.joined(separator: ", "))
                    }
                }
            }
            .frame(height: 84)
            .overlay(alignment: .bottom) {
                Rectangle().fill(palette.faint).frame(height: 1)
            }
            .statsTip { p, size in
                guard !bars.isEmpty else { return nil }
                let slot = size.width / CGFloat(bars.count)
                let i = min(max(Int(p.x / slot), 0), bars.count - 1)
                let h = size.height * CGFloat(bars[i].totalTokens) / peak
                var tip = StatsText.barTip(bars[i], summary.bucket)
                tip.anchor = CGRect(x: CGFloat(i) * slot, y: size.height - h, width: slot, height: h)
                return tip
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tokens \(StatsText.per(summary.bucket))")
            Text("Tokens \(StatsText.per(summary.bucket))")
                .font(.system(size: 10.5))
                .foregroundStyle(palette.ink3)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Four headline numbers about what the agents did.
private struct Quartet: View {
    let summary: StatsSummary
    let palette: StatsPalette

    var body: some View {
        let s = summary
        let perPrompt = { (n: Int64) in s.prompts > 0 ? StatsText.one(Double(n) / Double(s.prompts)) : nil }
        HStack(alignment: .top, spacing: 0) {
            cell(StatsText.duration(s.agentMillis), "Agent time", StatsText.workTime(s.agentMillis))
                .statsTip(StatsTip(
                    id: "agent", title: "Agent time",
                    rows: s.prompts > 0 ? [.init(label: "Per prompt", value: StatsText.duration(s.agentMillis / s.prompts))] : [],
                    note: "How long your agents worked: from each prompt to its last response, including the time tools ran. Gaps over 30 minutes don't count. A full-time week is 40 hours."))
            cell(s.toolCalls.formatted(.number), "Tool calls", perPrompt(s.toolCalls).map { "\($0) per prompt" })
                .statsTip(StatsTip(
                    id: "tools", title: "Tool calls",
                    rows: StatsText.byProvider(s.tools.reduce(into: [:]) { a, t in t.byProvider.forEach { a[$0.key, default: 0] += $0.value } }),
                    note: "Shell commands, file reads and edits, searches, web lookups and other tools the agents ran."))
            cell(s.linesAdded.formatted(.number), "Lines added", s.linesRemoved > 0 ? "\(s.linesRemoved.formatted(.number)) removed" : nil)
                .statsTip(StatsTip(
                    id: "lines", title: "Lines changed",
                    rows: [.init(label: "Added", value: s.linesAdded.formatted(.number)),
                           .init(label: "Removed", value: s.linesRemoved.formatted(.number))],
                    note: "Lines the agents' file edits added and removed. Files changed through shell commands aren't counted."))
            cell(s.prompts.formatted(.number), "Prompts", perPrompt(s.responses).map { "\($0) responses per prompt" })
                .statsTip(StatsTip(
                    id: "prompts", title: "Prompts",
                    rows: [.init(label: "Responses", value: s.responses.formatted(.number))],
                    note: "Messages you typed. Each one can take many model responses while the agent works through its tools."))
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
                .contentTransition(.numericText())
                .frame(height: 40, alignment: .bottomLeading)
            Text(label).font(.system(size: 12, weight: .semibold))
            Text(detail ?? " ").font(.system(size: 11)).foregroundStyle(palette.ink2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tokens by weekday and hour, Monday on top.
private struct HeatMap: View {
    let summary: StatsSummary
    let palette: StatsPalette
    @Environment(\.statsTipID) private var lit

    private static let cell: CGFloat = 9.5
    private static let gap: CGFloat = 2

    var body: some View {
        let heat = summary.heat
        let peak = max(heat.flatMap { $0.map(\.tokens) }.max() ?? 0, 1)
        // One subscription's tokens (a model picked) take its colour, as in the bars.
        let tint = summary.tokensByProvider.count == 1 ? summary.tokensByProvider.keys.first.map(palette.color) ?? palette.ink : palette.ink
        let outline = tint == palette.claude ? palette.ink : palette.claude
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "When your agents work", palette: palette)
            HStack(alignment: .top, spacing: 5) {
                VStack(alignment: .trailing, spacing: Self.gap) {
                    ForEach(Array(StatsText.weekdayInitials.enumerated()), id: \.offset) { _, d in
                        Text(d).frame(height: Self.cell)
                    }
                }
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(palette.ink3)
                VStack(alignment: .leading, spacing: Self.gap) {
                    VStack(alignment: .leading, spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { day in
                            HStack(spacing: Self.gap) {
                                ForEach(0..<24, id: \.self) { hour in
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(fill(heat[day][hour].tokens, peak: peak, tint))
                                        .overlay {
                                            if lit == "heat:\(day):\(hour)" {
                                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                    .strokeBorder(outline, lineWidth: 1.5)
                                            }
                                        }
                                        .frame(width: Self.cell, height: Self.cell)
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel(StatsText.hourTip(summary, day: day, hour: hour).title)
                                        .accessibilityValue("\(heat[day][hour].tokens.formatted(.number)) tokens, \(heat[day][hour].responses.formatted(.number)) responses")
                                }
                            }
                        }
                    }
                    .statsTip { p, _ in
                        let step = Self.cell + Self.gap
                        let day = min(max(Int(p.y / step), 0), 6), hour = min(max(Int(p.x / step), 0), 23)
                        var tip = StatsText.hourTip(summary, day: day, hour: hour)
                        tip.anchor = CGRect(x: CGFloat(hour) * step, y: CGFloat(day) * step, width: Self.cell, height: Self.cell)
                        tip.beside = true
                        return tip
                    }
                    HStack(spacing: 0) {
                        ForEach([0, 6, 12, 18], id: \.self) { h in
                            Text(String(format: "%02d", h)).frame(width: (Self.cell + Self.gap) * 6, alignment: .leading)
                        }
                    }
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(palette.ink3)
                }
            }
            // Always there, so the sections below never move.
            Text(StatsText.busiestHour(heat) ?? " ").font(.system(size: 11)).foregroundStyle(palette.ink2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(StatsText.busiestHour(heat) ?? "Tokens by hour")
    }

    private func fill(_ v: Int64, peak: Int64, _ tint: Color) -> Color {
        guard v > 0 else { return palette.faint }
        return tint.opacity(0.14 + 0.8 * (Double(v) / Double(peak)).squareRoot())
    }
}

private struct ToolBars: View {
    let tools: [StatsSummary.Tool]
    let palette: StatsPalette
    @Environment(\.statsTipID) private var lit

    var body: some View {
        let top = tools.filter { $0.category != .other }.prefix(Self.rows)
        let largest = max(top.first?.calls ?? 1, 1)
        let hovering = lit?.hasPrefix("tool:") == true
        VStack(alignment: .leading, spacing: 2) {
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
                    .opacity(!hovering || lit == "tool:\(tool.category.rawValue)" ? 1 : 0.35)
                    Text(tool.calls.formatted(.number))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(width: 54, alignment: .trailing)
                }
                .frame(height: 15)
                .statsTip(StatsTip(
                    id: "tool:\(tool.category.rawValue)", title: tool.category.label,
                    rows: StatsText.byProvider(tool.byProvider)
                        + (tool.names.count > 1 ? tool.names.prefix(5).map {
                            .init(label: StatsText.toolName($0.name), value: $0.value.formatted(.number))
                        } : []),
                    note: tool.category == .mcp ? "Tools from MCP servers. Server names aren't stored." : nil))
            }
            // A model that used fewer kinds of tools leaves the rest of the rows empty, not gone.
            ForEach(top.count..<Self.rows, id: \.self) { _ in
                Color.clear.frame(height: 15)
            }
        }
    }

    static let rows = 7
}

/// The top models, each a filter: clicking one shows only its stats. Every other model is one
/// click further, in the full list.
private struct ModelTable: View {
    let summary: StatsSummary
    let palette: StatsPalette
    @Environment(\.statsPick) private var pick
    @Environment(\.statsTipID) private var lit
    @State private var showsAll = false

    static let rows = 4

    var body: some View {
        let top = Array(summary.models.prefix(Self.rows))
        // A model picked from the full list gets the row below the top ones, kept free for it.
        let extra = summary.model.flatMap { picked in
            top.contains { $0.name == picked } ? nil : summary.models.first { $0.name == picked }
        }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionTitle(text: "Models", palette: palette)
                if let pick, summary.models.count > Self.rows {
                    Button("All \(summary.models.count)") { showsAll = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.ink2)
                        .help("Every model in this range")
                        .popover(isPresented: $showsAll, arrowEdge: .trailing) {
                            AllModels(models: summary.models, picked: summary.model) { name in
                                showsAll = false
                                pick(name)
                            }
                        }
                }
                Spacer()
                Text("Avg speed").frame(width: 62, alignment: .trailing)
                    .statsTip(StatsTip(id: "speed", title: "Average speed", note: StatsText.speedNote))
                Text("Peak context").frame(width: 76, alignment: .trailing)
                    .statsTip(StatsTip(id: "peak", title: "Peak context", note: "The most tokens one request to this model sent, cached or not."))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(palette.ink3)
            .padding(.bottom, 2)
            ForEach(top) { m in
                row(m)
            }
            Group {
                if let extra { row(extra) } else { row(nil) }
            }
        }
    }

    /// A model's row, or an empty one holding its place.
    @ViewBuilder
    private func row(_ m: StatsSummary.Model?) -> some View {
        if let m {
            let picked = summary.model == m.name
            let label = ModelRow(model: m, palette: palette)
                .opacity(summary.model != nil && !picked ? 0.38 : 1)
                .padding(.vertical, 2.5)
                .padding(.horizontal, 6)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.ink.opacity(picked ? 0.08 : lit == "model:\(m.name)" ? 0.05 : 0))
                }
                .padding(.horizontal, -6)
            if let pick {
                Button { pick(m.name) } label: { label.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .statsTip(StatsText.modelTip(m, total: summary.allTokens, picked: picked))
            } else {
                label
            }
        } else {
            Color.clear.frame(height: 20)
        }
    }
}

private struct ModelRow: View {
    let model: StatsSummary.Model
    let palette: StatsPalette

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(palette.color(model.provider)).frame(width: 6, height: 6)
            Text(ModelName.display(model.name)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                .layoutPriority(1)
            Text(Format.tokens(model.tokens)).font(.system(size: 11.5)).foregroundStyle(palette.ink2)
            Spacer(minLength: 4)
            Text(model.speed.map { "\(Int($0.rounded())) tok/s" } ?? "\u{2014}")
                .frame(width: 62, alignment: .trailing)
            Text(model.peakContext > 0 ? Format.tokens(model.peakContext) : "\u{2014}")
                .frame(width: 76, alignment: .trailing)
        }
        .font(.system(size: 11.5, weight: .medium))
        .monospacedDigit()
        .frame(height: 15)
    }
}

/// Every model used in the range, by subscription, in a popover from the card's model list.
private struct AllModels: View {
    let models: [StatsSummary.Model]
    let picked: String?
    let pick: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = StatsPalette(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach([ProviderID.claude, .codex], id: \.self) { id in
                    let mine = models.filter { $0.provider == id }
                    if !mine.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(id.displayName).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text("Avg speed").frame(width: 62, alignment: .trailing)
                                Text("Peak context").frame(width: 76, alignment: .trailing)
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 2)
                            ForEach(mine) { m in
                                Button { pick(m.name) } label: {
                                    ModelRow(model: m, palette: palette)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(AllModelsRowStyle(picked: picked == m.name))
                            }
                        }
                    }
                }
                Text(picked == nil ? "Click a model to show only its stats." : "Click the picked model again to show all models.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            .padding(10)
        }
        .frame(width: 380)
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AllModelsRowStyle: ButtonStyle {
    let picked: Bool

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, picked: picked)
    }

    private struct Row: View {
        let configuration: Configuration
        let picked: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.primary.opacity(configuration.isPressed ? 0.12 : picked ? 0.09 : hovering ? 0.05 : 0))
                }
                .onHover { hovering = $0 }
        }
    }
}

/// The bottom line: smaller facts, one row.
private struct Facts: View {
    let summary: StatsSummary
    let palette: StatsPalette

    var body: some View {
        let s = summary
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(palette.faint).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                fact(StatsText.days(s.currentStreak), "Current streak", "Longest \(StatsText.days(s.longestStreak))")
                    .statsTip(StatsTip(
                        id: "streak", title: "Streak",
                        rows: [.init(label: "Current", value: StatsText.days(s.currentStreak)),
                               .init(label: "Longest", value: StatsText.days(s.longestStreak))],
                        note: "Days in a row with any usage\(s.model.map { " of \(ModelName.display($0))" } ?? ""). Today joins the streak once it has some."))
                if let b = s.busiestDay {
                    fact(StatsText.shortDate(b.day), "Busiest day", "\(Format.tokens(b.tokens)) tokens")
                        .statsTip(StatsTip(
                            id: "busiest", title: DayKeyDate.date(b.day).formatted(.dateTime.weekday(.wide).month(.wide).day().year()),
                            rows: [.init(label: "Tokens", value: b.tokens.formatted(.number))]))
                } else {
                    fact("\u{2014}", "Busiest day", "no tokens yet")
                }
                fact(s.cacheShare.map(StatsText.percent) ?? "\u{2014}", "Read from cache", "of all input tokens")
                    .statsTip(StatsTip(
                        id: "cache", title: "Read from cache",
                        rows: [.init(label: "Cache reads", value: Format.tokens(s.tokenCounts.cacheRead)),
                               .init(label: "All input", value: Format.tokens(s.tokenCounts.input + s.tokenCounts.cacheWrite + s.tokenCounts.cacheRead))],
                        note: "Input the providers served from their prompt cache instead of processing it again. Cache reads cost a fraction of fresh input."))
                fact(s.compactions.formatted(.number), "Compactions",
                     s.compactedTokens > 0 ? "\(Format.tokens(s.compactedTokens)) tokens summarized" : "context summaries")
                    .statsTip(StatsTip(
                        id: "compactions", title: "Compactions",
                        note: "Times a conversation's context was summarized to free up room, automatically or with /compact. Token counts come from Claude Code; Codex doesn't log them."))
                fact(s.peakContext > 0 ? Format.tokens(s.peakContext) : "\u{2014}", "Biggest context", "tokens in one request")
                    .statsTip(StatsTip(
                        id: "context", title: "Biggest context",
                        rows: [.init(label: "Tokens", value: s.peakContext.formatted(.number))]
                            + (StatsText.peakModel(s).map { [.init(label: "Model", value: ModelName.display($0))] } ?? []),
                        note: "The most tokens one request sent to a model, cached or not."))
                fact(s.projects.formatted(.number), s.projects == 1 ? "Project" : "Projects",
                     "across \(s.activeDays) active \(s.activeDays == 1 ? "day" : "days")")
                    .statsTip(StatsTip(
                        id: "projects", title: "Projects",
                        rows: s.topProjects.prefix(5).map { .init(label: $0.name, value: Format.tokens($0.value)) },
                        note: "Folders your agents worked in, by tokens. Names stay in this window; the copied image shows only the count."))
            }
        }
    }

    private func fact(_ value: String, _ label: String, _ detail: String) -> some View {
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

struct SectionTitle: View {
    let text: String
    let palette: StatsPalette

    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink)
    }
}

// MARK: Text

enum StatsText {
    /// Whole dollars for the headline; "+" when some models have no known price, "—" when none do.
    static func headlineCost(_ c: Double?, partial: Bool) -> String {
        guard let c else { return "—" }
        return "$" + c.formatted(.number.precision(.fractionLength(0))) + (partial ? "+" : "")
    }

    /// Cents in hover details, so a small day doesn't read as $0.
    static func cost(_ c: Double?, partial: Bool) -> String {
        c == nil ? "—" : Format.cost(c) + (partial ? "+" : "")
    }

    static func costNote(_ c: Double?, partial: Bool) -> String {
        if c == nil { return "None of these models has a known API price." }
        let base = "What these tokens would cost at the providers' pay-as-you-go API prices. Your subscription doesn't charge per token."
        return partial ? base + " Some models have no known price, so their tokens aren't included." : base
    }

    static let weekdayInitials = ["M", "T", "W", "T", "F", "S", "S"]
    private static let weekdayNames = ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]

    static func tokensCaption(_ s: StatsSummary) -> String {
        let range = switch s.range {
        case .week: "in the last 7 days"
        case .month: "in the last 30 days"
        case .all: "since you started"
        }
        return s.model.map { "\(ModelName.display($0)) tokens \(range)" } ?? "tokens \(range)"
    }

    static func per(_ bucket: StatsBucket) -> String {
        switch bucket {
        case .day: "per day"
        case .week: "per week"
        case .month: "per month"
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

    /// "1 full workday", "1.5 full workdays".
    static func count(_ x: Double, _ unit: String) -> String {
        let n = one(x)
        return n == "1.0" || n == "1" ? "1 \(unit)" : "\(n) \(unit)s"
    }

    static func one(_ x: Double) -> String {
        x >= 10 ? "\(Int(x.rounded()))" : x.formatted(.number.precision(.fractionLength(1)))
    }

    static func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    static func duration(_ ms: Int64) -> String {
        let minutes = Int(ms / 60_000)
        let h = minutes / 60, m = minutes % 60
        if h >= 100 { return "\(h) h" }
        if h > 0 { return "\(h) h \(m) m" }
        if minutes > 0 { return "\(m) m" }
        return "\(ms / 1000) s"
    }

    /// Agent Time as full-time work: 40-hour weeks, or 8-hour days below one week.
    static func workTime(_ ms: Int64) -> String? {
        let hours = Double(ms) / 3_600_000
        if hours >= 40 { return count(hours / 40, "full-time week") }
        if hours >= 8 { return count(hours / 8, "full workday") }
        return nil
    }

    static func busiestHour(_ heat: [[StatsSummary.Hour]]) -> String? {
        var best: (Int, Int, Int64) = (0, 0, 0)
        for d in 0..<7 { for h in 0..<24 where heat[d][h].tokens > best.2 { best = (d, h, heat[d][h].tokens) } }
        guard best.2 > 0 else { return nil }
        return "Busiest on \(weekdayNames[best.0]) at \(String(format: "%02d:00", best.1))"
    }

    static let speedNote = "Output tokens per second, averaged over responses of 200 tokens or more, each timed from sending the request to its last token. Shown once a model has 10 of them."

    static func byProvider(_ counts: [ProviderID: Int64]) -> [StatsTip.Row] {
        [ProviderID.claude, .codex].compactMap { id in
            guard let v = counts[id], v > 0 else { return nil }
            return .init(label: id.displayName, value: v.formatted(.number), provider: id)
        }
    }

    /// Raw tool names as logged, with Codex's few renamed to what they do.
    static func toolName(_ name: String) -> String {
        switch name {
        case "Shell": "Shell (Codex)"
        case "Web": "Web (Codex)"
        default: name
        }
    }

    static func peakModel(_ s: StatsSummary) -> String? {
        if let m = s.model { return m }
        return s.models.max { $0.peakContext < $1.peakContext }.flatMap { $0.peakContext == s.peakContext ? $0.name : nil }
    }

    static func barTip(_ bar: StatsSummary.Bar, _ bucket: StatsBucket) -> StatsTip {
        let start = DayKeyDate.date(bar.start), end = DayKeyDate.date(bar.end)
        let title: String
        switch bucket {
        case .day:
            title = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week:
            let ends = Calendar.current.isDate(start, equalTo: end, toGranularity: .month)
                ? end.formatted(.dateTime.day()) : end.formatted(.dateTime.month(.abbreviated).day())
            title = "\(start.formatted(.dateTime.month(.abbreviated).day())) to \(ends)"
        case .month:
            title = start.formatted(.dateTime.month(.wide).year())
        }
        var rows: [StatsTip.Row] = [.init(label: "Tokens", value: bar.totalTokens.formatted(.number))]
        rows += byProvider(bar.tokens)
        if bar.totalTokens > 0 { rows.append(.init(label: "At API prices", value: cost(bar.cost, partial: bar.hasUnpriced))) }
        if bar.prompts > 0 { rows.append(.init(label: "Prompts", value: bar.prompts.formatted(.number))) }
        if bar.toolCalls > 0 { rows.append(.init(label: "Tool calls", value: bar.toolCalls.formatted(.number))) }
        if bar.agentMillis > 0 { rows.append(.init(label: "Agent time", value: duration(bar.agentMillis))) }
        if bar.linesAdded > 0 { rows.append(.init(label: "Lines added", value: bar.linesAdded.formatted(.number))) }
        return StatsTip(id: "bar:\(bar.start)", title: title, rows: rows)
    }

    static func hourTip(_ s: StatsSummary, day: Int, hour: Int) -> StatsTip {
        let cell = s.heat[day][hour]
        let n = s.weekdays[day]
        let one = String(weekdayNames[day].dropLast())
        return StatsTip(
            id: "heat:\(day):\(hour)",
            title: "\(weekdayNames[day]), \(String(format: "%02d:00", hour)) to \(String(format: "%02d:00", (hour + 1) % 24))",
            rows: [.init(label: "Tokens", value: cell.tokens.formatted(.number)),
                   .init(label: "Responses", value: cell.responses.formatted(.number))],
            note: n == 1 ? "One \(one) in this range." : "The sum of \(n) \(weekdayNames[day]).")
    }

    static func modelTip(_ m: StatsSummary.Model, total: Int64, picked: Bool) -> StatsTip {
        var rows: [StatsTip.Row] = [
            .init(label: "Tokens", value: m.tokens.formatted(.number)),
            .init(label: "Share", value: percent(Double(m.tokens) / Double(max(total, 1)))),
        ]
        rows.append(.init(label: "At API prices", value: cost(m.cost, partial: false)))
        rows.append(.init(label: "Responses", value: m.responses.formatted(.number)))
        if let speed = m.speed {
            rows.append(.init(label: "Avg speed", value: "\(one(speed)) tok/s"))
            rows.append(.init(label: "Timed responses", value: m.speedSamples.formatted(.number)))
        }
        if m.peakContext > 0 { rows.append(.init(label: "Peak context", value: m.peakContext.formatted(.number))) }
        return StatsTip(
            id: "model:\(m.name)", title: ModelName.display(m.name), rows: rows,
            note: picked ? "Click to show all models again." : "Click to show only this model.")
    }
}
