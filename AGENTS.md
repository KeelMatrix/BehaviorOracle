# BehaviorOracle development guide

## Navigation

- `src/KeelMatrix.BehaviorOracle` contains the executable tool, surface discovery, deterministic generation, worker protocol, bounded observation, minimization, telemetry adapter, and report/config contracts.
- `tests/KeelMatrix.BehaviorOracle.Tests` contains focused engine, process-contract, CLI, report, and package-boundary tests.
- `bench/corpus` contains the synthetic baseline/candidate benchmark libraries and expected labels.
- `scripts/Invoke-PackageSmoke.ps1` installs the packed tool from an isolated local feed and exercises equivalent and planted-divergence comparisons.
- `action/` contains the composite GitHub Action wrapper. There are no workflows in this repository.

## Commands

```text
dotnet restore KeelMatrix.BehaviorOracle.sln --configfile NuGet.config
dotnet build KeelMatrix.BehaviorOracle.sln -c Release --no-restore
dotnet test KeelMatrix.BehaviorOracle.sln -c Release --no-build
dotnet format KeelMatrix.BehaviorOracle.sln --verify-no-changes
dotnet pack src/KeelMatrix.BehaviorOracle/KeelMatrix.BehaviorOracle.csproj -c Release --no-build
dotnet run --project src/KeelMatrix.BehaviorOracle -- --help
dotnet run --project src/KeelMatrix.BehaviorOracle -- compare --baseline <dir> --candidate <dir> --config <file>
```

Run the local package-consumer smoke with `.\scripts\Invoke-PackageSmoke.ps1`.

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

Run the focused test class first, then the full test project, Release build, format verification, synthetic benchmark, package creation and inspection, isolated package-consumer smoke, and dependency vulnerability check. Record missing platform or network evidence rather than inferring it.
