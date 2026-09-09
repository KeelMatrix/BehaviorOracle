# BehaviorOracle development guide

## Navigation

- `src/KeelMatrix.BehaviorOracle` contains the executable probe, surface discovery, deterministic generation, worker protocol, bounded observation, minimization, and report contracts.
- `tests/KeelMatrix.BehaviorOracle.Tests` contains focused engine and process-contract tests.
- `bench/corpus` contains the synthetic baseline/candidate benchmark libraries and expected labels.
- `docs/benchmark-report.md` records reproducible probe measurements and the current gate result.

## Commands

```text
dotnet restore KeelMatrix.BehaviorOracle.sln
dotnet build KeelMatrix.BehaviorOracle.sln -c Release --no-restore
dotnet test KeelMatrix.BehaviorOracle.sln -c Release --no-build
dotnet format KeelMatrix.BehaviorOracle.sln --verify-no-changes
dotnet run --project src/KeelMatrix.BehaviorOracle -- --help
dotnet run --project src/KeelMatrix.BehaviorOracle -- compare --baseline <dir> --candidate <dir> --config <file>
```

## Invariants

- This repository is the Phase 0 feasibility harness only. It is one net8.0 executable and a test project; it is not a shipping NuGet tool.
- No telemetry, GitHub Actions, hosted execution, source-control orchestration, or release automation belongs in the probe.
- Baseline and candidate code always execute in separate disposable child processes with bounded time and output.
- A worker crash, timeout, cancellation, or unrepresentable observation is never reported as equivalence.
- Divergence requires independently stable baseline and candidate observations; exception messages are excluded from default equality.
- Generated inputs, observations, and minimized witnesses are bounded, deterministic, and local.
- Unsupported APIs are skipped conservatively. The probe never follows filesystem, network, database, callback, native, or opaque external-state behavior to increase coverage.
- Product files contain developer-facing material only. Do not add internal orchestration language, secrets, raw benchmark logs, or temporary artifacts.

## Validation strategy

Run the focused test class first, then the full test project, Release build, format verification, synthetic benchmark, and the documented real-library benchmark subset. Record missing platform or network evidence rather than inferring it.
