import XCTest
@testable import ConcurrencyMigrationKit

final class MigrationPlannerTests: XCTestCase {

    func testPlanForALayeredAppRespectsEveryEdge() throws {
        let graph = try Fixture.layeredApp()
        let plan = MigrationPlanner().plan(for: graph)

        XCTAssertEqual(plan.violations(against: graph), [], "the planner's own output must validate")
        XCTAssertEqual(plan.unreachable, [], "an acyclic graph always has a next wave")
        XCTAssertEqual(
            Set(plan.scheduledModules), Set(graph.pendingModules),
            "every pending module is scheduled exactly once"
        )
        XCTAssertEqual(plan.scheduledModules.count, graph.pendingModules.count)
        XCTAssertEqual(plan.alreadyMigrated, ["CoreTypes"])

        // Spot-check the ordering the edges force, rather than pinning the whole schedule:
        // a pinned schedule would fail on any harmless ranking change.
        let waveOf = { (id: ModuleID) -> Int in plan.wave(containing: id) ?? -1 }
        XCTAssertLessThan(waveOf("Logging"), waveOf("Networking"))
        XCTAssertLessThan(waveOf("Networking"), waveOf("Sync"))
        XCTAssertLessThan(waveOf("Persistence"), waveOf("Sync"))
        XCTAssertLessThan(waveOf("Sync"), waveOf("AppShell"))
        XCTAssertLessThan(waveOf("Checkout"), waveOf("AppShell"))
    }

    func testEmptyAndFullyMigratedGraphsPlanToNothing() throws {
        let empty = try ModuleGraph([])
        XCTAssertEqual(MigrationPlanner().plan(for: empty).waves.count, 0)

        let done = try ModuleGraph([
            ModuleNode(id: "A", posture: .swift6),
            ModuleNode(id: "B", posture: .swift6, dependencies: ["A"]),
        ])
        let plan = MigrationPlanner().plan(for: done)
        XCTAssertEqual(plan.waves, [])
        XCTAssertEqual(plan.alreadyMigrated, ["A", "B"])
        XCTAssertEqual(plan.violations(against: done), [])
    }

    /// The ranking's third key exists so the plan does not depend on `Set` iteration order.
    /// Calling the planner twice in one process would prove nothing — the same `Set` hashes
    /// the same way within a process. Feeding the *same graph built from a different input
    /// ordering* is what actually exercises it.
    func testPlanIsIdenticalWhenTheSameGraphIsBuiltInADifferentOrder() throws {
        var generator = SeededGenerator(seed: 0xC0FF_EE01)
        let canonical = try Fixture.layeredApp()
        let reference = MigrationPlanner(policy: MigrationPolicy(diagnosticsPerWave: 30))
            .plan(for: canonical)

        for attempt in 0..<12 {
            let shuffled = canonical.identifiers
                .compactMap { canonical.node($0) }
                .shuffled(using: &generator)
            let rebuilt = try ModuleGraph(shuffled)
            let plan = MigrationPlanner(policy: MigrationPolicy(diagnosticsPerWave: 30))
                .plan(for: rebuilt)
            XCTAssertEqual(
                plan, reference,
                "attempt \(attempt): the plan changed with the input ordering"
            )
        }
    }

    func testTighterBudgetProducesMoreWavesWithoutBreakingOrder() throws {
        let graph = try Fixture.layeredApp()
        let unbounded = MigrationPlanner(policy: .unbounded).plan(for: graph)
        let tight = MigrationPlanner(policy: MigrationPolicy(diagnosticsPerWave: 10)).plan(for: graph)

        XCTAssertEqual(unbounded.violations(against: graph), [])
        XCTAssertEqual(tight.violations(against: graph), [])
        XCTAssertGreaterThan(
            tight.waves.count, unbounded.waves.count,
            "a budget smaller than the natural wave size must split waves"
        )
        XCTAssertEqual(Set(tight.scheduledModules), Set(unbounded.scheduledModules))
    }

