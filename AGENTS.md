# BehaviorOracle development guide

## Navigation

- `src/KeelMatrix.BehaviorOracle` contains the executable tool, surface discovery, deterministic generation, worker protocol, bounded observation, minimization, telemetry adapter, and report/config contracts.
- `tests/KeelMatrix.BehaviorOracle.Tests` contains focused engine, process-contract, CLI, report, and package-boundary tests.
- `bench/corpus` contains the synthetic baseline/candidate benchmark libraries and expected labels.
- `scripts/Invoke-PackageSmoke.ps1` installs the packed tool from an isolated local feed and exercises equivalent and planted-divergence comparisons.
- `action/` contains the composite GitHub Action wrapper and entrypoint.
- `.github/workflows/ci.yml` defines repository CI: a Windows/Linux/macOS platform matrix and a dependent Ubuntu package inspection and consumer-smoke job.

## Commands

```text
dotnet restore KeelMatrix.BehaviorOracle.sln --configfile NuGet.config -p:NuGetAudit=false
dotnet build KeelMatrix.BehaviorOracle.sln --configuration Release --no-restore --warnaserror
dotnet test KeelMatrix.BehaviorOracle.sln --configuration Release --no-build --no-restore
dotnet format KeelMatrix.BehaviorOracle.sln --verify-no-changes
pwsh -NoProfile -File .\bench\Run-Benchmark.ps1 -Seed 12345 -ScenarioBudget 80 -ConfirmationRuns 3
dotnet pack src/KeelMatrix.BehaviorOracle/KeelMatrix.BehaviorOracle.csproj --configuration Release --no-build --no-restore --include-symbols --p:SymbolPackageFormat=snupkg --output .\artifacts\packages
pwsh -NoProfile -File .\scripts\Invoke-PackageSmoke.ps1 -PackagePath .\artifacts\packages\KeelMatrix.BehaviorOracle.0.1.0.nupkg -Seed 12345 -ScenarioBudget 20 -ConfirmationRuns 2
dotnet list KeelMatrix.BehaviorOracle.sln package --vulnerable --include-transitive
dotnet run --project src/KeelMatrix.BehaviorOracle -- --help
dotnet run --project src/KeelMatrix.BehaviorOracle -- compare --baseline <dir> --candidate <dir> --config <file>
```

The benchmark intentionally reports the planted divergence with exit code `1`; the package smoke expects an equivalent comparison to exit `0` and a planted divergence to exit `1`. CI additionally requires the full passing test suite with worker/process coverage, exact package and symbol archives, archive contents, and telemetry suppression. Its `platform` job runs on `windows-latest`, `ubuntu-latest`, and `macos-latest`; the dependent `package` job runs on `ubuntu-latest`.

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

Run the focused test class first, then the full test project, Release build, format verification, synthetic benchmark, package creation and inspection, isolated package-consumer smoke, and dependency vulnerability check. CI repeats repository validation on Windows, Linux, and macOS runners and performs package inspection and consumer smoke on Ubuntu. Record missing platform or network evidence rather than inferring it.
