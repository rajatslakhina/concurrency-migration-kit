import Foundation
@testable import ConcurrencyMigrationKit

/// SplitMix64. A seeded generator so every "random graph" test is reproducible from its
/// seed — a property test that cannot be replayed is a flake generator, not a test.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fixture {

    /// A graph whose alphabetical order deliberately contradicts its topological order:
    /// `Alpha` depends on `Zulu`. Any planner that sorts by name and ignores edges will
    /// schedule `Alpha` first and be caught by the validator.
    static func alphabeticalTrap() throws -> ModuleGraph {
        try ModuleGraph([
            ModuleNode(id: "Alpha", posture: .swift5Complete, dependencies: ["Zulu"], openDiagnostics: 4),
            ModuleNode(id: "Zulu", posture: .swift5Targeted, dependencies: [], openDiagnostics: 9),
        ])
    }

    /// A layered graph shaped like a real app: a couple of leaf utilities, some shared
    /// services on top of them, feature modules above that, and an app shell at the top.
    static func layeredApp() throws -> ModuleGraph {
        try ModuleGraph([
            ModuleNode(id: "CoreTypes", posture: .swift6, dependencies: [], openDiagnostics: 0, owningTeam: "Platform"),
            ModuleNode(id: "Logging", posture: .swift5Complete, dependencies: [], openDiagnostics: 6, owningTeam: "Platform"),
            ModuleNode(id: "Networking", posture: .swift5Targeted, dependencies: ["CoreTypes", "Logging"], openDiagnostics: 22, owningTeam: "Platform"),
            ModuleNode(id: "Persistence", posture: .swift5Targeted, dependencies: ["CoreTypes"], openDiagnostics: 14, owningTeam: "Data"),
            ModuleNode(id: "Sync", posture: .swift5Unchecked, dependencies: ["Networking", "Persistence"], openDiagnostics: 31, owningTeam: "Data"),
            ModuleNode(id: "Checkout", posture: .swift5Unchecked, dependencies: ["Networking"], openDiagnostics: 18, owningTeam: "Payments"),
            ModuleNode(id: "Profile", posture: .swift5Unchecked, dependencies: ["Persistence", "Logging"], openDiagnostics: 7, owningTeam: "Growth"),
            ModuleNode(id: "AppShell", posture: .swift5Unchecked, dependencies: ["Sync", "Checkout", "Profile"], openDiagnostics: 11, owningTeam: "Platform"),
        ])
    }

    /// `Reports` has been flipped to Swift 6 ahead of `Logging`, which has not — the shape
    /// every `@preconcurrency import` has.
    static func withInversion() throws -> ModuleGraph {
        try ModuleGraph([
            ModuleNode(id: "Logging", posture: .swift5Targeted, dependencies: [], openDiagnostics: 5),
            ModuleNode(id: "Analytics", posture: .swift6, dependencies: [], openDiagnostics: 0),
            ModuleNode(id: "Reports", posture: .swift6, dependencies: ["Logging", "Analytics"], openDiagnostics: 0),
        ])
    }

    static func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // A hard-coded, well-formed literal from this file only. If it ever fails to parse
        // the tests must not silently run against a bogus date, so fall back to a value
        // that makes every comparison obviously wrong rather than plausibly right.
        return formatter.date(from: iso) ?? Date.distantPast
    }

    /// Builds a random DAG. Edges only ever point from a higher index to a lower one,
    /// which makes acyclicity structural rather than something the generator has to check.
    static func randomDAG(
        moduleCount: Int,
        migratedChance: Int,
        using generator: inout SeededGenerator
    ) throws -> ModuleGraph {
        var nodes: [ModuleNode] = []
        for index in 0..<moduleCount {
            var dependencies: Set<ModuleID> = []
            for candidate in 0..<index where Int.random(in: 0..<100, using: &generator) < 35 {
                dependencies.insert(ModuleID("M\(candidate)"))
            }
            let migrated = Int.random(in: 0..<100, using: &generator) < migratedChance
            nodes.append(
                ModuleNode(
                    id: ModuleID("M\(index)"),
                    posture: migrated ? .swift6 : .swift5Targeted,
                    dependencies: dependencies,
                    openDiagnostics: Int.random(in: 0...25, using: &generator),
                    owningTeam: "T\(index % 4)"
                )
            )
        }
        return try ModuleGraph(nodes)
    }
}
