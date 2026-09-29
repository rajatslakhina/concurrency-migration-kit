#if canImport(SwiftUI)
import Foundation
import SwiftUI
import ConcurrencyMigrationKit

/// The planner and the ledger, rendered.
///
/// Everything shown here is derived from the `ModuleGraph` and `[ExemptionEntry]` handed
/// in — the view owns no fixture data of its own, which is what lets the demo app supply a
/// realistic package graph and lets a host app supply its own. Changing the wave budget
/// re-plans against the same graph, which is the point the whole screen is trying to make:
/// the dependency graph fixes the *order*, team capacity fixes the *batch size*, and those
/// are two different decisions owned by two different people.
public struct MigrationDashboardView: View {

    public enum Budget: String, CaseIterable, Identifiable, Sendable {
        case unbounded = "All at once"
        case balanced = "Balanced"
        case conservative = "Careful"

        public var id: String { rawValue }

        var policy: MigrationPolicy {
            switch self {
            case .unbounded: .unbounded
            case .balanced: MigrationPolicy(diagnosticsPerWave: 40)
            case .conservative: MigrationPolicy(diagnosticsPerWave: 12)
            }
        }

        var caption: String {
            switch self {
            case .unbounded: "No cap. Every unblocked module in the same wave."
            case .balanced: "Up to 40 open diagnostics per wave."
            case .conservative: "Up to 12 open diagnostics per wave."
            }
        }
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case plan = "Migration plan"
        case debt = "Suppression debt"
        var id: String { rawValue }
    }

    private let graph: ModuleGraph
    private let exemptions: [ExemptionEntry]
    private let referenceDate: Date

    @State private var budget: Budget
    @State private var tab: Tab = .plan

    public init(
        graph: ModuleGraph,
        exemptions: [ExemptionEntry],
        referenceDate: Date,
        initialBudget: Budget = .balanced
    ) {
        self.graph = graph
        self.exemptions = exemptions
        self.referenceDate = referenceDate
        self._budget = State(initialValue: initialBudget)
    }

    private var plan: MigrationPlan {
        MigrationPlanner(policy: budget.policy).plan(for: graph)
    }

    private var audit: LedgerAudit {
        PreconcurrencyLedger.audit(exemptions, against: graph, asOf: referenceDate)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if graph.isEmpty {
                    ContentUnavailableView(
                        "No modules",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Load a package graph to plan a migration.")
                    )
                } else {
                    content
                }
            }
            .navigationTitle("Swift 6 Migration")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var content: some View {
        List {
            Section { summary } header: { Text("Where the graph stands") }

            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .listRowBackground(Color.clear)

            switch tab {
            case .plan: planSections
            case .debt: debtSections
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Summary

    private var summary: some View {
        let migrated = graph.migratedModules.count
        let pending = graph.pendingModules.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(graph.migratedPercentage)%")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("in Swift 6 language mode")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(migrated),
                total: Double(max(graph.count, 1))
            )
            .tint(.green)
            HStack(spacing: 16) {
                Label("\(migrated) done", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Label("\(pending) to go", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Plan

    @ViewBuilder
    private var planSections: some View {
        let currentPlan = plan

        Section {
            Picker("Wave budget", selection: $budget) {
                ForEach(Budget.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 4) {
                Text(budget.caption)
                Text(
                    "\(currentPlan.waves.count) "
                        + (currentPlan.waves.count == 1 ? "wave" : "waves")
                        + " to finish."
                )
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            Text("How much at once")
        } footer: {
            Text(
                "Order comes from the dependency graph and does not change. "
                    + "Batch size comes from team capacity and does."
            )
        }

        if currentPlan.waves.isEmpty {
            Section {
                Label("Every module is already in Swift 6 mode.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }

        ForEach(currentPlan.waves, id: \.index) { wave in
            Section {
                ForEach(wave.modules, id: \.id) { module in
                    plannedRow(module)
                }
            } header: {
                HStack {
                    Text("Wave \(wave.index + 1)")
                    Spacer()
                    Text("\(wave.totalDiagnostics) diagnostics")
                        .monospacedDigit()
                }
            } footer: {
                Text(
                    wave.teams.isEmpty
                        ? "No owning team recorded."
                        : "Parallel across: " + wave.teams.joined(separator: ", ")
                )
            }
        }
    }

    private func plannedRow(_ module: PlannedModule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(module.id.rawValue)
                    .font(.body.weight(.medium))
                Spacer()
                Text("\(module.openDiagnostics)")
                    .monospacedDigit()
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            HStack(spacing: 10) {
                Label("unblocks \(module.blastRadius)", systemImage: "arrow.triangle.branch")
                Text(module.owningTeam)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Debt

    @ViewBuilder
    private var debtSections: some View {
        let currentAudit = audit
        let failures = currentAudit.gateFailures

        Section {
            Label(
                failures.isEmpty
                    ? "No suppression is hiding anything today."
                    : "\(failures.count) "
                        + (failures.count == 1 ? "finding" : "findings")
                        + " would fail the gate.",
                systemImage: failures.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
            )
            .foregroundStyle(failures.isEmpty ? .green : .red)
            .font(.subheadline.weight(.medium))
        } header: {
            Text("CI gate")
        } footer: {
            Text(
                "Stale suppressions and unrecorded inversions fail. "
                    + "Overdue ones are reported and left to a human — they are still load-bearing."
            )
        }

        if currentAudit.audited.isEmpty && currentAudit.unrecordedInversions.isEmpty {
            Section {
                Text("No @preconcurrency imports recorded for this graph.")
                    .foregroundStyle(.secondary)
            }
        }

        if !currentAudit.audited.isEmpty {
            Section("Ledger (\(currentAudit.audited.count))") {
                ForEach(currentAudit.audited, id: \.entry) { item in
                    exemptionRow(item)
                }
            }
        }

        if !currentAudit.unrecordedInversions.isEmpty {
            Section {
                ForEach(currentAudit.unrecordedInversions, id: \.self) { inversion in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(inversion.module.rawValue) → \(inversion.dependency.rawValue)")
                            .font(.body.weight(.medium))
                        Text(
                            "\(inversion.modulePosture.displayName) depending on "
                                + inversion.dependencyPosture.displayName
                                + " — with nothing written down."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Unrecorded inversions (\(currentAudit.unrecordedInversions.count))")
            } footer: {
                Text("A suppression with no ledger entry has no owner to ask.")
            }
        }
    }

    private func exemptionRow(_ item: AuditedExemption) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(item.entry.module.rawValue) → \(item.entry.importedModule.rawValue)")
                    .font(.body.weight(.medium))
                Spacer()
                statusBadge(item.status)
            }
            Text(item.entry.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label(item.entry.owner, systemImage: "person.fill")
                Label(
                    item.entry.reviewBy.formatted(date: .abbreviated, time: .omitted),
                    systemImage: "calendar"
                )
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    private func statusBadge(_ status: ExemptionStatus) -> some View {
        let (text, colour): (String, Color) = switch status {
        case .justified: ("justified", .green)
        case .stale: ("stale", .red)
        case .overdue: ("overdue", .orange)
        case .notADependency: ("not a dependency", .purple)
        case .unknownModule: ("unknown module", .purple)
        }
        return Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(colour.opacity(0.18), in: Capsule())
            .foregroundStyle(colour)
    }
}
#endif
