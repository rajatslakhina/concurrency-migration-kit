import XCTest
@testable import ConcurrencyMigrationKit

final class ModuleGraphTests: XCTestCase {

    func testEmptyGraphIsUsableRatherThanSpecialCased() throws {
        let graph = try ModuleGraph([])
        XCTAssertTrue(graph.isEmpty)
        XCTAssertEqual(graph.count, 0)
        XCTAssertEqual(graph.migratedPercentage, 0, "must not divide by zero")
        XCTAssertEqual(graph.pendingModules, [])
        XCTAssertEqual(graph.blastRadius(of: "Nope"), 0)
        XCTAssertEqual(graph.readiness(of: "Nope"), .alreadyMigrated)
    }

    func testDuplicateModuleIsRejected() {
        XCTAssertThrowsError(
            try ModuleGraph([
                ModuleNode(id: "A", posture: .swift6),
                ModuleNode(id: "A", posture: .swift5Targeted),
            ])
        ) { error in
            XCTAssertEqual(error as? GraphError, .duplicateModule("A"))
        }
    }

    func testDanglingDependencyIsRejectedBeforeCycleDetection() {
        XCTAssertThrowsError(
            try ModuleGraph([
                ModuleNode(id: "A", posture: .swift6, dependencies: ["Ghost"])
            ])
        ) { error in
            XCTAssertEqual(
                error as? GraphError,
                .unknownDependency(module: "A", dependency: "Ghost"),
                "the error must name the dangling edge, not a phantom cycle"
            )
        }
    }

    func testSelfDependencyIsReportedAsACycle() {
        XCTAssertThrowsError(
            try ModuleGraph([ModuleNode(id: "A", posture: .swift6, dependencies: ["A"])])
        ) { error in
            XCTAssertEqual(error as? GraphError, .dependencyCycle(["A"]))
        }
    }

    func testCycleErrorCarriesTheActualPath() {
        XCTAssertThrowsError(
            try ModuleGraph([
                ModuleNode(id: "A", posture: .swift6, dependencies: ["B"]),
                ModuleNode(id: "B", posture: .swift6, dependencies: ["C"]),
                ModuleNode(id: "C", posture: .swift6, dependencies: ["A"]),
                ModuleNode(id: "Unrelated", posture: .swift6),
            ])
        ) { error in
            guard case .dependencyCycle(let path) = error as? GraphError else {
                return XCTFail("expected a cycle, got \(error)")
            }
            XCTAssertEqual(
                Set(path), ["A", "B", "C"],
                "the path must be the three modules in the cycle, not the whole graph"
            )
            XCTAssertFalse(path.contains("Unrelated"))
        }
    }

    /// A recursive DFS blows the stack somewhere in the low thousands of frames. The
    /// traversal is iterative specifically so the tool that tells you your graph is
    /// unhealthy does not crash on an unhealthy graph.
    func testDeepChainDoesNotOverflowTheStack() throws {
        let depth = 5_000
        var nodes: [ModuleNode] = [ModuleNode(id: "M0", posture: .swift6)]
        for index in 1..<depth {
            nodes.append(
                ModuleNode(
                    id: ModuleID("M\(index)"),
                    posture: .swift6,
                    dependencies: [ModuleID("M\(index - 1)")]
                )
            )
        }
        let graph = try ModuleGraph(nodes)
        XCTAssertEqual(graph.count, depth)
        XCTAssertEqual(graph.transitiveDependencies(of: ModuleID("M\(depth - 1)")).count, depth - 1)
        XCTAssertEqual(graph.transitiveDependents(of: "M0").count, depth - 1)
    }

    func testDeepCycleIsStillDetected() {
        let depth = 3_000
        var nodes: [ModuleNode] = []
        for index in 0..<depth {
            let next = (index + 1) % depth
            nodes.append(
                ModuleNode(
                    id: ModuleID("M\(index)"),
                    posture: .swift6,
                    dependencies: [ModuleID("M\(next)")]
                )
            )
        }
        XCTAssertThrowsError(try ModuleGraph(nodes)) { error in
            guard case .dependencyCycle(let path) = error as? GraphError else {
                return XCTFail("expected a cycle, got \(error)")
            }
            XCTAssertEqual(path.count, depth)
        }
    }

    func testDiamondIsWalkedOnceAndNotDoubleCounted() throws {
        let graph = try ModuleGraph([
            ModuleNode(id: "Base", posture: .swift5Targeted),
            ModuleNode(id: "Left", posture: .swift5Targeted, dependencies: ["Base"]),
            ModuleNode(id: "Right", posture: .swift5Targeted, dependencies: ["Base"]),
            ModuleNode(id: "Top", posture: .swift5Targeted, dependencies: ["Left", "Right"]),
        ])
        XCTAssertEqual(graph.transitiveDependents(of: "Base"), ["Left", "Right", "Top"])
        XCTAssertEqual(graph.blastRadius(of: "Base"), 3)
        XCTAssertEqual(graph.transitiveDependencies(of: "Top"), ["Left", "Right", "Base"])
    }

    func testBlastRadiusCountsOnlyUnmigratedDependents() throws {
        let graph = try ModuleGraph([
            ModuleNode(id: "Base", posture: .swift5Targeted),
            ModuleNode(id: "Done", posture: .swift6, dependencies: ["Base"]),
            ModuleNode(id: "Waiting", posture: .swift5Targeted, dependencies: ["Base"]),
        ])
        XCTAssertEqual(graph.transitiveDependents(of: "Base").count, 2)
        XCTAssertEqual(
            graph.blastRadius(of: "Base"), 1,
            "a dependent that already went ahead is not waiting on anything"
        )
    }

    func testReadinessDistinguishesBlockedFromReady() throws {
        let graph = try Fixture.layeredApp()
        XCTAssertEqual(graph.readiness(of: "CoreTypes"), .alreadyMigrated)
        XCTAssertEqual(graph.readiness(of: "Logging"), .ready)
        XCTAssertEqual(
            graph.readiness(of: "Networking"), .blocked(by: ["Logging"]),
            "CoreTypes is done, so only Logging blocks it — and the list must be sorted"
        )
        XCTAssertEqual(graph.readiness(of: "AppShell"), .blocked(by: ["Checkout", "Profile", "Sync"]))
    }

    func testNegativeDiagnosticCountsAreNormalisedAtTheBoundary() throws {
        let graph = try ModuleGraph([ModuleNode(id: "A", posture: .swift5Targeted, openDiagnostics: -50)])
        XCTAssertEqual(graph.node("A")?.openDiagnostics, 0)
    }

    func testMigratedPercentageIsWholeGraphRelative() throws {
        let graph = try Fixture.layeredApp()
        XCTAssertEqual(graph.count, 8)
        XCTAssertEqual(graph.migratedModules, ["CoreTypes"])
        XCTAssertEqual(graph.migratedPercentage, 12)
    }
}
