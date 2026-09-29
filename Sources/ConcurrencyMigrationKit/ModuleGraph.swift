/// A module's name, as the build system spells it.
public struct ModuleID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static func < (lhs: ModuleID, rhs: ModuleID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

extension ModuleID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}

/// One module in the package graph, with the two facts the planner needs about it:
/// how far along it already is, and how much work is left.
public struct ModuleNode: Sendable, Hashable {
    public let id: ModuleID
    public let posture: ConcurrencyPosture
    /// Direct dependencies. Transitive edges are derived, never stored.
    public let dependencies: Set<ModuleID>
    /// Strict-concurrency diagnostics this module still emits under
    /// `-strict-concurrency=complete`. The planner's effort budget is denominated in these.
    public let openDiagnostics: Int
    /// The team that has to do the work. Carried through to the plan so a wave is
    /// actionable rather than just correct.
    public let owningTeam: String

    public init(
        id: ModuleID,
        posture: ConcurrencyPosture,
        dependencies: Set<ModuleID> = [],
        openDiagnostics: Int = 0,
        owningTeam: String = "unassigned"
    ) {
        self.id = id
        self.posture = posture
        self.dependencies = dependencies
        // A negative diagnostic count is meaningless and would corrupt every budget sum
        // downstream. Normalise at the boundary so no later arithmetic has to defend.
        self.openDiagnostics = max(0, openDiagnostics)
        self.owningTeam = owningTeam
    }
}

/// Why a proposed graph is not a graph.
///
/// Typed `throws(GraphError)` on the initialiser turns "what can constructing this fail
/// with" from a runtime surprise into part of the signature — the Swift 6 feature this
/// package leans on hardest at its own boundary.
public enum GraphError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The same module id was supplied more than once.
    case duplicateModule(ModuleID)
    /// A module depends on something that is not in the graph.
    case unknownDependency(module: ModuleID, dependency: ModuleID)
    /// A dependency cycle, as the actual path that closes it.
    /// The first element is repeated implicitly at the end: `[A, B, C]` means A → B → C → A.
    case dependencyCycle([ModuleID])

    public var description: String {
        switch self {
        case .duplicateModule(let id):
            "Duplicate module '\(id)'."
        case .unknownDependency(let module, let dependency):
            "Module '\(module)' depends on '\(dependency)', which is not in the graph."
        case .dependencyCycle(let path):
            "Dependency cycle: \(path.map(\.rawValue).joined(separator: " -> "))"
                + " -> \(path.first?.rawValue ?? "?")"
        }
    }
}

/// A validated, acyclic module dependency graph.
///
/// Validation happens once, in `init`, so every query below can be total — no method on a
/// constructed `ModuleGraph` returns an optional or throws because of malformed input.
/// That is the whole point of making the initialiser the only fallible entry point.
public struct ModuleGraph: Sendable {
    public let nodes: [ModuleID: ModuleNode]
    /// Module ids in a stable, sorted order. Everything that iterates the graph iterates
    /// this, so results never depend on `Dictionary` ordering.
    public let identifiers: [ModuleID]
    private let dependents: [ModuleID: Set<ModuleID>]

    /// Builds and validates a graph.
    ///
    /// - Throws: `GraphError.duplicateModule` on a repeated id,
    ///   `GraphError.unknownDependency` on a dangling edge, and
    ///   `GraphError.dependencyCycle` with the offending path if the edges are not acyclic.
    public init(_ modules: [ModuleNode]) throws(GraphError) {
        var byID: [ModuleID: ModuleNode] = [:]
        byID.reserveCapacity(modules.count)
        for module in modules {
            guard byID[module.id] == nil else { throw .duplicateModule(module.id) }
            byID[module.id] = module
        }

        // Dangling edges are checked before cycle detection so the error a caller gets
        // names the real problem rather than a cycle through a phantom node.
        let sortedIDs = byID.keys.sorted()
        for id in sortedIDs {
            // Safe by construction: `sortedIDs` is exactly `byID.keys`.
            guard let module = byID[id] else { continue }
            for dependency in module.dependencies.sorted() where byID[dependency] == nil {
                throw .unknownDependency(module: id, dependency: dependency)
            }
        }

        if let cycle = Self.findCycle(in: byID, order: sortedIDs) {
            throw .dependencyCycle(cycle)
        }

        var reverse: [ModuleID: Set<ModuleID>] = [:]
        for id in sortedIDs {
            guard let module = byID[id] else { continue }
            for dependency in module.dependencies {
                reverse[dependency, default: []].insert(id)
            }
        }

        self.nodes = byID
        self.identifiers = sortedIDs
        self.dependents = reverse
    }

