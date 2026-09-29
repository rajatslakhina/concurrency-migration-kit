# ConcurrencyMigrationKit

**A `@preconcurrency import` that outlives its reason is indistinguishable from one that still has a reason — unless something compares it against the dependency graph.**

Nothing in the Swift toolchain will ever tell you that a suppression has stopped suppressing what it was written for. It keeps compiling. The build stays green. And from the moment the dependency it was added for reaches Swift 6 language mode, that `@preconcurrency` is no longer protecting you from someone else's un-audited types — it is quietly discarding data-race diagnostics about **your own module's code**, for as long as the line stays in the file.

This package plans a strict-concurrency migration across a Swift package graph, and then keeps the suppressions that migration creates from becoming permanent.

---

## Why this matters

Moving a large app to the Swift 6 language mode is not a refactor, it is a **migration programme with a dependency order**, and the two hard parts are not writing `Sendable` conformances.

The first is **sequencing**. A module can only migrate cleanly once everything it depends on has migrated — otherwise its imports bring in un-audited types and the only way forward is `@preconcurrency import`. So the order is not a matter of taste; the dependency graph fixes it. What is *not* fixed is how much you attempt at once, and that is the decision a lead actually owns.

The second is **the debt the first part creates**. Every time somebody flips a module ahead of its dependencies — and on a real programme somebody always does, because a team is blocked and the quarter is ending — a suppression goes into a file. It has a reason on the day it is written. Six weeks later the dependency migrates, and nothing anywhere connects those two facts.

That is the same failure shape as a security exemption keyed on something the reviewed party controls: it does not fail loudly, it degrades silently into a permanent exemption. The difference is that here the exemption is invisible by construction, because the only evidence is a relationship between a source file and a build setting in a *different module*.

## What's in it

| Type | What it does |
| --- | --- |
| `ModuleGraph` | A validated, acyclic dependency graph. The initialiser is the only fallible entry point — it uses Swift 6's **typed `throws(GraphError)`**, so "what can this fail with" is part of the signature. Cycle detection is an **iterative** three-colour DFS that returns the actual cycle path. |
| `MigrationPlanner` | Turns the graph into ordered **waves** of modules that can be migrated in parallel, ranked by blast radius, then cost, then id. |
| `MigrationPolicy` | The one lever a lead has: outstanding diagnostics per wave. Order comes from the graph; batch size comes from team capacity. |
| `MigrationPlan.violations(against:)` | An **independent** checker that re-derives everything from the graph rather than trusting the planner. This is the package's actual contract. |
| `PreconcurrencyLedger` | Classifies every recorded suppression against the live graph: `justified`, `stale`, `overdue`, or incoherent — plus the inversions nobody wrote down at all. |
| `IsolationAuditor` | Finds every module sitting at a higher posture than something it depends on. |
| `SaturatingMath` | Non-trapping integer arithmetic, because every number here comes from a build log or a config file. |
| `NaiveWavePlanner` | A planner that is **wrong on purpose**, shipped in the library. See below. |

## Design decisions, and what was rejected

**A dependency must land in a *strictly earlier* wave, not the same one.** A wave is worked in parallel by different teams, so a dependency arriving beside its dependent gives that dependent nothing to build against. Accepting same-wave would have made plans shorter and the tool useless. `testDependencyInTheSameWaveAsItsDependentIsAViolation` pins it.

**"Ready" means every dependency is already in Swift 6 mode — not merely at `-strict-concurrency=complete`.** Complete checking still emits *warnings*, which the module emitting them is free to ignore, so a `swift5Complete` dependency offers its dependents no enforced `Sendable` guarantee. Using the weaker bar would have produced a plan that looks faster and generates suppression debt at every step.

**Blast radius is computed once, against the input graph, and held fixed.** Recomputing it per wave is more precise — a module's radius shrinks as its dependents migrate — but it costs a traversal per wave and makes the ranking depend on decisions the plan has not taken yet. Fixed radii keep every position in the schedule explainable from the graph alone, which matters more in a review than a marginally better ordering.

