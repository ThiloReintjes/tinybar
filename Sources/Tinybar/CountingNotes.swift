import SwiftUI
import TinybarCore

/// How Tinybar gets its numbers, in plain words. Shown on the popover's info page and from the
/// Stats window, with the share of tokens Activity was counted from when that is short of all.
struct CountingNotes: View {
    /// Providers whose Activity comes from logs holding under 97% of their tokens, with the share.
    var coverage: [ProviderID: Double] = [:]
    /// The range `coverage` is for.
    var range: StatsRange = .month

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            note("Limits", """
                Each provider reports your limits using the login its CLI already has, or your \
                browser session if you turned that on in Settings. Tinybar only reads those logins \
                and never changes them. A run-out time assumes you keep the average pace of the \
                window so far.
                """)
            note("Tokens", """
                Counted from the Claude Code and Codex logs on this Mac and kept as daily totals, so \
                they stay when the CLIs delete old logs. Gemini and Cursor show limits only.
                """)
            note("At API prices", """
                What those tokens would cost on each provider's pay-as-you-go API, at today's prices \
                from models.dev. Your subscription doesn't charge per token.
                """)
            note("Stats", activity)
            note("Your data", """
                Logs, totals and stats stay on this Mac. Tinybar only asks each provider for your \
                limits and models.dev for prices.
                """)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activity: String {
        var text = """
            Prompts, tool calls, lines and agent time are counted from the logs still on disk. \
            Codex compresses older logs, which Tinybar can't read yet, so some days have tokens but \
            little activity.
            """
        if !coverage.isEmpty {
            let parts = coverage.sorted { $0.key < $1.key }
                .map { "\(StatsText.percent($0.value)) of \($0.key.displayName) tokens" }
            text += " In \(phrase), the logs Tinybar could read hold \(parts.joined(separator: " and "))."
        }
        return text + " Point at anything in Stats to see what it counts."
    }

    private var phrase: String {
        switch range {
        case .week: "the last 7 days"
        case .month: "the last 30 days"
        case .all: "all your history"
        }
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
