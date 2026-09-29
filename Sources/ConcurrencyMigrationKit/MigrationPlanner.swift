/// How much work a single wave may contain.
public struct MigrationPolicy: Sendable, Hashable {
    /// Outstanding diagnostics a wave may contain before the planner closes it.
    ///
    /// This is the lever a lead actually has: not "what order", which the dependency graph
    /// decides, but "how much at once", which team capacity decides.
    public let diagnosticsPerWave: Int

    /// - Parameter diagnosticsPerWave: clamped to at least `0`. A budget of `0` does not
    ///   stall the plan — see the starvation guard in `MigrationPlanner.plan(for:)`.
    public init(diagnosticsPerWave: Int = .max) {
        self.diagnosticsPerWave = max(0, diagnosticsPerWave)
    }

    /// No budget: every ready module goes into the same wave.
    public static let unbounded = MigrationPolicy(diagnosticsPerWave: .max)
}

/// Anything that can turn a graph into a schedule.
///
/// The seam exists so the test suite can run a deliberately wrong planner through the
/// same validator as the real one — see `NaiveWavePlanner`.
public protocol WavePlanning: Sendable {
    func plan(for graph: ModuleGraph) -> MigrationPlan
}

/// Schedules a strict-concurrency migration as a sequence of parallelisable waves.
///
/// The rule the schedule obeys is narrow and deliberate: a module may migrate only once
/// every module it depends on has *already* migrated in an earlier wave. That is stricter
/// than "the compiler will let you" — you can always flip a module early and paper over
/// the result with `@preconcurrency import`. It is the stricter rule because the whole
/// point of the exercise is to finish with no suppressions left, and every early flip
/// creates one that somebody has to remember to remove.
///
/// Among the modules that are ready in a given wave, the ranking is:
///
/// 1. **Blast radius, descending.** Migrating the module that unblocks the most other
///    modules shortens the critical path.
/// 2. **Open diagnostics, ascending.** Among equally unblocking modules, cheapest first,
///    so a wave completes and the next one opens sooner.
/// 3. **Module id, ascending.** A total order, so the same graph always plans identically.
///    Without it the plan would depend on `Set` iteration order and no two CI runs would agree.
public struct MigrationPlanner: WavePlanning {
    public let policy: MigrationPolicy

    public init(policy: MigrationPolicy = .unbounded) {
        self.policy = policy
    }

    public func plan(for graph: ModuleGraph) -> MigrationPlan {
        let alreadyMigrated = graph.migratedModules
        var migrated = Set(alreadyMigrated)
        var remaining = Set(graph.pendingModules)

        guard !remaining.isEmpty else {
            return MigrationPlan(waves: [], alreadyMigrated: alreadyMigrated, unreachable: [])
        }

        // Blast radius is computed once, against the input graph, and held fixed for the
        // whole plan. Recomputing it per wave was the alternative: it is more precise,
        // because a module's radius shrinks as its dependents migrate, but it costs a
        // traversal per wave and it makes the ranking depend on decisions the plan has not
        // taken yet — which is exactly the kind of thing that makes a plan hard to argue
        // with in review. Fixed radii keep the ranking explainable from the graph alone.
        var radius: [ModuleID: Int] = [:]
        for id in graph.identifiers { radius[id] = graph.blastRadius(of: id) }

        var waves: [MigrationWave] = []
        var unreachable: [ModuleID] = []

        while !remaining.isEmpty {
            let ready = remaining
                .filter { id in
                    guard let node = graph.node(id) else { return false }
                    return node.dependencies.allSatisfy { migrated.contains($0) }
                }
                .sorted { lhs, rhs in
                    let lhsRadius = radius[lhs] ?? 0
                    let rhsRadius = radius[rhs] ?? 0
                    if lhsRadius != rhsRadius { return lhsRadius > rhsRadius }
                    let lhsCost = graph.node(lhs)?.openDiagnostics ?? 0
                    let rhsCost = graph.node(rhs)?.openDiagnostics ?? 0
                    if lhsCost != rhsCost { return lhsCost < rhsCost }
                    return lhs < rhs
                }

            guard !ready.isEmpty else {
                // Unreachable for any graph `ModuleGraph.init` accepted: that initialiser
                // rejects cycles, and an acyclic graph always has at least one pending
                // module whose dependencies are all migrated. Kept as a terminating branch
                // so a future planner change fails a test rather than spinning forever.
                unreachable = remaining.sorted()
                break
            }

            var admitted: [PlannedModule] = []
            var spent = 0
            for id in ready {
                guard let node = graph.node(id) else { continue }
                let next = SaturatingMath.add(spent, node.openDiagnostics)
                // Starvation guard: the highest-ranked ready module is admitted even when
                // it alone exceeds the budget. Without this, a single module carrying more
                // diagnostics than `diagnosticsPerWave` would be skipped in every wave
                // forever and the loop would never terminate.
                if !admitted.isEmpty && next > policy.diagnosticsPerWave { continue }
                admitted.append(
                    PlannedModule(
                        id: id,
                        openDiagnostics: node.openDiagnostics,
                        blastRadius: radius[id] ?? 0,
                        owningTeam: node.owningTeam
                    )
                )
                spent = next
            }

            // `ready` is non-empty and the guard above admits its first element
            // unconditionally, so `admitted` is non-empty and the loop makes progress.
            waves.append(MigrationWave(index: waves.count, modules: admitted))
            for planned in admitted {
                migrated.insert(planned.id)
                remaining.remove(planned.id)
            }
        }

        return MigrationPlan(
            waves: waves, alreadyMigrated: alreadyMigrated, unreachable: unreachable
        )
    }
}

/// A planner that is wrong on purpose.
///
/// It buckets pending modules alphabetically into fixed-size waves and ignores the
/// dependency graph entirely. It ships in the library rather than in the test target for
/// one reason: `MigrationPlan.violations(against:)` is the claim this package makes, and a
/// claim is only worth as much as the counter-example that would break it. The suite feeds
/// this planner's output to the validator and requires that the validator *rejects* it.
/// A validator that passed everything would look identical in a coverage report.
public struct NaiveWavePlanner: WavePlanning {
    public let waveSize: Int

    /// - Parameter waveSize: clamped to at least `1`.
    public init(waveSize: Int = 1) {
        self.waveSize = max(1, waveSize)
    }

    public func plan(for graph: ModuleGraph) -> MigrationPlan {
        let pending = graph.pendingModules
        var waves: [MigrationWave] = []
        var index = 0
        while index < pending.count {
            let upper = min(index + waveSize, pending.count)
            let slice = pending[index..<upper]
            let modules = slice.compactMap { id -> PlannedModule? in
                guard let node = graph.node(id) else { return nil }
                return PlannedModule(
                    id: id,
                    openDiagnostics: node.openDiagnostics,
                    blastRadius: graph.blastRadius(of: id),
                    owningTeam: node.owningTeam
                )
            }
            waves.append(MigrationWave(index: waves.count, modules: modules))
            index = upper
        }
        return MigrationPlan(
            waves: waves, alreadyMigrated: graph.migratedModules, unreachable: []
        )
    }
}
