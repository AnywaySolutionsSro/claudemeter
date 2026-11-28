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
    /// exhausted (past-reset windows already read as full in `current`) or while the
    /// `reached` window (`reachedWindow`) has not reset, else the windows that
    /// refilled per `refilledWindows`. Without `reached`, a 5-h refill under a weekly
    /// limit that cut the session off below 100% would type `continue` into a wall.
    static func gate(
        previous: [LimitWindow], previousAt: Date?, current: UsageSnapshot, now: Date, reached: LimitWindow? = nil,
    ) -> ResumeGate {
        if let blocking = current.blockingWindow { return .blocked(blocking) }
        if let reached { return .blocked(reached) }
        return .clear(refilled: refilledWindows(previous: previous, previousAt: previousAt, current: current, now: now))
    }

    /// The window a reading's `rate_limit_reached_type` cut the session off at, while
    /// its reset has not passed; `nil` when nothing is reached. The type's values are
    /// unverified, so the reached window is the reading's fullest one (ties: the later
    /// reset, the conservative choice). Without windows there is no reset to wait
    /// for, so nothing blocks (blocking would wedge auto-resume for good).
    static func reachedWindow(_ reading: CodexLimitReading?, now: Date) -> LimitWindow? {
        guard let reading, reading.reachedType != nil,
              let fullest = reading.windows.max(by: isLessReached),
              !isPastReset(fullest, now: now)
        else { return nil }
        let alone = CodexLimitReading(
            limitID: reading.limitID, observedAt: reading.observedAt, windows: [fullest], reachedType: nil,
        )
        return snapshot(from: alone, now: now).limitWindows.first
    }

    private static func isLessReached(_ lhs: CodexWindowReading, _ rhs: CodexWindowReading) -> Bool {
        if lhs.usedPercent != rhs.usedPercent { return lhs.usedPercent < rhs.usedPercent }
        return (lhs.resetsAt ?? .distantFuture) < (rhs.resetsAt ?? .distantFuture)
    }

    private static func isPast(_ resetsAt: Date?, at date: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= date
    }
}
