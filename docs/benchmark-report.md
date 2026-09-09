# BehaviorOracle synthetic benchmark report

This report records the reproducible synthetic feasibility evidence for the bounded .NET semantic domain. It is an engineering benchmark, not a release-readiness claim.

## Committed recipe and timing method

- Date: 2026-09-09
- Host: Windows 10.0.19045, win-x64
- .NET SDK: 8.0.424 (MSBuild 17.11.48), .NET runtime: 8.0.30
- Recipe: `bench/Run-Benchmark.ps1 -Seed 12345 -ScenarioBudget 80 -ConfirmationRuns 3`
- Worker timeout: `2000 ms`
- Raw result: [`bench/results/synthetic-benchmark.json`](../bench/results/synthetic-benchmark.json)
- Manifest: [`bench/corpus/manifest.json`](../bench/corpus/manifest.json)

The comparison median is the median of the 80 generated scenario comparison timings in this one committed recipe run. Each timing includes three fresh baseline-worker confirmations and three fresh candidate-worker confirmations; witness minimization is measured separately. The minimization median is across the 35 detected divergence scenario records. These are local wall-clock measurements on the host above, not cross-machine performance claims. Timing fields are retained for local benchmark inspection but omitted from the versioned JSON report so repeated reports with the same inputs remain byte-deterministic.

The benchmark runner clears generated baseline/candidate build and copy directories before each run, checks both corpus build exit codes, verifies the required assemblies, and aborts with exit code `2` on build, configuration, or execution failure. A trustworthy planted-divergence result preserves the tool's exit code `1` and is reported separately from runner failure; an equivalent result uses exit code `0`.

## Synthetic corpus

The baseline and candidate assemblies have identical public signatures. The candidate contains eight planted semantic changes: numeric threshold (`Bucket`), null/default string behavior (`Normalize`), exception type (`Parse`), collection order (`Ordered`), argument mutation (`Mutate`), `Task<T>` and `ValueTask<T>` results, and a constructible POCO graph threshold (`Calculator.Apply`). `Calculator.Add` and `TierValue` are unchanged equivalent controls in the same pair.

The corpus also contains a `Guid`-based random method, a `Stream`-accepting method, a direct `DateTime.Today` method, and a method that delegates to `Environment.GetEnvironmentVariable` in the referenced `HiddenStateBridge` assembly. The random method and the other four matched API pairs are skipped, including the referenced helper itself. The manifest records all 85 expected scenario addresses and outcomes.

## Synthetic measurements

| Measurement | Result |
| --- | ---: |
| Discovered callable APIs | 15 baseline / 15 candidate |
| Eligible supported API pairs | 10 |
| APIs actually exercised | 10 |
| Supported API percentage | 66.67% (10/15) |
| Generated scenarios | 80 |
| Stable scenarios | 80 |
| Expected scenario classifications | 85 |
| Divergence scenarios | 35 |
| Clean equivalent-control scenarios | 45 |
| Nondeterministic/inconclusive scenarios | 0 |
| Skipped unsupported API scenarios | 5 |
| Execution failures | 0 |
| False divergence scenarios | 0 |
| Precision | 100% |
| Recall of expected divergence scenarios | 100% |
| Median comparison time | 930.0662 ms |
| Median witness-minimization time | 0.0287 ms |
| Smallest minimized witness size | 0 arguments (`Ordered`) |
| Divergence scenarios with a minimized witness | 35/35 |
| Unsupported/inconclusive rate | 0% (0/80 generated scenarios) |

The benchmark runner compares every raw scenario result with the manifest. It separately asserts that every unsupported signature is `SKIPPED`, every planted divergence signature has at least one detected divergence, and every equivalent control is clean. The raw artifact contains only synthetic values and observations.

## Support boundary and worker protocol

Support is now filtered at the method level as well as by parameter and return type. The deny-by-default method-body check rejects mutable static field access, clock/time, randomness (including `Guid.NewGuid()`), culture, threading/timing, filesystem, environment, process, network, database, registry, or console APIs. Resolved user-assembly callees and type initializers are inspected recursively; unresolved or non-allowlisted platform calls are skipped. Metadata-resolution failures for missing callees remain attached to the affected method as explicit skipped outcomes. Immutable primitive and string constants remain eligible. This closes the demonstrated `DateTime.Today` class and the referenced-assembly environment class without treating stable same-day observations as evidence.

Each confirmation uses a disposable worker process with bounded stdout/stderr, timeout, and process-tree termination. Fresh workers prove only that the bounded observation was stable across those independent runs. The conservative boundary intentionally shrank API support from the previous 91.67% (11/12) to 66.67% (10/15) after adding explicit hidden-state fixtures; precision/recall remain 100% within the honest supported domain, while unsupported API coverage is now visible as five skipped pairs. The generated-scenario unsupported/inconclusive rate is 0% because skipped APIs are not generated; the report must not treat that number as the full API support rate. A crash, timeout, cancellation, output overflow, or unrepresentable observation is a failure or conservative non-result.

## Real-target evidence status

The historical Redaction, MockHttp, Newtonsoft.Json, and QueryWatch rows from the earlier probe are explicitly downgraded to unverified spot checks. This ref does not commit the exact package/source hashes, source commit references, configuration, commands, or raw result artifacts needed to reproduce those rows. They are excluded from the committed synthetic evidence set and must not be described as trustworthy real-library equivalence evidence. See [`bench/real-targets.md`](../bench/real-targets.md).

## Interpretation

The synthetic precision, recall, witness, runtime, and conservative-classification criteria pass for this bounded corpus. The honest supported-domain percentage is 66.67%, so the report does not claim a nominal coverage threshold for breadth; narrowing the domain is the correct response to hidden-state risk. The real-library-value criterion is **UNVERIFIED**, not passed, because the historical real-target spot checks were deliberately excluded. Independent review and the durable-engineering decision remain required; this report does not establish package, CI, telemetry, cross-platform, or release readiness.
