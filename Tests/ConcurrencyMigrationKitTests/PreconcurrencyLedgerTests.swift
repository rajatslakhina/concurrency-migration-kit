import XCTest
@testable import ConcurrencyMigrationKit

final class PreconcurrencyLedgerTests: XCTestCase {

    private let today = Fixture.date("2026-09-29")

    private func entry(
        _ module: ModuleID,
        imports imported: ModuleID,
        reviewBy: String = "2026-12-31"
    ) -> ExemptionEntry {
        ExemptionEntry(
            module: module,
            importedModule: imported,
            owner: "platform-team",
            reason: "Sendable conformance pending upstream.",
            reviewBy: Fixture.date(reviewBy)
        )
    }

    func testAnExemptionAgainstAnUnmigratedDependencyIsJustified() throws {
        let graph = try Fixture.withInversion()
        let audit = PreconcurrencyLedger.audit(
            [entry("Reports", imports: "Logging")], against: graph, asOf: today
        )
        XCTAssertEqual(audit.justified.count, 1)
        XCTAssertEqual(audit.stale, [])
        XCTAssertTrue(audit.passesGate)
    }

    /// The bug the whole package exists for: the dependency migrated, the suppression did
    /// not move, and nothing in the toolchain says a word. From here on it is discarding
    /// diagnostics about `Reports`' own code.
    func testAnExemptionBecomesStaleTheMomentItsDependencyMigrates() throws {
        let before = try Fixture.withInversion()
        let ledger = [entry("Reports", imports: "Logging")]
        XCTAssertTrue(PreconcurrencyLedger.audit(ledger, against: before, asOf: today).passesGate)

        // The only thing that changes is Logging's posture. The ledger is untouched.
        let after = try ModuleGraph([
            ModuleNode(id: "Logging", posture: .swift6, dependencies: [], openDiagnostics: 0),
            ModuleNode(id: "Analytics", posture: .swift6, dependencies: [], openDiagnostics: 0),
            ModuleNode(id: "Reports", posture: .swift6, dependencies: ["Logging", "Analytics"]),
        ])
        let audit = PreconcurrencyLedger.audit(ledger, against: after, asOf: today)

        XCTAssertEqual(audit.stale.count, 1)
        XCTAssertEqual(audit.justified, [])
        XCTAssertFalse(audit.passesGate, "a stale suppression must fail the gate")
        XCTAssertEqual(audit.gateFailures.count, 1)
        // `XCTAssertEqual` does not halt the test, so subscripting here would trap and kill
        // the whole process if this ever regressed to empty. `XCTUnwrap` reports instead.
        let failure = try XCTUnwrap(audit.gateFailures.first)
        XCTAssertTrue(failure.contains("platform-team"), "the failure must name an owner")
    }

    func testAnEntryPastItsReviewDateIsOverdueButDoesNotFailTheGate() throws {
        let graph = try Fixture.withInversion()
        let audit = PreconcurrencyLedger.audit(
            [entry("Reports", imports: "Logging", reviewBy: "2026-01-01")],
            against: graph, asOf: today
        )
        XCTAssertEqual(audit.overdue.count, 1)
        XCTAssertTrue(
            audit.passesGate,
            "an overdue entry is still load-bearing; failing the build punishes the blocked team"
        )
    }

    /// Precedence: an entry that is both stale and overdue is reported as stale, because
    /// that is the finding that changes what you do — delete it, today, safely.
    func testStalenessOutranksTheReviewDate() throws {
        let graph = try ModuleGraph([
            ModuleNode(id: "Logging", posture: .swift6),
            ModuleNode(id: "Reports", posture: .swift6, dependencies: ["Logging"]),
        ])
        let audit = PreconcurrencyLedger.audit(
            [entry("Reports", imports: "Logging", reviewBy: "2020-01-01")],
            against: graph, asOf: today
        )
        XCTAssertEqual(audit.stale.count, 1)
        XCTAssertEqual(audit.overdue, [])
    }

    func testTheReviewDateBoundaryIsNotOffByOne() throws {
        let graph = try Fixture.withInversion()
        let onTheDay = PreconcurrencyLedger.audit(
            [entry("Reports", imports: "Logging", reviewBy: "2026-09-29")],
            against: graph, asOf: today
        )
        XCTAssertEqual(onTheDay.overdue, [], "the review date itself is not yet overdue")
        XCTAssertEqual(onTheDay.justified.count, 1)

        let dayAfter = PreconcurrencyLedger.audit(
            [entry("Reports", imports: "Logging", reviewBy: "2026-09-28")],
            against: graph, asOf: today
        )
        XCTAssertEqual(dayAfter.overdue.count, 1)
    }

