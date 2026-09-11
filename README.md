# KeelMatrix.BehaviorOracle

Public API compatibility can stay green while behavior changes underneath it. BehaviorOracle runs the same deterministic scenarios against two .NET library builds and reports a minimized witness when stable observable behavior diverges.

BehaviorOracle is evidence gathering, not a proof of arbitrary semantic equivalence and not an automatic breaking-change judgment.

## Install, update, and uninstall

Install the first public package from NuGet.org with:

```powershell
dotnet tool install --global KeelMatrix.BehaviorOracle --version 0.1.0
```

Update an existing installation with:

```powershell
dotnet tool update --global KeelMatrix.BehaviorOracle --version 0.1.0
```

Remove it with:

```powershell
dotnet tool uninstall --global KeelMatrix.BehaviorOracle
```

The package is not published yet. Before publication, use the source and
isolated package-smoke commands below to validate the current release candidate.

## Try the current unreleased build

The first `0.1.0` package is not published yet. Run the current source from a clean clone with:

```powershell
dotnet restore .\KeelMatrix.BehaviorOracle.sln --configfile .\NuGet.config -p:NuGetAudit=false
dotnet run --project .\src\KeelMatrix.BehaviorOracle -- --help
```

To exercise the packed tool before publication, use the repository's package smoke command described below. It installs from an isolated local feed rather than changing your global tool installation.

## Package validation for maintainers

The repository's package contract is checked against the actual `.nupkg` and `.snupkg` archives. `scripts/Verify-PackageContract.ps1` uses an explicit allowlist for runtime, symbol, source, and NuGet-generated metadata entries; validates package metadata, the 512x512 icon and SourceLink; rejects unexpected archive entries; and repeats packing to compare canonical archive hashes. The only canonicalization is for the random identifiers NuGet generates in the allowlisted core-properties relationship metadata.

The package-consumer smoke uses fresh `NUGET_PACKAGES`, HTTP-cache, plugin-cache, scratch, and .NET CLI home directories plus a generated source-mapped NuGet configuration. `KeelMatrix.BehaviorOracle` resolves only from the local candidate feed; its runtime dependency resolves from NuGet.org. It verifies the installed candidate package hash before exercising equivalent and planted-divergence comparisons.

After finalizing the target `CHANGELOG.md` entry, maintainers can validate the first-release path without publishing by running `pwsh -NoProfile -File .\scripts\Invoke-ReleaseDryRun.ps1 -Tag v0.1.0`. The dry-run checks the exact-commit changelog/version contract, the workflow's version-output handoff, builds and packs the exact version, inspects both archives, runs the isolated consumer smoke, and explicitly skips publication. A planned or unreleased changelog entry is expected to fail this gate until release preparation is complete.

The pinned real-library evidence under `bench/real-targets.md` uses a documented deterministic Release build contract and a two-clean-clone engine-hash check. Its report JSON, counts, classifications, signatures, witnesses, and hashes are stable evidence; elapsed timings and host-environment snapshots are intentionally volatile context and are not compared for exact equality.

## Five-minute comparison

Build the baseline and candidate library artifacts into separate directories. The directories must contain the assemblies and dependencies needed to execute the compared APIs.

Create `oracle.json`:

```json
{
  "version": 1,
  "seed": 12345,
  "scenarioBudget": 500,
  "confirmationRuns": 3
}
```

Run the comparison:

```powershell
behavior-oracle compare --baseline .\artifacts\baseline --candidate .\artifacts\candidate --config .\oracle.json
```

Useful command-line overrides are `--seed`, `--scenario-budget`, `--timeout` (milliseconds), and `--format console|json`. The configuration file is required for `compare`; command-line overrides take precedence over its values.

An equivalent result looks like:

```text
EQUIVALENT WITHIN TESTED DOMAIN

Matched callable APIs: 84
Supported APIs exercised: 52
Stable scenarios: 418
Behavioral divergences: 0
Unsupported/inconclusive scenarios: 32
```

The phrase “within tested domain” is intentional. Unsupported APIs do not become evidence of equivalence.

## Result states and exit codes

The versioned JSON report uses one of these result states:

