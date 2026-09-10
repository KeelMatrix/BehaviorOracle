# BehaviorOracle synthetic benchmark report

This report records reproducible synthetic feasibility evidence for the bounded .NET semantic domain. It is an engineering benchmark, not a release-readiness claim.

## Committed recipe and environment

- Date of captured run: 2026-09-10
- Host: Windows 10.0.19045, win-x64
- .NET SDK: 8.0.425; .NET runtime: 8.0.31
- Culture: `en-US`
- Command: `pwsh -NoProfile -File .\bench\Run-Benchmark.ps1 -Seed 12345 -ScenarioBudget 80 -ConfirmationRuns 3`
- Telemetry: `KEELMATRIX_NO_TELEMETRY=1`
- JSON result: [`bench/results/synthetic-benchmark.json`](../bench/results/synthetic-benchmark.json)
- Console/timing result: [`bench/results/synthetic-benchmark.console.txt`](../bench/results/synthetic-benchmark.console.txt)
- Manifest: [`bench/corpus/manifest.json`](../bench/corpus/manifest.json)

The runner deletes generated corpus output before each build, checks both build exit codes, verifies the expected assemblies, runs the JSON and console forms, and requires their exit codes to match. The planted-divergence command intentionally exits `1`; runner or engine failure exits `2`.

## Synthetic corpus and measurements

The baseline and candidate assemblies have identical public signatures. The candidate plants threshold, null/default, exception-type, collection-order, argument-mutation, async-result, `ValueTask<T>`, and object-graph semantic changes. Equivalent controls, nondeterministic APIs, and unsupported external-state APIs are also present. The manifest contains 85 expected scenario addresses.

| Measurement | Result |
| --- | ---: |
| Discovered callable APIs | 15 baseline / 15 candidate |
| Eligible supported API pairs | 10 |
| APIs actually exercised | 10 |
| Supported API percentage | 66.67% (10/15) |
| Generated scenarios | 80 |
| Stable scenarios | 80 |
| True detected divergence scenarios | 35 |
| False divergence scenarios | 0 |
| Precision | 100% (35/35) |
| Recall within supported planted domain | 100% (35/35) |
| Nondeterministic/inconclusive scenarios | 0 |
| Unsupported API pairs skipped | 5 |
| Execution failures | 0 |
| Median comparison time | 822.9 ms |
| Median witness-minimization time | 0.0 ms (rounded to one decimal) |
| Divergences with minimized witnesses | 35/35 |
| Median input size | 1 |
| Median minimized witness size | 1 |
| Median size reduction | 0 |
| Smallest minimized witness | 0 arguments |

The raw report checks every expected scenario against its manifest label, every unsupported signature as `SKIPPED`, every planted divergence signature as detected, and every equivalent control as clean. It contains only synthetic values and observations.

## Boundary and interpretation

The support filter rejects hidden time, randomness, culture, threading/timing, filesystem, environment, process, network, database, registry, and console state. Resolved user-assembly calls and type initializers are inspected recursively; unresolved or non-allowlisted platform calls are skipped. This deliberately favors unsupported/inconclusive output over speculative findings.

Each confirmation uses a disposable worker process with bounded stdout/stderr, timeout, and process-tree termination. A crash, timeout, cancellation, output overflow, or unrepresentable observation is not equivalence.

Synthetic precision, recall, conservative classification, witness generation, and bounded runtime pass for this corpus. Synthetic truth does not establish real-library value; the pinned real-library evidence and the explicit go-gate evaluation are recorded in [`bench/real-targets.md`](../bench/real-targets.md).
