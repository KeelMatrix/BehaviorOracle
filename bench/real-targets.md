# Real-library feasibility evidence

This is the reproducible real-library evaluation for the bounded BehaviorOracle semantic domain. It compares pinned published package assets from two versions of each target. It does not claim arbitrary semantic equivalence, and it does not infer precision or recall for published-version pairs without a ground-truth label.

## Reproduction

The committed recipe is [`real-targets/Invoke-RealLibraryBenchmark.ps1`](real-targets/Invoke-RealLibraryBenchmark.ps1). Its inputs are [`real-targets/targets.json`](real-targets/targets.json) and [`real-targets/config.json`](real-targets/config.json). The script downloads from the NuGet v3 flat-container endpoint, verifies every package file with the SHA-512 recorded in `targets.json`, extracts only the pinned assembly/dependency assets, runs console and JSON comparisons, and requires a repeated JSON command to have the same exit code and bytes.

Run from the repository root after restore and a Release build:

```powershell
$env:KEELMATRIX_NO_TELEMETRY = '1'
dotnet restore KeelMatrix.BehaviorOracle.sln --configfile NuGet.config -p:NuGetAudit=false
dotnet build KeelMatrix.BehaviorOracle.sln --configuration Release --no-restore --warnaserror
pwsh -NoProfile -File .\bench\real-targets\Invoke-RealLibraryBenchmark.ps1
```

The script bounds each tool process at 300,000 ms and captures each stdout/stderr stream at 4 MiB. It records the runtime environment and tool assembly SHA-512 in [`results/real-targets/summary.json`](results/real-targets/summary.json). All raw bounded outputs are committed:

- [`summary.json`](results/real-targets/summary.json)
- [`humanizer-core.json`](results/real-targets/humanizer-core.json) and [`humanizer-core.console.txt`](results/real-targets/humanizer-core.console.txt)
- [`newtonsoft-json.json`](results/real-targets/newtonsoft-json.json) and [`newtonsoft-json.console.txt`](results/real-targets/newtonsoft-json.console.txt)
- [`npgsql.json`](results/real-targets/npgsql.json) and [`npgsql.console.txt`](results/real-targets/npgsql.console.txt)

## Target identity and exact artifacts

The package IDs, versions, asset paths, package SHA-512 hashes, dependency hash, and source commit references are the machine-readable source of truth in `targets.json`.

| Target | Role | Baseline → candidate | Source commits |
| --- | --- | --- | --- |
| `Humanizer.Core` | deterministic transformation-oriented | 2.13.14 → 2.14.1 | `18167e56c082449cc4fe805b8429e3127a7b7f93` → `3ebc38de585fc641a04b0e78ed69468453b0f8a1` |
| `Newtonsoft.Json` | more complex deterministic serialization | 13.0.2 → 13.0.3 | `4fba53a324c445f06ee08e45a015c346000a7ef2` → `0a2e291c0d9c0c7675d445703e51750363a549ef` |
| `Npgsql` | deliberately out-of-domain database/network surface | 8.0.4 → 8.0.5 | `6990cceffbca2d2de4c5f12df32729bc78bbeafb` → `2e914cc92562216b479e90a72846ed2f09e7527a` |

The full baseline/candidate package SHA-512 values are committed alongside these identities in `targets.json`; the Npgsql logging-abstractions dependency is pinned there too. No source build or planted source change is used: each pair is a published package-to-published-package differential, which is why real-target precision/recall are explicitly `null` rather than guessed.

## Environment and results

- OS: Windows 10.0.19045 (`win-x64`)
- .NET SDK: 8.0.425
- Runtime: .NET 8.0.31 available
- Culture/UI culture: `en-US`
- Seed: 12345
- Scenario budget: 32 per target
- Confirmation runs: 3
- Custom factories/generators: none for any target
- Engine assembly SHA-512: recorded in `summary.json`

| Target | Result | Discovered baseline/candidate | Matched | Supported pairs | Supported % | Exercised | Generated/stable | Divergences | Inconclusive | Unsupported APIs | Median comparison | Repeated JSON |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Humanizer.Core | `EQUIVALENT_WITHIN_TESTED_DOMAIN` | 392 / 414 | 392 | 25 | 6.38% | 25 | 32 / 32 | 0 | 0 | 367 | 807.5 ms | byte-identical |
| Newtonsoft.Json | `EQUIVALENT_WITHIN_TESTED_DOMAIN` | 687 / 687 | 687 | 1 | 0.15% | 1 | 32 / 32 | 0 | 0 | 686 | 837.7 ms | byte-identical |
| Npgsql | `NONDETERMINISTIC_INCONCLUSIVE` | 838 / 839 | 838 | 32 | 3.82% | 32 | 32 / 29 | 0 | 3 | 806 | 1,102.8 ms | byte-identical |

The real targets exercised 58 supported API pairs and produced 93 stable scenarios without any mandatory custom generation. The deterministic transformation target supplied 25 automatically exercised APIs. The more complex serialization target was intentionally reported honestly at one supported API. Npgsql produced three inconclusive scenarios and no divergence; the raw diagnostics show conservative classification rather than forced execution through network/database state.

Real-target minimization is not applicable because no stable real divergence was found. Synthetic truth-labeled evidence supplies the minimization measurement: 35/35 detected planted divergences had minimized witnesses, with median input size 1, median minimized size 1, median reduction 0, and smallest witness size 0; the console artifact records the bounded timing.

## Scope assessment

| Mandatory criterion | Verdict | Evidence |
| --- | --- | --- |
| At least 95% precision on planted changes in the supported domain | **PASS** | Synthetic corpus: 35 true detections, 0 false detections, 100% precision. Real pairs have no ground-truth labels and are not used to inflate this number. |
| At least 70% recall on supported planted changes | **PASS** | Synthetic corpus: 35/35 expected divergence scenarios detected, 100% recall. |
| No recurring false-positive class requiring domain-specific suppression | **PASS** | Synthetic corpus: 0 false divergence scenarios; hidden time/randomness/external-state cases were skipped. Real pairs produced 0 divergences. |
| Useful minimized witnesses for most detected simple divergences | **PASS** | 35/35 synthetic divergence records include minimized witnesses; console output shows API, input, both observations, minimized witness, and seed. No real divergence was available to score. |
| Bounded runtime suitable for ordinary CI | **PASS** | Synthetic median comparison: 822.9 ms for 80 scenarios; real-target per-scenario medians: 807.5–1,102.8 ms, with bounded end-to-end JSON runs of about 26.2–29.9 s per 32-scenario target. |
| Conservative deterministic/nondeterministic classification | **PASS** | Synthetic unsupported state cases are skipped; Npgsql has 3 inconclusive scenarios and 0 reported divergences. Repeated JSON output is byte-identical for all three targets. |
| Meaningful real-library value without mandatory custom factories/generators | **PASS (narrow domain)** | 58 real API pairs were exercised automatically and 93 scenarios were stable; 25 Humanizer APIs received deterministic comparison without custom setup. Coverage is intentionally low on the complex and out-of-domain targets and remains an explicit limitation. |

## Conclusion

The evaluation supports the explicitly bounded semantic domain, with real-library value demonstrated narrowly and conservatively. It does not establish broader coverage, hosted execution, or publication suitability. The low real-world supported percentages, lack of ground-truth real divergences, and lack of a real minimization witness remain documented limitations.
