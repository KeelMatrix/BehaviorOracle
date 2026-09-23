# KeelMatrix.BehaviorOracle

<!-- KeelMatrix.BehaviorOracle package README: project-local source -->

BehaviorOracle compares two .NET library builds with the same deterministic scenarios and reports a minimized witness when stable observable behavior diverges. It is designed for maintainers who need evidence beyond public API compatibility checks.

## Install

Install the .NET tool globally from NuGet.org:

```powershell
dotnet tool install --global KeelMatrix.BehaviorOracle --version 0.1.1
```

Update an existing installation with:

```powershell
dotnet tool update --global KeelMatrix.BehaviorOracle --version 0.1.1
```

## Quick start

Place the baseline and candidate assemblies, plus the dependencies they need, in separate directories. Create `oracle.json`:

```json
{
  "version": 1,
  "seed": 12345,
  "scenarioBudget": 500,
  "confirmationRuns": 3
}
```

Compare the two build directories:

```powershell
behavior-oracle compare --baseline .\artifacts\baseline --candidate .\artifacts\candidate --config .\oracle.json
```

Use `--format json` for a bounded, deterministic report. A result of `EQUIVALENT WITHIN TESTED DOMAIN` means that no stable divergence was found in the supported scenarios; it is not a proof that the builds are equivalent in every situation.

## Important limitations

- v1 covers a deliberately bounded deterministic domain: supported primitive, enum, string, nullable, array, common finite collection, and constructible object-graph inputs; synchronous and supported `Task<T>`/`ValueTask<T>` methods; return values, exception types, supported argument mutation, and supported public state. Object graphs use public constructors selected by fewest parameters and then canonical parameter-type order, followed by writable public members; types without a legal deterministic path are skipped.
- Filesystem, network, database, process/environment, GUI, native/unsafe, callback, concurrency, timing, random/cryptographic, opaque external-state, and other unsupported behavior is skipped or reported conservatively.
- Both sides must be independently stable before a behavioral divergence is reported. Nondeterministic or unrepresentable observations are inconclusive.
- A divergence is evidence that observable behavior differs; deciding whether it is intentional or a breaking change remains a maintainer decision.
- Comparisons are bounded and read-only with respect to the input artifact directories. Reports can contain API signatures and generated values, so treat retained reports as potentially sensitive.

## Deeper documentation

- [Full product documentation and troubleshooting](https://github.com/KeelMatrix/BehaviorOracle/blob/v0.1.1/README.md)
- [Configuration and report schema change checklist](https://github.com/KeelMatrix/BehaviorOracle/blob/v0.1.1/docs/SCHEMA_CHANGE_CHECKLIST.md)
- [Synthetic benchmark report](https://github.com/KeelMatrix/BehaviorOracle/blob/v0.1.1/docs/benchmark-report.md)
- [Real-library feasibility evidence](https://github.com/KeelMatrix/BehaviorOracle/blob/v0.1.1/bench/real-targets.md)
- [Security policy](https://github.com/KeelMatrix/BehaviorOracle/blob/v0.1.1/SECURITY.md)
- [Privacy](https://github.com/KeelMatrix/BehaviorOracle/blob/v0.1.1/PRIVACY.md)
