import Foundation

/// How the app is allowed to run new sessions given today's spend (§4.3.6, R13).
/// Caps gate STARTING sessions only — an active session always finishes (R13),
/// downgrading to the cheap pipeline mid-flight if needed but never terminating.
public enum CostPolicy: String, Sendable, Equatable {
    /// Full experience: realtime-voice roleplay (Pipeline A) permitted.
    case full
    /// Soft cap reached (or user forced it): new roleplays run on the cheap
    /// cascade pipeline (Pipeline B) — STT→Claude→cached-voice TTS.
    case cheapMode
    /// Hard cap reached: drills only; no new roleplays may start.
    case drillsOnly

    /// A new roleplay may be started at all (false only past the hard cap).
    public var allowsNewRoleplay: Bool { self != .drillsOnly }

    /// The pipeline a newly started roleplay must use.
    public var roleplayPipeline: SessionPipeline {
        self == .full ? .realtime : .cascade
    }
}

/// Daily spend caps (USD). Defaults per §4.3.6 dogfood envelope; both are
/// user-overridable. Verify per-minute provider pricing before shipping.
public struct CostCaps: Sendable, Equatable {
    public var softUSD: Double
    public var hardUSD: Double

    public init(softUSD: Double, hardUSD: Double) {
        self.softUSD = softUSD
        self.hardUSD = hardUSD
    }

    /// §4.3.6 defaults: soft $2.50 → cheap mode, hard $5.00 → drills only.
    public static let dogfoodDefault = CostCaps(softUSD: 2.50, hardUSD: 5.00)
}

/// Pure policy resolver. Given today's metered spend, the caps, and an optional
/// manual "always cheap" override, decides what may start now. Deterministic and
/// side-effect free so it is trivially unit-testable and safe to call anywhere.
public struct CostGovernor: Sendable, Equatable {
    public var caps: CostCaps
    /// User's Settings toggle: force the cheap pipeline regardless of spend (R14
    /// cost-transparency; lets a cost-conscious dogfooder cap realtime voice).
    public var forceCheapMode: Bool

    public init(caps: CostCaps = .dogfoodDefault, forceCheapMode: Bool = false) {
        self.caps = caps
        self.forceCheapMode = forceCheapMode
    }

    /// Resolve the policy for a given day's spend. Hard cap wins over soft cap
    /// wins over the manual toggle; the manual toggle only ever tightens.
    public func policy(todaySpendUSD spend: Double) -> CostPolicy {
        if spend >= caps.hardUSD { return .drillsOnly }
        if forceCheapMode || spend >= caps.softUSD { return .cheapMode }
        return .full
    }
}
