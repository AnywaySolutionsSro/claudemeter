import Foundation

/// The Codex auto-resume gate. Codex limits come from local transcripts, and no Codex
/// turn runs while blocked, so no fresh reading arrives to show the drop: the reset
/// passing is itself the refill signal.
public extension CodexLimits {
    /// Windows of `current` that refilled since the previous scan: each window, compared
    /// with itself by `LimitWindow.id`, whose `resets_at` had not passed at `previousAt`
    /// but has at `now` — **whatever its used%**, since a cutoff can come from
    /// `rate_limit_reached_type` below 100% — or whose utilization dropped ≥ 25 points
    /// (`UsageStats.refilledWindows`). A window with no previous reading refilled nothing.
    /// Returned in `current`'s order, each window once.
    static func refilledWindows(
        previous: [LimitWindow], previousAt: Date?, current: UsageSnapshot, now: Date,
    ) -> [LimitWindow] {
        let dropped = Set(UsageStats.refilledWindows(previous: previous, current: current.limitWindows).map(\.id))
        return current.limitWindows.filter { window in
            if dropped.contains(window.id) { return true }
            guard let previousAt, let before = previous.first(where: { $0.id == window.id }) else { return false }
            return !isPast(before.bucket.resetsAt, at: previousAt) && isPast(window.bucket.resetsAt, at: now)
        }
    }

    /// `AutoResumePlanner.gate` for Codex: blocked while an account-wide window is
    /// exhausted (past-reset windows already read as full in `current`), else the
    /// windows that refilled per `refilledWindows`.
    static func gate(previous: [LimitWindow], previousAt: Date?, current: UsageSnapshot, now: Date) -> ResumeGate {
        if let blocking = current.blockingWindow { return .blocked(blocking) }
        return .clear(refilled: refilledWindows(previous: previous, previousAt: previousAt, current: current, now: now))
    }

    private static func isPast(_ resetsAt: Date?, at date: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= date
    }
}
