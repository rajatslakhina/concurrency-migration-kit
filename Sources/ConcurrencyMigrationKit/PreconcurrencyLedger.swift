import Foundation

/// One recorded `@preconcurrency import`, with the two things a suppression needs to not
/// become permanent: a named owner, and a date somebody agreed to look at it again.
public struct ExemptionEntry: Sendable, Hashable {
    /// The module containing the `@preconcurrency import`.
    public let module: ModuleID
    /// The module being imported that way.
    public let importedModule: ModuleID
    public let owner: String
    public let reason: String
    /// The date the exemption was agreed to be revisited.
    public let reviewBy: Date

    public init(
        module: ModuleID,
        importedModule: ModuleID,
        owner: String,
        reason: String,
        reviewBy: Date
    ) {
        self.module = module
        self.importedModule = importedModule
        self.owner = owner
        self.reason = reason
        self.reviewBy = reviewBy
    }
}

/// What an exemption is actually doing today, as opposed to what it was for.
public enum ExemptionStatus: Sendable, Hashable {
    /// The imported module is still below Swift 6 mode. The suppression is doing the job
    /// it was written for.
    case justified
    /// The imported module has reached Swift 6 mode. Nothing needs suppressing any more,
    /// so this `@preconcurrency` is silently discarding real diagnostics about the
    /// importing module's own code.
    case stale
    /// Past its review date, and the imported module has not migrated. Still load-bearing,
    /// but nobody has looked at it since the date they promised to.
    case overdue
    /// The entry names a module that is not in the graph.
    case unknownModule(ModuleID)
    /// The entry names a real module that the importing module does not actually depend on.
    case notADependency
}

/// An entry paired with what the graph says about it.
public struct AuditedExemption: Sendable, Hashable {
    public let entry: ExemptionEntry
    public let status: ExemptionStatus
}

/// The result of checking a ledger against the real graph.
public struct LedgerAudit: Sendable, Hashable {
    /// Every entry, sorted by module then imported module. Stable for diffing in CI.
    public let audited: [AuditedExemption]

    public func entries(with status: ExemptionStatus) -> [AuditedExemption] {
        audited.filter { $0.status == status }
    }

    public var stale: [AuditedExemption] { entries(with: .stale) }
    public var overdue: [AuditedExemption] { entries(with: .overdue) }
    public var justified: [AuditedExemption] { entries(with: .justified) }

    /// Entries that describe something the graph does not support: an unknown module, or
    /// an import of something the module does not depend on.
    public var incoherent: [AuditedExemption] {
        audited.filter {
            switch $0.status {
            case .unknownModule, .notADependency: true
            case .justified, .stale, .overdue: false
            }
        }
    }

    /// Inversions in the graph that no ledger entry accounts for.
    ///
    /// The other half of the check, and the half a ledger cannot catch on its own: a
    /// module that went ahead of its dependency and suppressed the fallout *without*
    /// writing the suppression down. An unrecorded exemption is strictly worse than an
    /// overdue one, because there is no owner to ask.
    public let unrecordedInversions: [PostureInversion]

    /// What a CI gate should fail on.
    ///
    /// Stale entries and unrecorded inversions fail; overdue ones do not. That split is a
    /// judgement call worth defending: a stale entry is *actively hiding compiler
    /// diagnostics right now* and deleting it is a mechanical, safe change. An overdue one
    /// is still doing real work, and failing the build over a calendar date punishes the
    /// team that is blocked rather than the one blocking them. Overdue entries are
    /// reported, loudly, and left to a human.
    public var gateFailures: [String] {
        var failures: [String] = []
        for item in stale {
            failures.append(
                "Stale @preconcurrency: '\(item.entry.module)' still suppresses"
                    + " '\(item.entry.importedModule)', which reached Swift 6."
                    + " Owner: \(item.entry.owner)."
            )
        }
        for item in incoherent {
            failures.append(
                "Incoherent ledger entry: '\(item.entry.module)' -> '\(item.entry.importedModule)'"
                    + " does not match the graph. Owner: \(item.entry.owner)."
            )
        }
        for inversion in unrecordedInversions {
            failures.append(
                "Unrecorded inversion: '\(inversion.module)' (\(inversion.modulePosture.displayName))"
                    + " depends on '\(inversion.dependency)'"
                    + " (\(inversion.dependencyPosture.displayName)) with no ledger entry."
            )
        }
        return failures
    }

    public var passesGate: Bool { gateFailures.isEmpty }
}

/// Checks recorded `@preconcurrency` suppressions against what the module graph actually
/// looks like today.
///
/// The bug this exists to catch: an exemption is written when a dependency is behind, and
/// then the dependency migrates. The exemption keeps compiling. Nothing warns. From that
/// moment it is not suppressing anything about the dependency — it is suppressing
/// diagnostics about the importing module's *own* code, indefinitely, and the only way to
/// know is to compare it against the graph. A suppression that outlives its reason is
/// indistinguishable from one that still has a reason, unless somebody checks.
public enum PreconcurrencyLedger {

    public static func audit(
        _ entries: [ExemptionEntry],
        against graph: ModuleGraph,
        asOf date: Date
    ) -> LedgerAudit {
        let sorted = entries.sorted { lhs, rhs in
            lhs.module == rhs.module
                ? lhs.importedModule < rhs.importedModule
                : lhs.module < rhs.module
        }

        var audited: [AuditedExemption] = []
        audited.reserveCapacity(sorted.count)
        var recorded: Set<Pair> = []

        for entry in sorted {
            let status = classify(entry, against: graph, asOf: date)
            audited.append(AuditedExemption(entry: entry, status: status))
            switch status {
            case .unknownModule, .notADependency:
                break
            case .justified, .stale, .overdue:
                recorded.insert(Pair(module: entry.module, dependency: entry.importedModule))
            }
        }

        let unrecorded = IsolationAuditor.inversions(in: graph).filter {
            !recorded.contains(Pair(module: $0.module, dependency: $0.dependency))
        }

        return LedgerAudit(audited: audited, unrecordedInversions: unrecorded)
    }

    /// Precedence is deliberate, strongest signal first:
    ///
    /// 1. Coherence — an entry that does not match the graph tells you nothing about
    ///    concurrency, only that the ledger has drifted from the build files.
    /// 2. Staleness — the dependency migrated, so the suppression is now hiding
    ///    diagnostics. This outranks the review date on purpose: a stale entry is a
    ///    correctness problem today, while an overdue one is a process problem. An entry
    ///    that is both is reported as stale, because that is the finding that changes what
    ///    you do about it.
    /// 3. Review date.
    private static func classify(
        _ entry: ExemptionEntry,
        against graph: ModuleGraph,
        asOf date: Date
    ) -> ExemptionStatus {
        guard let module = graph.node(entry.module) else {
            return .unknownModule(entry.module)
        }
        guard let imported = graph.node(entry.importedModule) else {
            return .unknownModule(entry.importedModule)
        }
        guard module.dependencies.contains(entry.importedModule) else {
            return .notADependency
        }
        if imported.posture.isMigrated { return .stale }
        if date > entry.reviewBy { return .overdue }
        return .justified
    }

    private struct Pair: Hashable {
        let module: ModuleID
        let dependency: ModuleID
    }
}
