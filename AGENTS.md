# BehaviorOracle development guide

## Navigation

- `src/KeelMatrix.BehaviorOracle` contains the executable tool, surface discovery, deterministic generation, worker protocol, bounded observation, minimization, telemetry adapter, and report/config contracts.
- `tests/KeelMatrix.BehaviorOracle.Tests` contains focused engine, process-contract, CLI, report, and package-boundary tests.
- `bench/corpus` contains the synthetic baseline/candidate benchmark libraries and expected labels.
- `bench/real-targets` contains the pinned published-library evaluation recipe and committed bounded results.
- `docs/benchmark-report.md` records the synthetic benchmark contract and captured measurements.
- `scripts/Verify-PackageContract.ps1` inspects the exact package and symbol archives and checks repeat-pack determinism.
- `scripts/Invoke-PackageSmoke.ps1` installs the packed tool from an isolated local feed and exercises equivalent and planted-divergence comparisons.
- `scripts/Test-EngineReproducibility.ps1` builds two clean path-separated clones and asserts identical Release engine hashes.
- `scripts/Invoke-ReleaseDryRun.ps1` validates the tag-version handoff and exercises the non-publishing release build, pack, inspection, and consumer path.
- `scripts/Invoke-DependencyAudit.ps1` provides the fail-closed dependency audit used by CI.
- `action/` contains the composite GitHub Action wrapper and entrypoint.
- `.github/workflows/ci.yml` defines repository CI: a Windows/Linux/macOS platform matrix, a required Ubuntu dependency-audit job, and a dependent Ubuntu package inspection and consumer-smoke job.
- `.github/workflows/release.yml` defines the tag-driven package validation and publication workflow.

## Commands

```text
dotnet restore KeelMatrix.BehaviorOracle.sln --configfile NuGet.config -p:NuGetAudit=false
dotnet build KeelMatrix.BehaviorOracle.sln --configuration Release --no-restore --warnaserror
dotnet test KeelMatrix.BehaviorOracle.sln --configuration Release --no-build --no-restore
dotnet format KeelMatrix.BehaviorOracle.sln --verify-no-changes
pwsh -NoProfile -File .\bench\Run-Benchmark.ps1 -Seed 12345 -ScenarioBudget 80 -ConfirmationRuns 3
pwsh -NoProfile -File .\action\Test-Action.ps1  # Windows only
dotnet pack src/KeelMatrix.BehaviorOracle/KeelMatrix.BehaviorOracle.csproj --configuration Release --no-build --no-restore --include-symbols -p:SymbolPackageFormat=snupkg --output .\artifacts\packages
pwsh -NoProfile -File .\scripts\Verify-PackageContract.ps1 -PackagePath .\artifacts\packages\KeelMatrix.BehaviorOracle.0.1.0.nupkg -SymbolsPath .\artifacts\packages\KeelMatrix.BehaviorOracle.0.1.0.snupkg -ExpectedRepositoryCommit (git rev-parse HEAD)
pwsh -NoProfile -File .\scripts\Invoke-PackageSmoke.ps1 -PackagePath .\artifacts\packages\KeelMatrix.BehaviorOracle.0.1.0.nupkg -SymbolsPath .\artifacts\packages\KeelMatrix.BehaviorOracle.0.1.0.snupkg -ExpectedRepositoryCommit (git rev-parse HEAD) -Seed 12345 -ScenarioBudget 20 -ConfirmationRuns 2
pwsh -NoProfile -File .\scripts\Test-EngineReproducibility.ps1
pwsh -NoProfile -File .\scripts\Invoke-ReleaseDryRun.ps1 -Tag v0.1.0
pwsh -NoProfile -File .\scripts\Invoke-DependencyAudit.ps1 -Mode Required -Solution KeelMatrix.BehaviorOracle.sln
pwsh -NoProfile -File .\scripts\Test-DependencyAudit.ps1
dotnet run --project src/KeelMatrix.BehaviorOracle -- --help
dotnet run --project src/KeelMatrix.BehaviorOracle -- compare --baseline <dir> --candidate <dir> --config <file>
```

The benchmark intentionally reports its planted divergence with exit code `1`; it is enabled only by `bench/Run-Benchmark.ps1` and is not a shipped CLI command. The package smoke expects an equivalent comparison to exit `0` and a planted divergence to exit `1`. `action/Test-Action.ps1` validates the Action wrapper on Windows PowerShell/.NET 8, including path handling, failure propagation, and cleanup. CI runs the full test, format, benchmark, dependency-audit, and telemetry-suppression checks on `windows-latest`, `ubuntu-latest`, and `macos-latest`; the Windows matrix leg also runs the Action validation. A separate Ubuntu job fails closed when advisory data is unavailable, and the dependent Ubuntu `package` job inspects the exact archives and runs the isolated consumer smoke.

## Invariants

- The shipping artifact is one `net8.0` .NET tool package with command `behavior-oracle`; it has no supported library API.
- Configuration and report schema version `1` are compatibility contracts.
- Public callable surface matching uses fully qualified compatible signatures.
- Every generated scenario is deterministic from the explicit seed and stays within configured scenario, process, observation, output, and minimization bounds.
- Baseline and candidate code always execute in separate disposable child processes with bounded time and output.
- A worker crash, timeout, cancellation, or unrepresentable observation is never reported as equivalence.
- Divergence requires independently stable baseline and candidate observations; exception messages are excluded from default equality.
- Generated inputs, observations, and minimized witnesses are bounded, deterministic, and local.
- Unsupported APIs are skipped conservatively. The tool never follows filesystem, network, database, callback, native, or opaque external-state behavior to increase coverage.
- `compare` is read-only with respect to the input artifact directories. It does not rewrite, delete, or instrument compared assemblies.
- Telemetry is requested only after a successful comparison has executed at least one supported scenario on both sides; `KEELMATRIX_NO_TELEMETRY=1` is used for local and validation runs.

## Validation strategy

Run the focused test class first, then the full test project, Release build, format verification, synthetic benchmark, package contract inspection, isolated package-consumer smoke, and required dependency audit. Run `action/Test-Action.ps1` on Windows. The real-library evaluation is a separate network-dependent check. CI repeats repository validation on Windows, Linux, and macOS runners, runs the required fail-closed audit on Ubuntu, and performs package inspection and consumer smoke on Ubuntu. Record missing platform or network evidence rather than inferring it.