    func testAnEntryNamingAModuleOutsideTheGraphIsIncoherent() throws {
        let graph = try Fixture.withInversion()
        let audit = PreconcurrencyLedger.audit(
            [entry("Ghost", imports: "Logging"), entry("Reports", imports: "Phantom")],
            against: graph, asOf: today
        )
        XCTAssertEqual(audit.incoherent.count, 2)
        XCTAssertFalse(audit.passesGate)
        XCTAssertEqual(audit.justified, [], "an incoherent entry never counts as justified")
    }

    func testAnEntryForANonDependencyIsIncoherent() throws {
        let graph = try Fixture.withInversion()
        // Analytics is in the graph, and Logging is in the graph, but Logging does not
        // depend on Analytics — so this @preconcurrency import cannot exist.
        let audit = PreconcurrencyLedger.audit(
            [entry("Logging", imports: "Analytics")], against: graph, asOf: today
        )
        XCTAssertEqual(audit.audited.first?.status, .notADependency)
        XCTAssertFalse(audit.passesGate)
    }

    /// The half a ledger cannot catch on its own. `Reports` went ahead of `Logging` and
    /// wrote nothing down; with an empty ledger the audit must still find it.
    func testAnInversionWithNoLedgerEntryIsReported() throws {
        let graph = try Fixture.withInversion()
        let audit = PreconcurrencyLedger.audit([], against: graph, asOf: today)

        XCTAssertEqual(audit.unrecordedInversions.count, 1)
        XCTAssertEqual(audit.unrecordedInversions.first?.module, "Reports")
        XCTAssertEqual(audit.unrecordedInversions.first?.dependency, "Logging")
        XCTAssertFalse(audit.passesGate)
        XCTAssertTrue(audit.gateFailures.contains { $0.contains("Unrecorded inversion") })
    }

    func testRecordingTheInversionClearsTheUnrecordedFinding() throws {
        let graph = try Fixture.withInversion()
        let audit = PreconcurrencyLedger.audit(
            [entry("Reports", imports: "Logging")], against: graph, asOf: today
        )
        XCTAssertEqual(audit.unrecordedInversions, [], "the entry accounts for the inversion")
        XCTAssertTrue(audit.passesGate)
    }

    /// An incoherent entry must not be able to launder a real inversion into silence.
    func testAnIncoherentEntryDoesNotSuppressTheInversionItMisnames() throws {
        let graph = try Fixture.withInversion()
        let audit = PreconcurrencyLedger.audit(
            [entry("Reports", imports: "Phantom")], against: graph, asOf: today
        )
        XCTAssertEqual(audit.incoherent.count, 1)
        XCTAssertEqual(
            audit.unrecordedInversions.count, 1,
            "the real Reports -> Logging inversion is still unaccounted for"
        )
        XCTAssertEqual(audit.gateFailures.count, 2)
    }

    func testAuditOutputIsSortedSoCIDiffsAreStable() throws {
        let graph = try Fixture.layeredApp()
        let entries = [
            entry("Sync", imports: "Persistence"),
            entry("Checkout", imports: "Networking"),
            entry("Sync", imports: "Networking"),
        ]
        let audit = PreconcurrencyLedger.audit(entries, against: graph, asOf: today)
        XCTAssertEqual(
            audit.audited.map { "\($0.entry.module)->\($0.entry.importedModule)" },
            ["Checkout->Networking", "Sync->Networking", "Sync->Persistence"]
        )
    }

    func testAGraphWithNoInversionsAndNoLedgerPasses() throws {
        let graph = try Fixture.layeredApp()
        let audit = PreconcurrencyLedger.audit([], against: graph, asOf: today)
        XCTAssertEqual(audit.unrecordedInversions, [])
        XCTAssertTrue(audit.passesGate)
        XCTAssertEqual(audit.gateFailures, [])
    }

    func testInversionsAreDetectedAcrossEveryPostureStep() throws {
        let graph = try ModuleGraph([
            ModuleNode(id: "Bottom", posture: .swift5Unchecked),
            ModuleNode(id: "Middle", posture: .swift5Complete, dependencies: ["Bottom"]),
            ModuleNode(id: "Top", posture: .swift5Targeted, dependencies: ["Middle"]),
        ])
        let inversions = IsolationAuditor.inversions(in: graph)
        XCTAssertEqual(inversions.count, 1, "only Middle sits above what it depends on")
        XCTAssertEqual(inversions.first?.module, "Middle")
        XCTAssertEqual(inversions.first?.dependencyPosture, .swift5Unchecked)
    }
}
