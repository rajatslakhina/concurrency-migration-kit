/// Whether a module can move to the Swift 6 language mode right now.
public enum MigrationReadiness: Sendable, Hashable {
    /// Already in Swift 6 language mode.
    case alreadyMigrated
    /// Every dependency is already in Swift 6 mode, so migrating creates no new
    /// `@preconcurrency` debt.
    case ready
    /// At least one dependency is not in Swift 6 mode yet. Migrating now would force an
    /// `@preconcurrency import` of each listed module. Sorted, never empty.
    case blocked(by: [ModuleID])

    public var isReady: Bool { self == .ready }
}

extension ModuleGraph {

    /// Whether `id` can migrate without taking on new suppression debt.
    ///
    /// Returns `.alreadyMigrated` for an id that is not in the graph as well as for one
    /// that is genuinely done — an unknown module has no work outstanding here, and the
    /// planner separately refuses to schedule ids it does not know.
    public func readiness(of id: ModuleID) -> MigrationReadiness {
        guard let module = nodes[id] else { return .alreadyMigrated }
        if module.posture.isMigrated { return .alreadyMigrated }
        let blockers = module.dependencies
            .filter { nodes[$0]?.posture.isMigrated != true }
            .sorted()
        return blockers.isEmpty ? .ready : .blocked(by: blockers)
    }

    /// How many not-yet-migrated modules are waiting, directly or transitively, on `id`.
    ///
    /// This is the planner's "unblock the most work first" signal. It counts only
    /// unmigrated dependents, because a dependent that is already in Swift 6 mode is not
    /// waiting on anything — it went ahead, which is an inversion the auditor reports
    /// rather than progress this number should take credit for.
    public func blastRadius(of id: ModuleID) -> Int {
        guard nodes[id] != nil else { return 0 }
        return transitiveDependents(of: id)
            .reduce(into: 0) { total, dependent in
                if nodes[dependent]?.posture.isMigrated != true {
                    total = SaturatingMath.add(total, 1)
                }
            }
    }

    /// Modules already in Swift 6 mode, sorted.
    public var migratedModules: [ModuleID] {
        identifiers.filter { nodes[$0]?.posture.isMigrated == true }
    }

    /// Modules not yet in Swift 6 mode, sorted.
    public var pendingModules: [ModuleID] {
        identifiers.filter { nodes[$0]?.posture.isMigrated != true }
    }

    /// Share of modules already in Swift 6 mode, as a whole-number percentage.
    /// An empty graph reports `0` rather than dividing by zero.
    public var migratedPercentage: Int {
        SaturatingMath.percentage(part: migratedModules.count, of: count)
    }
}

/// A dependent sitting at a *higher* posture than something it depends on.
///
/// This is the shape of every `@preconcurrency import` in a real codebase: somebody moved
/// a module forward before its dependency was ready and suppressed the fallout. The
/// inversion itself is not a bug — it is often the only way to make progress — but it is
/// debt, and it is the set the ledger has to account for.
public struct PostureInversion: Sendable, Hashable {
    public let module: ModuleID
    public let dependency: ModuleID
    public let modulePosture: ConcurrencyPosture
    public let dependencyPosture: ConcurrencyPosture
}

public enum IsolationAuditor {

    /// Every dependent/dependency pair where the dependent has moved ahead of what it
    /// depends on. Sorted by module then dependency, so the output is diffable in CI.
    public static func inversions(in graph: ModuleGraph) -> [PostureInversion] {
        var found: [PostureInversion] = []
        for id in graph.identifiers {
            guard let module = graph.node(id) else { continue }
            for dependency in module.dependencies.sorted() {
                guard let dependencyNode = graph.node(dependency) else { continue }
                guard module.posture > dependencyNode.posture else { continue }
                found.append(
                    PostureInversion(
                        module: id,
                        dependency: dependency,
                        modulePosture: module.posture,
                        dependencyPosture: dependencyNode.posture
                    )
                )
            }
        }
        return found
    }
}
