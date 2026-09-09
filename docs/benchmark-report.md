# BehaviorOracle Phase 0 benchmark report

This report records the feasibility-probe evidence for the bounded .NET semantic domain. It is an engineering benchmark, not a release-readiness claim.

## Run configuration

- Date: 2026-09-09
- Host: Windows 10.0.19045, win-x64
- .NET SDK: 8.0.424 (MSBuild 17.11.48), .NET runtime 8.0.30
- Seed: `12345`
- Synthetic scenario budget: `80`
- Confirmation runs: `3`
- Worker timeout: `2000 ms` (real-target smoke used `1000 ms`)
- Synthetic command: `bench/Run-Benchmark.ps1 -Seed 12345 -ScenarioBudget 80 -ConfirmationRuns 3`

The run uses separate disposable worker processes, bounded observations and logs, deterministic generation, conservative support filtering, and bounded witness minimization. No Linux or macOS evidence is claimed.

## Synthetic corpus

The baseline and candidate assemblies have identical public signatures. The candidate contains eight planted semantic changes:

1. numeric threshold (`Bucket`);
2. null/default string behavior (`Normalize`);
3. exception type (`Parse`);
4. collection order (`Ordered`);
5. argument mutation (`Mutate`);
6. `Task<T>` result (`AsyncResult`);
7. `ValueTask<T>` result (`ValueTaskResult`);
8. constructible POCO graph threshold (`Calculator.Apply`).

The corpus also contains a `Guid`-based nondeterministic method and a `Stream`-accepting method. The former must be inconclusive; the latter is outside the supported domain and must be filtered.

## Synthetic measurements

| Measurement | Result |
| --- | ---: |
| Discovered callable APIs | 12 baseline / 12 candidate |
| Supported API percentage | 91.67% (11/12) |
| Generated scenarios | 80 |
| Stable scenarios | 73 |
| Planted divergence APIs | 8 |
| True detected divergence APIs | 8 |
| False divergence APIs | 0 |
| Precision | 100% |
| Recall within supported domain | 100% |
| Median comparison time | 791.7 ms |
| Median witness-minimization time | 0.0289 ms |
| Smallest minimized witness size | 0 arguments (the parameterless `Ordered` API) |
| Detected APIs with a minimized witness | 8/8 |
| Nondeterministic/inconclusive scenarios | 7 |
| Unsupported scenario outcomes | 0 |
| Unsupported API count | 1 (`Stream`) |
| Unsupported/inconclusive scenario rate | 8.75% (7/80) |
| Worker execution failures | 0 |

The JSON artifact is written to disposable `artifacts/synthetic-benchmark.json` and is intentionally ignored by Git. The report contains API signatures, seed-bearing inputs, baseline/candidate observations, and minimized inputs; exception messages and sensitive values are not part of the default equality contract.

### Witness summary

All eight planted divergence APIs produced a stable minimized witness. Numeric, string, collection, mutation, async, and POCO witnesses were reduced by rerunning both workers after each candidate shrink. The zero-argument result is expected for `Ordered`; it is still a useful witness because the returned collection order is the contract difference.

## Real-world evaluation

All targets were evaluated from disposable scratch copies. Reference repositories were not modified.

| Target and pair | Matched APIs | Supported | Generated / stable | Divergences | Unsupported APIs | Result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| KeelMatrix.Redaction package `0.1.0` vs read-only source Release output | 20 | 18 (90.00%) | 30 / 30 | 0 | 2 | trustworthy equivalent within tested domain |
| RichardSzalay.MockHttp `7.0.0` vs `7.1.0`, `netstandard2.0` | 92 | 0 (0.00%) | 0 / 0 | 0 | 92 | conservatively skipped; no finding |
| Newtonsoft.Json `13.0.1` vs `13.0.3`, `netstandard2.0` | 686 (+1 added API) | 42 (6.12%) | 20 / 20 | 0 | 644 | trustworthy equivalent within tested domain |
| KeelMatrix.QueryWatch source Release output copied to both sides | 5 | 0 (0.00%) | 0 / 0 | 0 | 5 | conservatively skipped; no finding |

The Redaction package and QueryWatch package version indexes were checked against NuGet on this run; both currently list `0.1.0`. MockHttp currently lists `7.1.0`; the comparison intentionally uses its two comparable published versions `7.0.0` and `7.1.0`. The MockHttp and QueryWatch outcomes demonstrate that unsupported HTTP/integration-heavy surfaces are not forced through generation. The Newtonsoft run also exercised the recursion guard against a self-enumerating public type and terminated safely after the guard fix.

## Go-gate mapping

The following is the honest result for the eight mandatory feasibility criteria. “Pass” applies only to this bounded Phase 0 evidence and does not approve durable product engineering or release.

| Criterion | Evidence | Gate |
| --- | --- | --- |
| Precision at least 95% | 8 true API detections, 0 false API detections: 100% | PASS |
| Recall at least 70% | 8/8 supported planted divergence APIs detected: 100% | PASS |
| No recurring false-positive class requiring domain-specific suppression | 0 false divergence APIs; unsupported and nondeterministic cases were excluded | PASS for this corpus |
| Useful minimized witnesses for most simple divergences | 8/8 planted divergence APIs have stable minimized witnesses | PASS |
| Bounded runtime suitable for ordinary CI | 80-scenario local run completed on Windows; median comparison 751.4 ms and every worker has a 2-second timeout | PASS for this bounded probe; the default 500-scenario profile was not timed or claimed |
| Conservative deterministic/nondeterministic classification | 7 nondeterministic scenarios inconclusive; no nondeterministic finding | PASS |
| Meaningful real-library value without mandatory custom factories | Redaction exercised 18 supported APIs; Newtonsoft exercised 42; no custom factories were used | PASS for the demonstrated surfaces |
| Independent reviewer can understand a finding without engine internals | Finding records contain signature, seed, input, both observations, and minimized input; independent review was not separately conducted | EVIDENCE PRESENT; independent review pending |

The implementation therefore supports continuing only with an independent review and durable-engineering decision. It does not establish package, CI, telemetry, cross-platform, or release readiness.

## Freshness note

Checked 2026-09-09:

- [KeelMatrix.Redaction on NuGet](https://www.nuget.org/packages/KeelMatrix.Redaction) and [KeelMatrix.QueryWatch on NuGet](https://www.nuget.org/packages/KeelMatrix.QueryWatch): the live v3 flat-container indexes list `0.1.0` for each.
- [RichardSzalay.MockHttp on NuGet](https://www.nuget.org/packages/RichardSzalay.MockHttp): the live listing/index includes `7.0.0` and `7.1.0`, with `7.1.0` current at the time of the check.
- [.NET API compatibility tools](https://learn.microsoft.com/en-us/dotnet/fundamentals/apicompat/overview): current .NET SDK/API-compatibility tooling covers API compatibility checks, but it does not provide this probe’s runtime scenario generation, process isolation, observation, stability, or behavioral witness comparison. The overlap is surface/API compatibility only; it is not a substitute for this feasibility probe.
