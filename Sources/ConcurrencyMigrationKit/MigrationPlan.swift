/// A module scheduled into a wave, carrying the numbers that justified its position.
public struct PlannedModule: Sendable, Hashable {
    public let id: ModuleID
    public let openDiagnostics: Int
    public let blastRadius: Int
    public let owningTeam: String

    // Explicitly public: the compiler's memberwise initialiser is internal, which would
    // make the public `MigrationPlan.init` below unusable from outside the module.
    public init(id: ModuleID, openDiagnostics: Int, blastRadius: Int, owningTeam: String) {
        self.id = id
        self.openDiagnostics = openDiagnostics
        self.blastRadius = blastRadius
        self.owningTeam = owningTeam
    }
}

/// A set of modules that can be migrated in parallel.
///
/// Every module in a wave has all of its dependencies satisfied by an *earlier* wave, so
/// the teams that own them can work simultaneously without waiting on each other.
public struct MigrationWave: Sendable, Hashable {
    public let index: Int
    /// Ordered by the planner's rank, best-first.
    public let modules: [PlannedModule]

    public init(index: Int, modules: [PlannedModule]) {
        self.index = index
        self.modules = modules
    }

    /// Total outstanding diagnostics in this wave — what the effort budget is spent on.
    public var totalDiagnostics: Int {
        SaturatingMath.sum(modules.map(\.openDiagnostics))
    }

    /// Distinct owning teams, sorted. A wave spanning many teams parallelises well;
    /// a wave that is one team five times over is a queue wearing a wave's clothes.
    public var teams: [String] {
        Array(Set(modules.map(\.owningTeam))).sorted()
    }
}

/// An ordered migration schedule for a graph.
public struct MigrationPlan: Sendable, Hashable {
    public let waves: [MigrationWave]
    /// Modules already in Swift 6 mode when the plan was made, sorted.
    public let alreadyMigrated: [ModuleID]
    /// Modules the planner could not schedule. For a graph accepted by `ModuleGraph.init`
    /// this is always empty; it exists so a planner that gets stuck says so instead of
    /// silently dropping work. `MigrationPlannerTests` asserts it stays empty.
    public let unreachable: [ModuleID]

    public init(waves: [MigrationWave], alreadyMigrated: [ModuleID], unreachable: [ModuleID]) {
        self.waves = waves
        self.alreadyMigrated = alreadyMigrated
        self.unreachable = unreachable
    }

    /// Every module scheduled, in wave order then rank order.
    public var scheduledModules: [ModuleID] { waves.flatMap { $0.modules.map(\.id) } }

    /// The wave a module was scheduled into, or `nil` if it was not scheduled.
    public func wave(containing id: ModuleID) -> Int? {
        for wave in waves where wave.modules.contains(where: { $0.id == id }) {
            return wave.index
        }
        return nil
    }
}

/// A way a plan can be wrong.
public enum PlanViolation: Sendable, Hashable, CustomStringConvertible {
    /// A dependency is scheduled no earlier than something that depends on it. Same-wave
    /// counts: a wave is worked in parallel, so a dependency landing in the same wave
    /// gives the dependent no guarantee it can build against.
    case dependencyNotScheduledEarlier(
        dependency: ModuleID, dependent: ModuleID, dependencyWave: Int, dependentWave: Int
    )
    /// A dependency is neither already migrated nor anywhere in the plan.
    case dependencyNeverScheduled(dependency: ModuleID, dependent: ModuleID)
    case moduleScheduledTwice(ModuleID)
    case alreadyMigratedModuleScheduled(ModuleID)
    case unknownModuleScheduled(ModuleID)
    /// A pending module the plan forgot.
    case pendingModuleMissingFromPlan(ModuleID)
    /// Wave indices are not `0, 1, 2, …`.
    case waveIndicesNotContiguous([Int])

    public var description: String {
        switch self {
        case .dependencyNotScheduledEarlier(let dependency, let dependent, let dw, let tw):
            "'\(dependency)' is in wave \(dw) but its dependent '\(dependent)' is in wave \(tw);"
                + " a dependency must land in a strictly earlier wave."
        case .dependencyNeverScheduled(let dependency, let dependent):
            "'\(dependent)' depends on '\(dependency)', which is not migrated and never scheduled."
        case .moduleScheduledTwice(let id): "'\(id)' appears in more than one wave."
        case .alreadyMigratedModuleScheduled(let id): "'\(id)' is already in Swift 6 mode but was scheduled."
        case .unknownModuleScheduled(let id): "'\(id)' is not in the graph but was scheduled."
        case .pendingModuleMissingFromPlan(let id): "'\(id)' still needs migrating but is not in the plan."
        case .waveIndicesNotContiguous(let indices):
            "Wave indices are \(indices); expected 0..<\(indices.count)."
        }
    }
}

extension MigrationPlan {

    /// Checks this plan against the graph it claims to schedule.
    ///
    /// This is the package's real contract, and it is deliberately implemented
    /// independently of `MigrationPlanner` — it re-derives what it needs from the graph
    /// rather than trusting anything the planner recorded. That independence is what lets
    /// the test suite run a knowingly-broken planner through it and require failures.
    public func violations(against graph: ModuleGraph) -> [PlanViolation] {
        var violations: [PlanViolation] = []

        let indices = waves.map(\.index)
        if indices != Array(0..<waves.count) {
            violations.append(.waveIndicesNotContiguous(indices))
        }

        var waveByModule: [ModuleID: Int] = [:]
        var seenTwice: Set<ModuleID> = []
        for wave in waves {
            for planned in wave.modules {
                if waveByModule[planned.id] != nil {
                    if seenTwice.insert(planned.id).inserted {
                        violations.append(.moduleScheduledTwice(planned.id))
                    }
                    continue
                }
                waveByModule[planned.id] = wave.index
                guard let node = graph.node(planned.id) else {
                    violations.append(.unknownModuleScheduled(planned.id))
                    continue
                }
                if node.posture.isMigrated {
                    violations.append(.alreadyMigratedModuleScheduled(planned.id))
                }
            }
        }

        for id in graph.pendingModules where waveByModule[id] == nil {
            violations.append(.pendingModuleMissingFromPlan(id))
        }

        for (id, dependentWave) in waveByModule.sorted(by: { $0.key < $1.key }) {
            guard let node = graph.node(id) else { continue }
            for dependency in node.dependencies.sorted() {
                if graph.node(dependency)?.posture.isMigrated == true { continue }
                guard let dependencyWave = waveByModule[dependency] else {
                    violations.append(
                        .dependencyNeverScheduled(dependency: dependency, dependent: id)
                    )
                    continue
                }
                if dependencyWave >= dependentWave {
                    violations.append(
                        .dependencyNotScheduledEarlier(
                            dependency: dependency,
                            dependent: id,
                            dependencyWave: dependencyWave,
                            dependentWave: dependentWave
                        )
                    )
                }
            }
        }
        return violations
    }

    /// `true` when the plan schedules every pending module in a dependency-respecting order.
    public func isValid(against graph: ModuleGraph) -> Bool {
        violations(against: graph).isEmpty
    }
}
