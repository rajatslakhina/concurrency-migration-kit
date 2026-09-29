/// Non-trapping integer arithmetic.
///
/// Every number in this package is derived from user-supplied graph data: diagnostic
/// counts parsed out of a build log, budgets typed into a config file, blast radii
/// accumulated across a transitive closure. Any one of them can be absurd, and Swift's
/// `+`, `*`, `/`, `%` and `Int(Double)` all *trap* rather than misbehave — a crash in a
/// planning tool that runs in CI, on someone else's numbers.
///
/// Saturating at the representable bounds is the deliberate trade-off: a blast radius
/// reported as `Int.max` is obviously wrong to a human reading the plan, where a crash is
/// merely absent. Nothing here widens to `Int64`, so the semantics hold on a 32-bit `Int`.
public enum SaturatingMath {

    /// `a + b`, clamped to the representable range instead of trapping.
    public static func add(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return sum }
        return b > 0 ? Int.max : Int.min
    }

    /// `a - b`, clamped to the representable range instead of trapping.
    public static func subtract(_ a: Int, _ b: Int) -> Int {
        let (difference, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return difference }
        return b < 0 ? Int.max : Int.min
    }

    /// `a * b`, clamped to the representable range instead of trapping.
    public static func multiply(_ a: Int, _ b: Int) -> Int {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return product }
        let negative = (a < 0) != (b < 0)
        return negative ? Int.min : Int.max
    }

    /// Sums a sequence, clamping instead of trapping.
    public static func sum<S: Sequence>(_ values: S) -> Int where S.Element == Int {
        values.reduce(0) { add($0, $1) }
    }

    /// `part / whole` as a whole-number percentage in `0...100`.
    ///
    /// Returns `0` when `whole <= 0` — the two cases Swift would trap on (`/ 0`) or that
    /// have no meaningful answer (a negative denominator) collapse to the same honest
    /// "nothing to report" value rather than to a crash or a negative percentage.
    ///
    /// The multiply is done at double width rather than saturated. Saturating it is the
    /// obvious-looking version and it is wrong: `percentage(part: .max, of: .max)` becomes
    /// `Int.max / Int.max == 1`, reporting 1% for a graph that is 100% migrated. Clamping
    /// an intermediate silently destroys a ratio, which is a good reason to be suspicious
    /// of saturating arithmetic anywhere the value is not itself the answer.
    public static func percentage(part: Int, of whole: Int) -> Int {
        guard whole > 0 else { return 0 }
        let clampedPart = max(0, min(part, whole))
        // `clampedPart` is in `0...whole` and `whole > 0`, so the exact quotient is in
        // `0...100` and therefore representable — `dividingFullWidth` only traps when the
        // quotient does not fit or the divisor is zero, and neither is reachable here.
        // `Int.min / -1` is ruled out by the same positive divisor.
        let wide = clampedPart.multipliedFullWidth(by: 100)
        return whole.dividingFullWidth(wide).quotient
    }

    /// Converts a `Double` to an `Int` without trapping.
    ///
    /// `Int(someDouble)` traps on NaN, on ±infinity, and on any value outside
    /// `Int`'s range. Comparing against `Double(Int.max)` is *not* a correct guard —
    /// that conversion rounds up to exactly 2^63, so a value equal to it would pass a
    /// `<=` check and still trap. `Int(exactly:)` on the truncated value is the
    /// bound-free test, and it stays correct where `Int` is 32 bits wide.
    public static func int(_ value: Double) -> Int {
        guard value.isFinite else {
            if value.isNaN { return 0 }
            return value > 0 ? Int.max : Int.min
        }
        let truncated = value.rounded(.towardZero)
        if let exact = Int(exactly: truncated) { return exact }
        return truncated > 0 ? Int.max : Int.min
    }

    /// Clamps `value` into `range`.
    public static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