    /// Iterative depth-first search with three-colour marking.
    ///
    /// Iterative rather than recursive on purpose: a real package graph can be hundreds of
    /// modules deep in a pathological chain, and a recursive DFS that blows the stack is a
    /// crash in the exact tool whose job is to tell you your graph is unhealthy.
    private static func findCycle(
        in nodes: [ModuleID: ModuleNode],
        order: [ModuleID]
    ) -> [ModuleID]? {
        enum Colour { case grey, black }
        var colour: [ModuleID: Colour] = [:]
        // The current DFS path, used to reconstruct the cycle when a grey node is re-entered.
        var path: [ModuleID] = []
        var onPath: Set<ModuleID> = []

        // Each frame carries its own child cursor, which is what replaces the call stack.
        struct Frame { let id: ModuleID; var children: [ModuleID]; var next: Int }

        for root in order where colour[root] == nil {
            var stack: [Frame] = [
                Frame(id: root, children: nodes[root]?.dependencies.sorted() ?? [], next: 0)
            ]
            colour[root] = .grey
            path.append(root)
            onPath.insert(root)

            while var frame = stack.popLast() {
                guard frame.next < frame.children.count else {
                    colour[frame.id] = .black
                    if let last = path.last, last == frame.id {
                        path.removeLast()
                        onPath.remove(last)
                    }
                    continue
                }
                let child = frame.children[frame.next]
                frame.next += 1
                stack.append(frame)

                if onPath.contains(child) {
                    // `child` is on the current path, so it is somewhere in `path`.
                    guard let start = path.firstIndex(of: child) else { return [child] }
                    return Array(path[start...])
                }
                if colour[child] == .black { continue }

                colour[child] = .grey
                path.append(child)
                onPath.insert(child)
                stack.append(
                    Frame(id: child, children: nodes[child]?.dependencies.sorted() ?? [], next: 0)
                )
            }
        }
        return nil
    }

    public var count: Int { nodes.count }
    public var isEmpty: Bool { nodes.isEmpty }

    public func node(_ id: ModuleID) -> ModuleNode? { nodes[id] }

    /// Modules that depend on `id` directly.
    public func directDependents(of id: ModuleID) -> Set<ModuleID> { dependents[id] ?? [] }

    /// Every module that reaches `id` through one or more edges.
    ///
    /// Breadth-first over the reverse graph with a `visited` set, so a diamond is walked
    /// once and the traversal terminates on any input the initialiser accepted.
    public func transitiveDependents(of id: ModuleID) -> Set<ModuleID> {
        var visited: Set<ModuleID> = []
        var queue: [ModuleID] = (dependents[id] ?? []).sorted()
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            guard visited.insert(current).inserted else { continue }
            for next in (dependents[current] ?? []).sorted() where !visited.contains(next) {
                queue.append(next)
            }
        }
        return visited
    }

    /// Every module `id` reaches through one or more edges.
    public func transitiveDependencies(of id: ModuleID) -> Set<ModuleID> {
        var visited: Set<ModuleID> = []
        var queue: [ModuleID] = (nodes[id]?.dependencies ?? []).sorted()
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            guard visited.insert(current).inserted else { continue }
            for next in (nodes[current]?.dependencies ?? []).sorted() where !visited.contains(next) {
                queue.append(next)
            }
        }
        return visited
    }
}
