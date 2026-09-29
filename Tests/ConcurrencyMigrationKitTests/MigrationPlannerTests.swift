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

    /// Covers one specific thing: the order nodes are handed to `ModuleGraph.init` does not
    /// leak into the plan. It does **not** exercise the ranking's id tie-break — the
    /// planner reads `graph.pendingModules`, which is already sorted, so the shuffle is
    /// washed out before the comparator sees it. `testRankingFallsBackToAStableIdOrder`
    /// below is the test that actually pins the tie-break.
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

    /// The ranking's third key, pinned directly.
    ///
    /// Twelve leaf modules with identical blast radius (all zero) and identical cost, so
    /// nothing but the id comparison can decide their order. Delete `return lhs < rhs`
    /// from the comparator and the order falls back to `Set` iteration, which matches
    /// sorted order for twelve elements roughly once in 479,001,600 runs.
    func testRankingFallsBackToAStableIdOrderWhenRadiusAndCostTie() throws {
        let names = [
            "Quebec", "Alpha", "Zulu", "Mike", "Bravo", "Yankee",
            "Delta", "Xray", "Charlie", "November", "Echo", "Sierra",
        ]
        let graph = try ModuleGraph(
            names.map { ModuleNode(id: ModuleID($0), posture: .swift5Targeted, openDiagnostics: 5) }
        )
        let plan = MigrationPlanner().plan(for: graph)
        XCTAssertEqual(plan.waves.count, 1, "every module is a leaf, so they all go in wave 1")
        XCTAssertEqual(plan.waves.first?.modules.map(\.id.rawValue), names.sorted())
    }

    /// Everything public here is an immutable value, so this cannot fail by data race
    /// today. What it does pin is that those values are genuinely `Sendable` in use — the
    /// compiler has to accept them crossing 64 task boundaries — and that planning holds
    /// no hidden shared state. If someone later adds a memo table to the planner for the
    /// blast radii, this is the test that stops it being a silent data race.
    func testPlanningTheSameGraphFromManyTasksAtOnceAgrees() async throws {
        let graph = try Fixture.layeredApp()
        let planner = MigrationPlanner(policy: MigrationPolicy(diagnosticsPerWave: 30))
        let reference = planner.plan(for: graph)

        let plans = await withTaskGroup(of: MigrationPlan.self) { group in
            for _ in 0..<64 {
                group.addTask { planner.plan(for: graph) }
            }
            var collected: [MigrationPlan] = []
            for await plan in group { collected.append(plan) }
            return collected
        }

        XCTAssertEqual(plans.count, 64)
        for (index, plan) in plans.enumerated() {
            XCTAssertEqual(plan, reference, "task \(index) produced a different plan")
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