**Stale outranks overdue.** An entry can be both. It is reported as stale, because that is the finding that changes what you do: a stale entry is hiding compiler diagnostics *today* and deleting it is mechanical and safe.

**Stale entries fail the CI gate; overdue ones do not.** A stale suppression is a correctness problem with a safe fix. An overdue one is still load-bearing, and failing the build over a calendar date punishes the team that is blocked rather than the team blocking them. Overdue entries are reported loudly and left to a human. This is a judgement call, and it is the one most worth arguing with.

**The ranking has a third tie-break on module id.** Without a total order the plan would depend on `Set` iteration order, and no two CI runs would agree on the schedule.

**The planner admits the top-ranked ready module even when it alone blows the budget.** Without that starvation guard, a module carrying more diagnostics than `diagnosticsPerWave` is skipped in every wave forever and the loop never terminates.

## The test that tries to break the claim

A validator that returned `[]` unconditionally would pass every test written against the real planner, because the real planner never produces a bad plan. Coverage would look identical.

So `NaiveWavePlanner` — which buckets modules alphabetically and ignores every edge — ships **in the library**, and `PlanValidatorFalsificationTests` requires the validator to *reject* it: on a graph where `Alpha` depends on `Zulu`, and on 100+ generated DAGs, while requiring the real planner to survive the identical graphs so a reject-everything validator fails too. Each violation case also has its own hand-built counter-example.

The same discipline found a real bug in this repo. `SaturatingMath.percentage` originally used the saturating multiply, which clamps `100 * Int.max` to `Int.max` and then divides it by `Int.max` — so a **fully-migrated graph reported 1%**. Clamping an intermediate is silent data corruption whenever the value is a ratio rather than the answer. The fix uses `multipliedFullWidth`/`dividingFullWidth`; `testPercentageIsExactAtTheScaleWhereASaturatedMultiplyWouldLie` is the regression test.

## Safety properties

No force-unwraps. Every collection access is bounds-checked or expressed as a `Sequence` operation. Every arithmetic operation that can trap — `+`, `-`, `*`, `/`, `%`, `Int(Double)` — goes through `SaturatingMath`, including the `Double(Int.max)` boundary that rounds *up* to 2^63 and defeats the obvious-looking `value <= Double(Int.max)` guard. Nothing widens to `Int64`, so the semantics hold where `Int` is 32 bits. The graph traversals are iterative, so a 5,000-module chain is a test case rather than a stack overflow.

## Using it

```swift
.package(url: "https://github.com/rajatslakhina/concurrency-migration-kit.git", from: "1.0.0")
```

```swift
import ConcurrencyMigrationKit

let graph = try ModuleGraph([
    ModuleNode(id: "CoreTypes", posture: .swift6, owningTeam: "Platform"),
    ModuleNode(id: "Logging", posture: .swift5Complete, openDiagnostics: 6, owningTeam: "Platform"),
    ModuleNode(id: "Networking", posture: .swift5Targeted,
               dependencies: ["CoreTypes", "Logging"], openDiagnostics: 22, owningTeam: "Platform"),
])

let plan = MigrationPlanner(policy: MigrationPolicy(diagnosticsPerWave: 40)).plan(for: graph)
precondition(plan.isValid(against: graph))

let audit = PreconcurrencyLedger.audit(ledger, against: graph, asOf: .now)
guard audit.passesGate else {
    audit.gateFailures.forEach { print("error: \($0)") }
    exit(1)
}
```

`ConcurrencyMigrationKitUI` adds `MigrationDashboardView`, which renders a plan and a ledger audit and re-plans live when you change the wave budget.

## Running the tests

```bash
swift build -Xswiftc -warnings-as-errors
swift test
```

## Verification

<!-- VERIFICATION -->

## Demo app

Demo app: (added after the companion repo is pushed — see below)

## Licence

MIT. See [LICENSE](LICENSE).
