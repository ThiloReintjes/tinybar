import Foundation

/// A Provider's Accounts taken together (see CONTEXT.md: Pool, SPEC §15).
public struct Pool: Sendable {
    /// The Accounts, soonest next Reset first. Empty or single: nothing is pooled.
    public var accounts: [Account]
    /// What the Provider shows: the only Account's snapshot, or the pooled windows.
    public var snapshot: ProviderSnapshot?
    /// Set when no Account could be read, so the whole Provider is Stale.
    public var error: ProviderError?

    public init(provider: ProviderID, accounts: [Account], now: Date = Date()) {
        guard accounts.count > 1 else {
            self.accounts = accounts
            snapshot = accounts.first?.snapshot
            error = accounts.first?.error
            return
        }
        let current = accounts.map { account -> Account in
            var account = account
            account.snapshot = account.snapshot.map { Self.current($0, now: now) }
            return account
        }
        self.accounts = Self.ordered(current)
        let known = self.accounts.compactMap(\.snapshot)
        snapshot = known.isEmpty ? nil : ProviderSnapshot(
            provider: provider, plan: "\(accounts.count) accounts", windows: Self.windows(known),
            fetchedAt: known.map(\.fetchedAt).max() ?? now)
        error = accounts.allSatisfy(\.isStale) ? accounts.first?.error : nil
    }

    /// A window whose known Reset has passed is full, whatever it last read: an idle login can't
    /// be asked, and its old reading would otherwise hold the Pool down for good.
    private static func current(_ snapshot: ProviderSnapshot, now: Date) -> ProviderSnapshot {
        var snapshot = snapshot
        snapshot.windows = snapshot.windows.map { window in
            guard let reset = window.resetsAt, reset <= now else { return window }
            var window = window
            window.usedPercent = 0
            window.resetsAt = nil
            return window
        }
        return snapshot
    }

    /// Soonest next refill first, on the shortest window any Account reports, as T3 Code does.
    private static func ordered(_ accounts: [Account]) -> [Account] {
        let windows = accounts.compactMap(\.snapshot).flatMap(\.windows).filter { !$0.isModelSpecific }
        let shortest = windows.min { ($0.durationSeconds ?? .max) < ($1.durationSeconds ?? .max) }?.id
        func reset(_ account: Account) -> Date {
            account.snapshot?.windows.first { $0.id == shortest }?.resetsAt ?? .distantFuture
        }
        return accounts.sorted {
            (reset($0), $0.displayName.lowercased(), $0.id) < (reset($1), $1.displayName.lowercased(), $1.id)
        }
    }

    /// Each window is the plain average over the Accounts reporting it, as T3 Code's is. Plans can't
    /// weigh it, because claude-swap doesn't report them.
    private static func windows(_ snapshots: [ProviderSnapshot]) -> [LimitWindow] {
        var order: [String] = []
        var members: [String: [(window: LimitWindow, spentWeek: LimitWindow?)]] = [:]
        for snapshot in snapshots {
            let general = snapshot.windows.filter { !$0.isModelSpecific }
            // A week used up leaves nothing to use in its 5 hours, however empty those are.
            let spentWeek = general.first { $0.kind == .weekly && $0.usedPercent >= 100 }
            for window in general {
                if members[window.id] == nil { order.append(window.id) }
                members[window.id, default: []].append((window, window.kind == .session ? spentWeek : nil))
            }
        }
        return order.compactMap { id in
            guard let list = members[id], let first = list.first?.window else { return nil }
            let used = list.map { $0.spentWeek == nil ? $0.window.usedPercent : 100 }.reduce(0, +) / Double(list.count)
            let resets = list.compactMap { refill($0.window, spentWeek: $0.spentWeek) }.sorted { $0.at < $1.at }
            // The next Reset that gives anything back, with any others landing at that moment.
            let next = resets.first { $0.percent > 0 } ?? resets.first
            let together = next.map { n in resets.filter { abs($0.at.timeIntervalSince(n.at)) < 60 } } ?? []
            var window = LimitWindow(
                id: id, title: first.title, usedPercent: used, resetsAt: next?.at, durationSeconds: first.durationSeconds)
            window.poolRefill = together.map(\.percent).reduce(0, +) / Double(list.count)
            return window
        }
    }

    /// When an Account's window gets its share back, and how much. A 5 hours blocked by a spent week
    /// needs both to reset, as T3 Code works out: unused time comes back with the week, and a spent
    /// 5 hours with whichever comes last.
    private static func refill(_ window: LimitWindow, spentWeek: LimitWindow?) -> (at: Date, percent: Double)? {
        guard let spentWeek else { return window.resetsAt.map { ($0, window.usedPercent) } }
        guard let weekReset = spentWeek.resetsAt else { return nil }
        // With no Reset of its own, what's used of it stays used when the week comes back.
        guard let reset = window.resetsAt else { return (weekReset, 100 - window.usedPercent) }
        if reset <= weekReset { return (weekReset, 100) }
        return window.usedPercent >= 100 ? (reset, 100) : (weekReset, 100 - window.usedPercent)
    }
}
