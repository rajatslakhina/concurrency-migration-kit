/// Where a single module sits on the road from Swift 5 to full Swift 6 data-race safety.
///
/// The ordering is load-bearing: the planner treats "dependency posture >= dependent
/// posture" as the invariant a healthy graph maintains, and an inversion of it as the
/// place where `@preconcurrency` debt is created.
public enum ConcurrencyPosture: Int, Sendable, Hashable, CaseIterable, Comparable {
    /// Swift 5 language mode, `-strict-concurrency=minimal` or unset. No checking.
    case swift5Unchecked = 0
    /// Swift 5 language mode, `-strict-concurrency=targeted`. Warnings on explicitly
    /// concurrent code only.
    case swift5Targeted = 1
    /// Swift 5 language mode, `-strict-concurrency=complete`. Full checking, as warnings.
    case swift5Complete = 2
    /// Swift 6 language mode. The same checks, as errors.
    case swift6 = 3

    public static func < (lhs: ConcurrencyPosture, rhs: ConcurrencyPosture) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// `true` once the module compiles under the Swift 6 language mode.
    ///
    /// This, not `swift5Complete`, is the bar a dependency must clear before a dependent
    /// can migrate without taking on an `@preconcurrency import`: warnings can be ignored
    /// by the module that emits them, so a `swift5Complete` dependency still offers its
    /// dependents no enforced `Sendable` guarantee.
    public var isMigrated: Bool { self == .swift6 }

    public var displayName: String {
        switch self {
        case .swift5Unchecked: "Swift 5 (unchecked)"
        case .swift5Targeted: "Swift 5 (targeted)"
        case .swift5Complete: "Swift 5 (complete)"
        case .swift6: "Swift 6"
        }
    }
}
