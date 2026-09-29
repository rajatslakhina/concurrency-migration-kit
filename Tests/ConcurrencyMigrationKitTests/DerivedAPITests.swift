import XCTest
@testable import ConcurrencyMigrationKit

/// Coverage for the derived and presentational API — the properties the dashboard renders
/// and the strings a CI gate prints.
///
/// These existed and were exercised by nothing. Each one could be replaced with a constant
/// and the whole suite stayed green, which is the same failure mode as a vacuous test:
/// the coverage report looked fine and the behaviour was unguarded. Every assertion below
/// was checked by breaking the implementation first and confirming it fails.
final class DerivedAPITests: XCTestCase {

    func testWaveTotalDiagnosticsSumsItsModules() throws {
        let graph = try Fixture.layeredApp()
        let plan = MigrationPlanner(policy: .unbounded).plan(for: graph)
        guard let first = plan.waves.first else { return XCTFail("expected at least one wave") }

        // Logging (6) + Persistence (14) — the first wave of the layered fixture.
        XCTAssertEqual(first.totalDiagnostics, 20)
        XCTAssertEqual(
            first.totalDiagnostics,
            first.modules.reduce(0) { $0 + $1.openDiagnostics },
            "the header number must be the sum the dashboard claims it is"
        )
    }

    func testWaveTotalDiagnosticsSaturatesRatherThanTrapping() {
        let wave = MigrationWave(index: 0, modules: [
            PlannedModule(id: "A", openDiagnostics: .max, blastRadius: 0, owningTeam: "T"),
            PlannedModule(id: "B", openDiagnostics: .max, blastRadius: 0, owningTeam: "T"),
        ])
        XCTAssertEqual(wave.totalDiagnostics, Int.max, "plain `+` would trap here")
    }

    /// The doc comment's whole point — "a wave that is one team five times over is a queue
    /// wearing a wave's clothes" — depends on the dedupe. Without it the dashboard would
    /// render "Parallel across: Data, Data, Data".
    func testWaveTeamsAreDeduplicatedAndSorted() {
        let wave = MigrationWave(index: 0, modules: [
            PlannedModule(id: "A", openDiagnostics: 1, blastRadius: 0, owningTeam: "Payments"),
            PlannedModule(id: "B", openDiagnostics: 1, blastRadius: 0, owningTeam: "Data"),
            PlannedModule(id: "C", openDiagnostics: 1, blastRadius: 0, owningTeam: "Data"),
            PlannedModule(id: "D", openDiagnostics: 1, blastRadius: 0, owningTeam: "Platform"),
        ])
        XCTAssertEqual(wave.teams, ["Data", "Payments", "Platform"])
    }

    func testEmptyWaveHasNoTeamsAndNoDiagnostics() {
        let wave = MigrationWave(index: 0, modules: [])
        XCTAssertEqual(wave.teams, [])
        XCTAssertEqual(wave.totalDiagnostics, 0)
    }

    /// `displayName` is rendered in every dashboard row *and* interpolated into
    /// `gateFailures` strings, so a wrong one is wrong in CI output too.
    func testEveryPostureHasItsOwnDisplayName() {
        let names = ConcurrencyPosture.allCases.map(\.displayName)
        XCTAssertEqual(names, [
            "Swift 5 (unchecked)",
            "Swift 5 (targeted)",
            "Swift 5 (complete)",
            "Swift 6",
        ])
        XCTAssertEqual(Set(names).count, ConcurrencyPosture.allCases.count, "names must be distinct")
    }

    func testPostureOrderingAndMigratedFlag() {
        XCTAssertTrue(ConcurrencyPosture.swift5Unchecked < .swift5Targeted)
        XCTAssertTrue(ConcurrencyPosture.swift5Targeted < .swift5Complete)
        XCTAssertTrue(ConcurrencyPosture.swift5Complete < .swift6)
        XCTAssertEqual(
            ConcurrencyPosture.allCases.filter(\.isMigrated), [.swift6],
            "only Swift 6 mode counts as migrated — `complete` emits warnings its own module can ignore"
        )
    }

    func testViolationDescriptionsNameTheModulesInvolved() {
        let violation = PlanViolation.dependencyNotScheduledEarlier(
            dependency: "Networking", dependent: "Checkout", dependencyWave: 2, dependentWave: 1
        )
        let text = violation.description
        XCTAssertTrue(text.contains("Networking"), text)
        XCTAssertTrue(text.contains("Checkout"), text)
        XCTAssertTrue(text.contains("wave 2") && text.contains("wave 1"), text)

        XCTAssertTrue(PlanViolation.moduleScheduledTwice("Sync").description.contains("Sync"))
        XCTAssertTrue(
            PlanViolation.pendingModuleMissingFromPlan("Profile").description.contains("Profile")
        )
    }

    func testGraphErrorDescriptionsRenderTheOffendingPath() {
        XCTAssertTrue(GraphError.duplicateModule("A").description.contains("A"))

        let unknown = GraphError.unknownDependency(module: "App", dependency: "Ghost").description
        XCTAssertTrue(unknown.contains("App") && unknown.contains("Ghost"), unknown)

        let cycle = GraphError.dependencyCycle(["A", "B", "C"]).description
        XCTAssertTrue(cycle.contains("A -> B -> C -> A"), "the cycle must close visibly: \(cycle)")
    }

    func testDirectDependentsAreTheImmediateNeighboursOnly() throws {
        let graph = try Fixture.layeredApp()
        XCTAssertEqual(graph.directDependents(of: "CoreTypes"), ["Networking", "Persistence"])
        XCTAssertEqual(
            graph.transitiveDependents(of: "CoreTypes").count, 6,
            "transitively it reaches much further than its direct neighbours"
        )
        XCTAssertEqual(graph.directDependents(of: "AppShell"), [], "nothing depends on the shell")
        XCTAssertEqual(graph.directDependents(of: "NotInGraph"), [])
    }

    func testReadinessConvenienceFlagMatchesTheCase() throws {
        let graph = try Fixture.layeredApp()
        XCTAssertTrue(graph.readiness(of: "Logging").isReady)
        XCTAssertFalse(graph.readiness(of: "Networking").isReady, "blocked is not ready")
        XCTAssertFalse(graph.readiness(of: "CoreTypes").isReady, "already migrated is not 'ready'")
    }

    func testPlanWaveLookupFindsTheRightWave() throws {
        let graph = try Fixture.layeredApp()
        let plan = MigrationPlanner(policy: .unbounded).plan(for: graph)
        XCTAssertEqual(plan.wave(containing: "Logging"), 0)
        XCTAssertNil(plan.wave(containing: "CoreTypes"), "already migrated, so never scheduled")
        XCTAssertNil(plan.wave(containing: "NotInGraph"))
        XCTAssertEqual(plan.scheduledModules.count, graph.pendingModules.count)
    }
}
