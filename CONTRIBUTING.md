# Contributing

Contributions are welcome as focused fixes, tests, and documentation improvements.

## Before you begin

Use a clean clone and keep generated output, credentials, customer data, and machine-specific paths out of commits. Set `KEELMATRIX_NO_TELEMETRY=1` during local validation so development activity is not counted as external demand.

Maintainer commit checks are documented in the [Git hooks guide](.githooks/README.md).

## Make changes

Changes to CLI options, configuration, report states, exit codes, or supported semantic behavior should include focused regression coverage and matching README or changelog updates. Keep the core comparison read-only with respect to compared artifact directories.

## Validate locally

Use the commands in [`AGENTS.md`](AGENTS.md) for the repository CI-equivalent path. They cover restore, Release build, tests, formatting, the synthetic benchmark, the bounded pinned real-library subset, package inspection, isolated package-consumer smoke, and dependency auditing.

After the Release build, run the real-library subset and its fail-closed contract check:

```powershell
$env:KEELMATRIX_NO_TELEMETRY = '1'
pwsh -NoProfile -File .\bench\real-targets\Invoke-RealLibraryBenchmark.ps1
pwsh -NoProfile -File .\bench\real-targets\Test-RealLibraryBenchmark.ps1
```

The benchmark uses the three package version/SHA-512 pairs committed in `bench/real-targets/targets.json`, a 32-scenario maximum, three confirmation runs, a five-minute per-comparison bound, and bounded output capture. It fails closed when package retrieval, hash validation, asset extraction, comparison, reproducibility, or committed stable evidence validation fails. The contract check deliberately supplies an over-budget configuration and verifies rejection.

## Validate a local build

From the repository root, run the tool from a clean clone with:

```powershell
$env:KEELMATRIX_NO_TELEMETRY = '1'
dotnet restore .\KeelMatrix.BehaviorOracle.sln --configfile .\NuGet.config -p:NuGetAudit=false
dotnet run --project .\src\KeelMatrix.BehaviorOracle -- --help
```

To validate the packed tool, pack it and run the isolated package contract and consumer checks:

```powershell
dotnet build .\KeelMatrix.BehaviorOracle.sln --configuration Release --no-restore --warnaserror
dotnet pack .\src\KeelMatrix.BehaviorOracle\KeelMatrix.BehaviorOracle.csproj --configuration Release --no-build --no-restore --include-symbols -p:SymbolPackageFormat=snupkg --output .\artifacts\packages
$commit = (git rev-parse HEAD).Trim()
pwsh -NoProfile -File .\scripts\Verify-PackageContract.ps1 -PackagePath .\artifacts\packages\KeelMatrix.BehaviorOracle.0.1.1.nupkg -SymbolsPath .\artifacts\packages\KeelMatrix.BehaviorOracle.0.1.1.snupkg -ExpectedRepositoryCommit $commit
pwsh -NoProfile -File .\scripts\Invoke-PackageSmoke.ps1 -PackagePath .\artifacts\packages\KeelMatrix.BehaviorOracle.0.1.1.nupkg -SymbolsPath .\artifacts\packages\KeelMatrix.BehaviorOracle.0.1.1.snupkg -ExpectedRepositoryCommit $commit -Seed 12345 -ScenarioBudget 20 -ConfirmationRuns 2
```

The smoke test uses an isolated local feed and cache directories; it does not change a global tool installation. The release dry run is expected to pass only after the target changelog entry is finalized. It can be run earlier to exercise the gate, but the changelog contract is expected to fail until release preparation is complete:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-ReleaseDryRun.ps1 -Tag v0.1.1
pwsh -NoProfile -File .\scripts\Test-ReleasePublicationContractContract.ps1
```

A planned changelog entry is expected to fail the release dry-run gate until release preparation is complete. The dry run never publishes the package.

Package inspection requires documentation links shipped in the package to use the release tag form `blob/v<package-version>/...`. Pre-release local inspection validates that stable reference form without requiring the future tag to exist, so `Invoke-ReleaseDryRun.ps1` remains usable before tagging. The tag-triggered release workflow passes `-VerifyReleaseReference` to `Verify-PackageContract.ps1`; that gate requires the checked-out `v<package-version>` tag to resolve to the exact release commit.

## Validate the Action wrapper

On Windows, run:

```powershell
pwsh -NoProfile -File .\action\Test-Action.ps1
```

This covers equivalent and divergent comparisons, invalid paths, candidate build failures, tool installation failures, relative paths, spaces, Windows casing, exit-code propagation, and cleanup.

## Security and community

Security reports must use the private channels in [`SECURITY.md`](SECURITY.md), not a public issue. Community conduct concerns should follow [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md), not the vulnerability-reporting route.
