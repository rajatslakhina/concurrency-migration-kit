import XCTest
@testable import ConcurrencyMigrationKit

/// The README claims `MigrationPlan.violations(against:)` catches a plan that violates the
/// dependency order. A validator that returned `[]` unconditionally would satisfy every
/// test in `MigrationPlannerTests`, because the real planner never produces a bad plan.
///
/// So this file does the opposite: it feeds the validator plans that are *known to be
/// wrong* — one from a planner that ships in the library precisely to be wrong, and one
/// hand-built per violation case — and requires the validator to reject each of them. If
/// the validator ever regresses to "always passes", every test here fails.
final class PlanValidatorFalsificationTests: XCTestCase {

    // MARK: - The deliberately broken planner

    func testNaivePlannerIsRejectedOnAGraphWhereAlphabeticalOrderIsWrong() throws {
        let graph = try Fixture.alphabeticalTrap()
        let plan = NaiveWavePlanner(waveSize: 1).plan(for: graph)

        XCTAssertEqual(
            plan.scheduledModules, ["Alpha", "Zulu"],
            "precondition: the naive planner really does sort by name"
        )
        let violations = plan.violations(against: graph)
        XCTAssertTrue(
            violations.contains(
                .dependencyNotScheduledEarlier(
                    dependency: "Zulu", dependent: "Alpha", dependencyWave: 1, dependentWave: 0
                )
            ),
            "expected the out-of-order edge to be caught, got \(violations)"
        )
        XCTAssertFalse(plan.isValid(against: graph))
    }

    /// The same-wave case. A wave is worked in parallel, so a dependency landing beside its
    /// dependent gives that dependent nothing to build against — it must be *strictly*
    /// earlier. A validator using `>` instead of `>=` would pass this and be wrong.
    func testDependencyInTheSameWaveAsItsDependentIsAViolation() throws {
        let graph = try Fixture.alphabeticalTrap()
        let plan = NaiveWavePlanner(waveSize: 8).plan(for: graph)

        XCTAssertEqual(plan.waves.count, 1, "precondition: both modules land in one wave")
        XCTAssertTrue(
            plan.violations(against: graph).contains(
                .dependencyNotScheduledEarlier(
                    dependency: "Zulu", dependent: "Alpha", dependencyWave: 0, dependentWave: 0
                )
            ),
            "same-wave must not be accepted as 'earlier'"
        )
    }

    func testNaivePlannerIsRejectedOnGeneratedGraphsFarMoreOftenThanNot() throws {
        var rejected = 0
        var total = 0
        for seed in 0..<120 {
            var generator = SeededGenerator(seed: UInt64(seed) &* 0x1234_5677)
            let graph = try Fixture.randomDAG(
                moduleCount: 8 + (seed % 12), migratedChance: 10, using: &generator
            )
            guard graph.pendingModules.count > 1 else { continue }
            total += 1
            if !NaiveWavePlanner(waveSize: 1 + (seed % 3)).plan(for: graph).isValid(against: graph) {
                rejected += 1
            }
            // The real planner must survive the identical graph, so a "reject everything"
            // validator cannot pass this test either.
            XCTAssertTrue(
                MigrationPlanner().plan(for: graph).isValid(against: graph),
                "seed \(seed): the real planner's output was rejected"
            )
        }
        XCTAssertGreaterThan(total, 100, "precondition: enough graphs had real work in them")
        XCTAssertGreaterThan(
            rejected, total * 3 / 4,
            "the naive planner was accepted \(total - rejected)/\(total) times; the validator is too lenient"
        )
    }

    /// The real planner on the same trap graph. Without this, every assertion above would
    /// also be satisfied by a validator that rejects everything.
    func testRealPlannerPassesTheGraphTheNaivePlannerFails() throws {
        let graph = try Fixture.alphabeticalTrap()
        let plan = MigrationPlanner().plan(for: graph)
        XCTAssertEqual(plan.scheduledModules, ["Zulu", "Alpha"], "dependency first")
        XCTAssertEqual(plan.violations(against: graph), [])
    }

    // MARK: - One hand-built counter-example per violation case

    private func planned(_ id: ModuleID) -> PlannedModule {
        PlannedModule(id: id, openDiagnostics: 0, blastRadius: 0, owningTeam: "T")
    }

    private func wave(_ index: Int, _ ids: [ModuleID]) -> MigrationWave {
        MigrationWave(index: index, modules: ids.map(planned))
    }

    func testDependencyNeverScheduledIsCaught() throws {
        let graph = try Fixture.alphabeticalTrap()
        let plan = MigrationPlan(
            waves: [wave(0, ["Alpha"])], alreadyMigrated: [], unreachable: []
        )
        let violations = plan.violations(against: graph)
        XCTAssertTrue(violations.contains(.dependencyNeverScheduled(dependency: "Zulu", dependent: "Alpha")))
        XCTAssertTrue(violations.contains(.pendingModuleMissingFromPlan("Zulu")))
    }

    func testModuleScheduledTwiceIsCaughtOnce() throws {
        let graph = try Fixture.alphabeticalTrap()
        let plan = MigrationPlan(
            waves: [wave(0, ["Zulu"]), wave(1, ["Alpha", "Zulu"])],
            alreadyMigrated: [], unreachable: []
        )
        let violations = plan.violations(against: graph)
        XCTAssertEqual(
            violations.filter { $0 == .moduleScheduledTwice("Zulu") }.count, 1,
            "a duplicate must be reported exactly once, not once per extra appearance"
        )
    }

    func testSchedulingAnAlreadyMigratedModuleIsCaught() throws {
        let graph = try Fixture.layeredApp()
        var waves = MigrationPlanner().plan(for: graph).waves
        guard let first = waves.first else { return XCTFail("fixture should produce waves") }
        waves[0] = MigrationWave(index: 0, modules: first.modules + [planned("CoreTypes")])
        let plan = MigrationPlan(waves: waves, alreadyMigrated: ["CoreTypes"], unreachable: [])
        XCTAssertTrue(plan.violations(against: graph).contains(.alreadyMigratedModuleScheduled("CoreTypes")))
    }

    func testSchedulingAnUnknownModuleIsCaught() throws {
        let graph = try Fixture.alphabeticalTrap()
        let plan = MigrationPlan(
            waves: [wave(0, ["Zulu"]), wave(1, ["Alpha", "Phantom"])],
            alreadyMigrated: [], unreachable: []
        )
        XCTAssertTrue(plan.violations(against: graph).contains(.unknownModuleScheduled("Phantom")))
    }

    func testNonContiguousWaveIndicesAreCaught() throws {
        let graph = try Fixture.alphabeticalTrap()
        let plan = MigrationPlan(
            waves: [wave(0, ["Zulu"]), wave(7, ["Alpha"])], alreadyMigrated: [], unreachable: []
        )
        XCTAssertTrue(plan.violations(against: graph).contains(.waveIndicesNotContiguous([0, 7])))
    }

    func testAStuckPlanSurfacesAsMissingModulesRatherThanSilence() throws {
        let graph = try Fixture.layeredApp()
        let plan = MigrationPlan(waves: [], alreadyMigrated: ["CoreTypes"], unreachable: graph.pendingModules)
        let violations = plan.violations(against: graph)
        XCTAssertEqual(
            violations.count, graph.pendingModules.count,
            "every unscheduled pending module must be reported"
        )
    }
}