    /// A single module carrying more diagnostics than the entire budget must still be
    /// admitted, or it is skipped in every wave forever and the planner never terminates.
    /// `XCTestCase` would hang rather than fail, so the assertion is really the fact that
    /// this test returns at all — plus the shape of what it returned.
    func testModuleLargerThanTheWholeBudgetIsStillScheduled() throws {
        let graph = try ModuleGraph([
            ModuleNode(id: "Huge", posture: .swift5Unchecked, openDiagnostics: 5_000),
            ModuleNode(id: "AlsoHuge", posture: .swift5Unchecked, dependencies: ["Huge"], openDiagnostics: 4_000),
        ])
        let plan = MigrationPlanner(policy: MigrationPolicy(diagnosticsPerWave: 1)).plan(for: graph)

        XCTAssertEqual(plan.waves.count, 2)
        XCTAssertEqual(plan.scheduledModules, ["Huge", "AlsoHuge"])
        XCTAssertEqual(plan.violations(against: graph), [])
        XCTAssertTrue(
            plan.waves.allSatisfy { !$0.modules.isEmpty },
            "an empty wave means the loop made no progress"
        )
    }

    func testZeroBudgetStillTerminatesAndSchedulesEverything() throws {
        let graph = try Fixture.layeredApp()
        let plan = MigrationPlanner(policy: MigrationPolicy(diagnosticsPerWave: 0)).plan(for: graph)
        XCTAssertEqual(Set(plan.scheduledModules), Set(graph.pendingModules))
        XCTAssertEqual(plan.violations(against: graph), [])
        XCTAssertTrue(plan.waves.allSatisfy { $0.modules.count == 1 })
    }

    func testNegativeBudgetIsClampedRatherThanTrusted() {
        XCTAssertEqual(MigrationPolicy(diagnosticsPerWave: -99).diagnosticsPerWave, 0)
        XCTAssertEqual(NaiveWavePlanner(waveSize: -4).waveSize, 1)
    }

    func testHigherBlastRadiusWinsOverLowerDiagnosticCount() throws {
        // `Hub` is more expensive than `Leaf` but unblocks two modules; `Leaf` unblocks none.
        let graph = try ModuleGraph([
            ModuleNode(id: "Hub", posture: .swift5Targeted, openDiagnostics: 20),
            ModuleNode(id: "Leaf", posture: .swift5Targeted, openDiagnostics: 1),
            ModuleNode(id: "UserA", posture: .swift5Targeted, dependencies: ["Hub"]),
            ModuleNode(id: "UserB", posture: .swift5Targeted, dependencies: ["Hub"]),
        ])
        let plan = MigrationPlanner(policy: MigrationPolicy(diagnosticsPerWave: 5)).plan(for: graph)
        XCTAssertEqual(
            plan.waves.first?.modules.first?.id, "Hub",
            "unblocking two modules beats being 19 diagnostics cheaper"
        )
    }

    func testCheaperModuleWinsWhenBlastRadiusTies() throws {
        let graph = try ModuleGraph([
            ModuleNode(id: "Expensive", posture: .swift5Targeted, openDiagnostics: 30),
            ModuleNode(id: "Cheap", posture: .swift5Targeted, openDiagnostics: 2),
        ])
        let plan = MigrationPlanner(policy: MigrationPolicy(diagnosticsPerWave: 1)).plan(for: graph)
        XCTAssertEqual(plan.waves.first?.modules.first?.id, "Cheap")
    }

    /// The invariant `MigrationPlan.unreachable` exists to detect: for any graph the
    /// initialiser accepted, the planner must schedule everything. Two hundred generated
    /// DAGs across a range of shapes, each replayable from its seed.
    func testGeneratedDAGsAlwaysPlanCompletelyAndValidly() throws {
        for seed in 0..<200 {
            var generator = SeededGenerator(seed: UInt64(seed) &* 0x9E37_79B9)
            let moduleCount = 1 + (seed % 24)
            let graph = try Fixture.randomDAG(
                moduleCount: moduleCount,
                migratedChance: (seed % 5) * 20,
                using: &generator
            )
            let budget = seed % 7 == 0 ? MigrationPolicy.unbounded : MigrationPolicy(diagnosticsPerWave: seed % 60)
            let plan = MigrationPlanner(policy: budget).plan(for: graph)

            XCTAssertEqual(plan.unreachable, [], "seed \(seed): planner got stuck")
            XCTAssertEqual(plan.violations(against: graph), [], "seed \(seed): invalid plan")
            XCTAssertEqual(
                Set(plan.scheduledModules), Set(graph.pendingModules),
                "seed \(seed): plan and graph disagree about what is pending"
            )
            XCTAssertEqual(
                plan.scheduledModules.count, Set(plan.scheduledModules).count,
                "seed \(seed): a module was scheduled twice"
            )
        }
    }
}