- `EQUIVALENT_WITHIN_TESTED_DOMAIN`
- `BEHAVIORAL_DIVERGENCE`
- `NONDETERMINISTIC_INCONCLUSIVE`
- `UNSUPPORTED_API`
- `EXECUTION_FAILURE`

Exit codes are:

- `0`: the comparison completed without a stable divergence. The report may still contain unsupported or inconclusive items.
- `1`: at least one stable behavioral divergence was found.
- `2`: configuration, worker, loading, timeout, cancellation, or other execution failure prevented a trustworthy comparison.

Use `--format json` for machine-readable output. Reports are schema version `1`, bounded, deterministic in ordering and serialization, and contain local evidence only. They can include API signatures, generated witnesses, observations, and minimized witnesses; treat retained reports as potentially sensitive.

## Troubleshooting

- Exit code `2` means configuration, loading, worker, timeout, or another execution failure prevented a trustworthy comparison. Check the paths, config version, dependencies, and host runtime first.
- `UNSUPPORTED_API` and `NONDETERMINISTIC_INCONCLUSIVE` are conservative results, not evidence of equivalence. Review the API classification and run a focused scenario when the behavior is part of your contract.
- A stable divergence should be rerun with its reported seed and minimized witness before deciding whether the change is intentional or breaking.

## Divergence interpretation

A divergence includes the matched API signature, generated input witness, baseline observation, candidate observation, minimized witness, and reproduction seed:

```text
BEHAVIORAL DIVERGENCE

API:
  Example.PricePolicy::GetDiscount(System.Int32)->System.Int32
Input witness:
  arg0 = 100
Baseline:
  {"outcome":"returned", ...}
Candidate:
  {"outcome":"returned", ...}
Minimized witness:
  arg0 = 100
Reproduce with seed: 12345
```

This is evidence that the two builds behaved differently for a tested scenario. It does not decide whether the change is intentional, compatible, or a breaking change.

## Supported v1 domain

BehaviorOracle currently generates and observes:

- public static methods;
- public instance methods on constructible public classes and structs;
- synchronous methods plus `Task<T>` and `ValueTask<T>` when their values fit the supported domain;
- primitives, enums, strings, nullable values, one-dimensional arrays, and common finite collection shapes;
- shallow bounded POCO graphs created through public constructors and writable public members;
- deterministic return values, deterministic exception types, supported argument mutation, and supported public object state after execution.

Generation is deterministic from the explicit seed. The built-in corpus includes boundary numeric values, empty and bounded strings, Unicode, bounded collections, enum values, and bounded object variants. Recursion, collection size, observation depth, output, worker time, scenario count, and minimization attempts are bounded.

## Unsupported and inconclusive behavior

The tool skips or classifies conservatively when an API requires filesystem, network, database, process/environment, native, unsafe, callback, opaque external, timing, concurrency, cryptographic, random, or otherwise unsupported state. Huge stateful models and arbitrary application behavior are outside v1.

Before comparing sides, each scenario runs repeatedly against the baseline and candidate independently. A scenario is divergent only when both sides are internally stable and their normalized observations differ. Nondeterministic or unrepresentable observations are inconclusive rather than equivalence. Worker crashes and timeouts are execution failures, never equivalence.

Normalization is deliberately minimal. BehaviorOracle does not sort collections, remove timestamps globally, or ignore fields merely to make results look equivalent. Exception messages are excluded from default equality; exception types remain observable.

For a stable divergence, the minimizer tries bounded reductions such as simpler numbers, shorter strings, fewer collection items, and default object members. Every accepted reduction is re-run on both sides and must preserve stable divergence.

## Process and security model

Baseline and candidate calls execute in separate disposable child processes. Worker stdout and stderr are bounded, timeouts terminate the process tree, and temporary working directories are removed after each call. The worker is not an operating-system security sandbox. Run comparisons in an environment where executing the library assemblies is acceptable, such as your own CI or development machine; BehaviorOracle does not execute customer assemblies on a KeelMatrix service.

The tool does not access network, filesystem, database, or other external state to make an unsupported API testable. Full witnesses remain local by default.

## Telemetry and privacy

