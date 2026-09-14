import Foundation

// Pure decision logic for the two durability fixes (spec 2026-09-13): the collapse-guard
// deadline and the frozen-scope switcher filter. No AppKit — unit-tested in MSVCoreTests.

/// health.json shape — written by the app's 30s heartbeat timer, read by `multistreamviewer
/// status`. Shared here so writer and reader can't drift.
public struct Health: Codable {
    public var updatedEpoch: Double
    public var lastTickEpoch: Double
    public var tapAlive: Bool
    public var windowCount: Int
    public var groupCount: Int
    public var currentGroup: String
    public init(updatedEpoch: Double, lastTickEpoch: Double, tapAlive: Bool,
                windowCount: Int, groupCount: Int, currentGroup: String) {
        self.updatedEpoch = updatedEpoch
        self.lastTickEpoch = lastTickEpoch
        self.tapAlive = tapAlive
        self.windowCount = windowCount
        self.groupCount = groupCount
        self.currentGroup = currentGroup
    }
}

public struct CollapseState: Equatable {
    public var lastRawCount: Int
    public var collapsedSince: Date?
    public init(lastRawCount: Int = 0, collapsedSince: Date? = nil) {
        self.lastRawCount = lastRawCount
        self.collapsedSince = collapsedSince
    }
}

public struct CollapseDecision: Equatable {
    public let skip: Bool          // ignore this tick's list (blip / off-console degradation)
    public let accepted: Bool      // deadline hit — reality wins, list adopted
    public let state: CollapseState
}

/// A mass disappearance (count drops below 40% with ≥5 windows before) is a degraded snapshot,
/// not the user closing everything — but only for so long. After `deadline` seconds of
/// *usable-session* collapse, accept reality (a genuine mass-close must not wedge every future
/// tick, which is exactly what the pre-spec code did). While the session is not usable
/// (off-console, locked), the clock does not run — accepting the off-console empty list would
/// prune every tag.
public func collapseDecision(_ st: CollapseState, newCount: Int, sessionUsable: Bool,
                             now: Date, deadline: TimeInterval = 10) -> CollapseDecision {
    let collapsed = st.lastRawCount >= 5 && newCount * 5 < st.lastRawCount * 2
    if !collapsed {
        return CollapseDecision(skip: false, accepted: false,
                                state: CollapseState(lastRawCount: newCount, collapsedSince: nil))
    }
    guard sessionUsable else {   // off-console/locked: hold position, don't run the clock
        return CollapseDecision(skip: true, accepted: false,
                                state: CollapseState(lastRawCount: st.lastRawCount, collapsedSince: nil))
    }
    let since = st.collapsedSince ?? now
    if now.timeIntervalSince(since) > deadline {
        return CollapseDecision(skip: false, accepted: true,
                                state: CollapseState(lastRawCount: newCount, collapsedSince: nil))
    }
    return CollapseDecision(skip: true, accepted: false,
                            state: CollapseState(lastRawCount: st.lastRawCount, collapsedSince: since))
}

/// The switcher's per-tick candidate maintenance under a scope frozen at open(): drop only
/// windows that actually closed. In fallback mode (`frozenScope == nil`) group membership is
/// ignored entirely — a window appearing in some group mid-hold must never yank the list.
/// `assignment` maps windowID → groupID for the live windows.
public func maintainCandidates<W: Hashable, G: Equatable>(
    candidates: [W], liveIDs: Set<W>, assignment: [W: G], frozenScope: G?
) -> [W] {
    candidates.filter { w in
        guard liveIDs.contains(w) else { return false }
        guard let scope = frozenScope else { return true }   // fallback: liveness only
        return assignment[w] == scope
    }
}
