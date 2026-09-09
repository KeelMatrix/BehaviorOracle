# BehaviorOracle Phase 0 benchmark report

This report records the reproducible synthetic feasibility evidence for the bounded .NET semantic domain. It is an engineering benchmark, not a release-readiness claim.

## Committed recipe and timing method

- Date: 2026-09-09
- Host: Windows 10.0.19045, win-x64
- .NET SDK: 8.0.424 (MSBuild 17.11.48), .NET runtime: 8.0.30
- Recipe: `bench/Run-Benchmark.ps1 -Seed 12345 -ScenarioBudget 80 -ConfirmationRuns 3`
- Worker timeout: `2000 ms`
- Raw result: [`bench/results/synthetic-benchmark.json`](../bench/results/synthetic-benchmark.json)
- Manifest: [`bench/corpus/manifest.json`](../bench/corpus/manifest.json)

The comparison median is the median of the 80 generated scenario comparison timings in this one committed recipe run. Each timing includes three fresh baseline-worker confirmations and three fresh candidate-worker confirmations; witness minimization is measured separately. The minimization median is across the 32 detected divergence scenario records. These are local wall-clock measurements on the host above, not cross-machine performance claims. The report values below are copied from the raw artifact.

## Synthetic corpus

The baseline and candidate assemblies have identical public signatures. The candidate contains eight planted semantic changes: numeric threshold (`Bucket`), null/default string behavior (`Normalize`), exception type (`Parse`), collection order (`Ordered`), argument mutation (`Mutate`), `Task<T>` and `ValueTask<T>` results, and a constructible POCO graph threshold (`Calculator.Apply`). `Calculator.Add` and `TierValue` are unchanged equivalent controls in the same pair.

The corpus also contains a `Guid`-based nondeterministic method and a `Stream`-accepting method. The former must be inconclusive; the latter must be skipped. The manifest records all 81 expected scenario addresses and outcomes, including the one skipped API address.

## Synthetic measurements

| Measurement | Result |
| --- | ---: |
| Discovered callable APIs | 12 baseline / 12 candidate |
| Eligible supported API pairs | 11 |
| APIs actually exercised | 11 |
| Supported API percentage | 91.67% (11/12) |
| Generated scenarios | 80 |
| Stable scenarios | 73 |
| Expected scenario classifications | 81 |
| Divergence scenarios | 32 |
| Clean equivalent-control scenarios | 41 |
| Nondeterministic/inconclusive scenarios | 7 |
| Skipped unsupported API scenarios | 1 |
| Execution failures | 0 |
| False divergence scenarios | 0 |
| Precision | 100% |
| Recall of expected divergence scenarios | 100% |
| Median comparison time | 819.7548 ms |
| Median witness-minimization time | 0.0303 ms |
| Smallest minimized witness size | 0 arguments (`Ordered`) |
| Divergence scenarios with a minimized witness | 32/32 |
| Unsupported/inconclusive rate | 8.75% (7/80 generated scenarios) |

The benchmark runner compares every raw scenario result with the manifest. It separately asserts that every nondeterministic signature is `INCONCLUSIVE`, every unsupported signature is `SKIPPED`, every planted divergence signature has at least one detected divergence, and every equivalent control is clean. The raw artifact contains only synthetic values and observations.

## Support boundary and worker protocol

Support is now filtered at the method level as well as by parameter and return type. The conservative method-body check rejects mutable static field access and calls into filesystem, environment, process, network, database, registry, or console APIs. Same-assembly helper calls are inspected recursively to catch hidden mutable static state. Immutable primitive and string constants remain eligible.

Each confirmation uses a disposable worker process with bounded stdout/stderr, timeout, and process-tree termination. Fresh workers prove only that the bounded observation was stable across those independent runs. Unknown external-state mechanisms that evade the method-body filter can still be masked by fresh-worker isolation; they remain outside the claimed coverage rather than being treated as proof of equivalence. A crash, timeout, cancellation, output overflow, or unrepresentable observation is a failure or conservative non-result.

## Real-target evidence status

The historical Redaction, MockHttp, Newtonsoft.Json, and QueryWatch rows from the earlier probe are explicitly downgraded to unverified spot checks. This ref does not commit the exact package/source hashes, source commit references, configuration, commands, or raw result artifacts needed to reproduce those rows. They are excluded from the synthetic go-gate evidence and must not be described as trustworthy real-library equivalence evidence. See [`bench/real-targets.md`](../bench/real-targets.md).

## Go-gate interpretation

The synthetic precision, recall, witness, runtime, and conservative-classification criteria pass for this bounded corpus. The real-library-value criterion is **UNVERIFIED**, not passed, because the historical real-target spot checks were deliberately excluded. Independent review and the durable-engineering decision remain required; this report does not establish package, CI, telemetry, cross-platform, or release readiness.