BehaviorOracle uses `KeelMatrix.Telemetry` for a minimal anonymous activation and weekly heartbeat. Activation is requested only after a comparison completes with at least one supported scenario executed against both sides. Installation, invalid configuration, a comparison with no executable supported scenario, and a failed comparison do not count as activation.

Telemetry is best-effort and cannot affect comparison results. It does not send API names, type names, inputs, witnesses, return values, exception text or traces, assembly/package identity, repository names, paths, source, configuration, report contents, or customer outputs. Reports stay local.

Disable telemetry for a process with:

```powershell
$env:KEELMATRIX_NO_TELEMETRY = "1"
```

The shared telemetry package also honors `DOTNET_CLI_TELEMETRY_OPTOUT`, `DO_NOT_TRACK`, and supported repository-local opt-out files. See the [privacy policy](https://github.com/KeelMatrix/BehaviorOracle/blob/main/PRIVACY.md).

## GitHub Action wrapper

The repository includes a composite Action under `action/`. After the tool package is available from the configured package source, it builds the selected baseline and candidate Git revisions and invokes the same tool:

```yaml
- name: Compare library behavior
  uses: KeelMatrix/BehaviorOracle/action@main
  with:
    baseline-ref: v1.2.0
    candidate-ref: ${{ github.sha }}
    project: src/Example/Example.csproj
    config: .github/behavior-oracle.json
```

The wrapper requires the tool version to be available from the configured package source. It does not replace ordinary build or API-compatibility checks.

Maintainers can validate the committed wrapper on Windows with:

```powershell
pwsh -NoProfile -File .\action\Test-Action.ps1
```

The validation exercises equivalent, divergent, invalid-path, candidate-build-failure, and tool-install-failure cases. It also covers relative paths, spaces, Windows casing, exit-code propagation, and cleanup. The committed evidence is Windows PowerShell with .NET 8; Linux and macOS Action support is not claimed until independently exercised.

## Platform evidence and limitations

The repository's CI validates the tool and worker/process scenarios with .NET 8.0 on `windows-latest`, `ubuntu-latest`, and `macos-latest` in its `platform` job. That matrix runs restore, a Release build with warnings as errors, format verification, the full test suite, the deterministic synthetic benchmark, the ordinary dependency-audit mode, and telemetry-suppression checks. The Windows matrix leg also validates the committed Action wrapper.

The separate `dependency-audit-required` job runs on `ubuntu-latest` and fails closed when vulnerability-advisory data is unavailable. After the platform matrix passes, the dependent `package` job runs on `ubuntu-latest`. It packs the `KeelMatrix.BehaviorOracle` 0.1.0 package and symbols, inspects the exact archive contents, installs the packed tool from an isolated feed, exercises equivalent and planted-divergence comparisons, and verifies telemetry remains suppressed. See the [CI workflow](https://github.com/KeelMatrix/BehaviorOracle/blob/main/.github/workflows/ci.yml).

This evidence covers the tested .NET 8.0 tool and worker/process scenarios on those GitHub-hosted runner images. It does not guarantee that every compared assembly runs on every operating system; behavior remains subject to the compared library and host environment.

BehaviorOracle does not build source revisions as part of its core engine, guarantee arbitrary equivalence, infer author intent, compare performance, test concurrency semantics, or provide a hosted execution sandbox. Build baseline and candidate artifacts separately and inspect every reported difference in the context of your library's contract.

The permanent synthetic corpus and benchmark recipe under `bench/` cover planted threshold, null/default, exception-type, collection-order, mutation, async, object-graph, nondeterministic, and external-state cases. The `benchmark` command is development-only and is absent from the shipped help; `bench/Run-Benchmark.ps1` enables it for the committed regression corpus. Real-library value remains dependent on the target library's supported deterministic surface.

## Findings checklist

When a report contains a divergence:

1. Re-run the same command and seed.
2. Confirm the minimized witness is legal for the library's intended contract.
3. Inspect the baseline and candidate observations, including mutation and exception type.
4. Decide whether the change is intentional and whether its compatibility policy treats it as breaking.
5. Add a focused regression test or an explicit normalizer only when the behavior is genuinely non-contractual.

BehaviorOracle helps produce evidence for that review; it does not make the review decision for you.

## License

BehaviorOracle is available under the MIT License. See [`LICENSE`](LICENSE).
