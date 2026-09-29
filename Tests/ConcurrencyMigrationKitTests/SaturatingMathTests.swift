import XCTest
@testable import ConcurrencyMigrationKit

/// Every assertion here names a value that makes the *unguarded* operator trap. If any of
/// these were implemented with plain `+`, `*`, `/` or `Int(_:)`, the test process would
/// crash rather than fail — which is the point: these are crash tests wearing an
/// assertion's clothes.
final class SaturatingMathTests: XCTestCase {

    func testAdditionSaturatesInsteadOfTrapping() {
        XCTAssertEqual(SaturatingMath.add(Int.max, 1), Int.max)
        XCTAssertEqual(SaturatingMath.add(Int.max, Int.max), Int.max)
        XCTAssertEqual(SaturatingMath.add(Int.min, -1), Int.min)
        XCTAssertEqual(SaturatingMath.add(Int.min, Int.min), Int.min)
        XCTAssertEqual(SaturatingMath.add(7, 5), 12)
        XCTAssertEqual(SaturatingMath.add(Int.max, Int.min), -1)
    }

    func testSubtractionSaturatesInsteadOfTrapping() {
        XCTAssertEqual(SaturatingMath.subtract(Int.min, 1), Int.min)
        XCTAssertEqual(SaturatingMath.subtract(Int.max, -1), Int.max)
        XCTAssertEqual(SaturatingMath.subtract(10, 4), 6)
    }

    func testMultiplicationSaturatesWithCorrectSign() {
        XCTAssertEqual(SaturatingMath.multiply(Int.max, 2), Int.max)
        XCTAssertEqual(SaturatingMath.multiply(Int.max, -2), Int.min)
        XCTAssertEqual(SaturatingMath.multiply(Int.min, -1), Int.max, "Int.min * -1 overflows by exactly one")
        XCTAssertEqual(SaturatingMath.multiply(6, 7), 42)
        XCTAssertEqual(SaturatingMath.multiply(Int.min, 0), 0)
    }

    func testSumOfAnOverflowingSequenceSaturates() {
        XCTAssertEqual(SaturatingMath.sum([Int.max, Int.max, Int.max]), Int.max)
        XCTAssertEqual(SaturatingMath.sum([] as [Int]), 0)
        XCTAssertEqual(SaturatingMath.sum([1, 2, 3]), 6)
    }

    func testPercentageNeverDividesByZeroOrEscapesItsRange() {
        XCTAssertEqual(SaturatingMath.percentage(part: 5, of: 0), 0, "a zero denominator must not divide")
        XCTAssertEqual(SaturatingMath.percentage(part: 5, of: -10), 0, "a negative denominator has no answer")
        XCTAssertEqual(SaturatingMath.percentage(part: -5, of: 10), 0, "a negative part clamps up to zero")
        XCTAssertEqual(SaturatingMath.percentage(part: 50, of: 10), 100, "an oversized part clamps to the whole")
        XCTAssertEqual(SaturatingMath.percentage(part: 1, of: 3), 33)
        XCTAssertEqual(SaturatingMath.percentage(part: 3, of: 3), 100)
        // The `Int.min / -1` trap is unreachable because the divisor is the clamped,
        // strictly-positive `whole`. Pin it with the values that would reach it.
        XCTAssertEqual(SaturatingMath.percentage(part: Int.min, of: Int.max), 0)
        XCTAssertEqual(SaturatingMath.percentage(part: Int.max, of: Int.max), 100)
    }

    /// Regression. The first implementation reached for `SaturatingMath.multiply` here,
    /// which clamps `100 * Int.max` to `Int.max` and then divides it by `Int.max` — so a
    /// fully-migrated graph reported **1%**. Clamping an intermediate is silent data
    /// corruption whenever the value is a ratio rather than the answer itself.
    func testPercentageIsExactAtTheScaleWhereASaturatedMultiplyWouldLie() {
        XCTAssertEqual(
            SaturatingMath.multiply(Int.max, 100), Int.max,
            "precondition: a saturating multiply really does clamp at this scale"
        )
        XCTAssertEqual(SaturatingMath.percentage(part: Int.max, of: Int.max), 100)

        // Quarters of a number far past `Int.max / 100`, chosen so the exact answer is a
        // whole percentage and any loss of precision shows up as an off-by-one.
        let quarter = Int.max / 4
        let whole = SaturatingMath.multiply(quarter, 4)
        XCTAssertLessThan(whole, Int.max, "precondition: the denominator did not saturate")
        XCTAssertGreaterThan(quarter, Int.max / 100, "precondition: 100 * part overflows Int")
        XCTAssertEqual(SaturatingMath.percentage(part: quarter, of: whole), 25)
        XCTAssertEqual(SaturatingMath.percentage(part: quarter * 2, of: whole), 50)
        XCTAssertEqual(SaturatingMath.percentage(part: quarter * 3, of: whole), 75)
        XCTAssertEqual(SaturatingMath.percentage(part: whole, of: whole), 100)
    }

    func testDoubleConversionHandlesEveryValueThatWouldTrap() {
        XCTAssertEqual(SaturatingMath.int(Double.nan), 0)
        XCTAssertEqual(SaturatingMath.int(Double.signalingNaN), 0)
        XCTAssertEqual(SaturatingMath.int(.infinity), Int.max)
        XCTAssertEqual(SaturatingMath.int(-.infinity), Int.min)
        XCTAssertEqual(SaturatingMath.int(3.9), 3, "truncates toward zero")
        XCTAssertEqual(SaturatingMath.int(-3.9), -3, "truncates toward zero, not floor")
        XCTAssertEqual(SaturatingMath.int(0), 0)
    }

    /// The specific bug the doc comment on `SaturatingMath.int` calls out: `Double(Int.max)`
    /// rounds *up* to 2^63, so a guard written as `value <= Double(Int.max)` admits a value
    /// that `Int(_:)` then traps on. `Int(exactly:)` is the version that does not.
    func testDoubleAtTheIntMaxBoundaryDoesNotTrap() {
        let roundedUpIntMax = Double(Int.max)
        XCTAssertGreaterThan(
            roundedUpIntMax, 9.223372036854775e18,
            "precondition: Double(Int.max) is 2^63, one above Int.max"
        )
        XCTAssertNil(Int(exactly: roundedUpIntMax), "precondition: 2^63 is not representable as Int")
        XCTAssertEqual(SaturatingMath.int(roundedUpIntMax), Int.max)
        XCTAssertEqual(SaturatingMath.int(-roundedUpIntMax), Int.min)
        XCTAssertEqual(SaturatingMath.int(1e300), Int.max)
        XCTAssertEqual(SaturatingMath.int(-1e300), Int.min)
    }

    func testClampHonoursBothEnds() {
        XCTAssertEqual(SaturatingMath.clamp(-5, to: 0...100), 0)
        XCTAssertEqual(SaturatingMath.clamp(500, to: 0...100), 100)
        XCTAssertEqual(SaturatingMath.clamp(42, to: 0...100), 42)
    }
}
