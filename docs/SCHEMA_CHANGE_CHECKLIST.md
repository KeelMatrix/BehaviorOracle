# BehaviorOracle schema change checklist

This document is the required compatibility policy for BehaviorOracle's versioned external contracts. It covers the `oracle.json` configuration file and the JSON report emitted by `behavior-oracle compare --format json`.

This document is required, not optional, because both contracts are consumed by automation outside the tool: configuration selects comparison behavior, and reports are retained or processed by CI and other developer tooling. A contract change must satisfy this checklist before it is merged.

## Normative v1 scope

The following rules define version 1. The canonical JSON spelling is lower camel case; the report serializer emits compact JSON with deterministic ordering and serialization.

### Configuration

An `oracle.json` file is a JSON object with these supported properties:

| Property | Type | Default or requirement | v1 validation |
| --- | --- | --- | --- |
| `version` | integer | Required; `1` | Other versions are rejected |
| `seed` | signed 64-bit integer | `12345` | The value is used as the deterministic scenario seed |
| `scenarioBudget` | integer | `500` | `1` through `100000` |
| `confirmationRuns` | integer | `3` | `2` through `9` |

Unknown properties are rejected. Property-name matching is case-insensitive when the file is read, but new documentation and fixtures must use the canonical spelling above. Command-line overrides are controls for a run, not additional configuration-file properties.

### JSON report

The report's top-level `reportVersion` is the version marker and is `1` for the current contract. Existing top-level field names, JSON types, nullability, result-state values, and meanings are normative. The report includes comparison inputs and bounded evidence such as API counts, scenario outcomes, divergences, witnesses, diagnostics, and the `trustworthy` result.

The allowed result states are:

- `EQUIVALENT_WITHIN_TESTED_DOMAIN`
- `BEHAVIORAL_DIVERGENCE`
- `NONDETERMINISTIC_INCONCLUSIVE`
- `UNSUPPORTED_API`
- `EXECUTION_FAILURE`

The report does not serialize the internal timing properties `medianComparisonMilliseconds` or `medianMinimizationMilliseconds`. A report remains local evidence; it is not a hosted or proof-bearing contract.

The [README result-state and exit-code reference](../README.md#result-states-and-exit-codes) explains the consumer-visible interpretation. The current implementation is represented by [`ProbeOptions`](../src/KeelMatrix.BehaviorOracle/ProbeOptions.cs) and [`ProbeReport`](../src/KeelMatrix.BehaviorOracle/ProbeContracts.cs); those files are implementation references, while this checklist is the compatibility policy.

## Compatibility evaluation

Evaluate a proposed change against the current v1 behavior and representative existing payloads before choosing a version change.

### Configuration changes

A v1 configuration remains compatible only when every existing valid v1 file continues to parse with the same meaning, defaults, validation, and precedence relative to command-line overrides. Renaming or removing a property, changing its type or meaning, changing a default or accepted range, or changing the required version is a breaking contract change.

Adding a property is not automatically compatible: the v1 reader currently rejects unknown properties. Keep an added property out of v1, or deliberately change the reader and make the versioning and migration behavior explicit before documenting it as supported.

### Report changes

An existing v1 report remains compatible when existing fields and result states retain their names, types, nullability, and meanings. An optional additive field may remain in report version 1 only when consumers that ignore unknown JSON properties remain valid and deterministic serialization is preserved. Removing or renaming a field, changing its type or meaning, changing result-state values, or changing the meaning of missing or null data requires a new `reportVersion` and migration guidance.

Changing only the package version does not change either schema version. A schema version changes only when the corresponding external contract changes.

## Required change procedure

For every configuration or report contract change:

1. Record the proposed change and classify it as compatible within v1 or requiring a new schema version. Do not silently reinterpret an existing field.
2. Update this policy and the relevant consumer documentation. Keep the README summary linked to this source of truth.
3. Add or update committed fixtures or golden files for the affected configuration and report shapes. Cover the old shape and the new shape, including defaults, version markers, and any changed result or evidence fields. If no suitable fixture exists, create one in the affected test fixture set rather than relying only on an inline test string.
4. Add or update round-trip coverage. Configuration fixtures must parse to the expected effective options; report fixtures must deserialize and reserialize with semantically equivalent fields. When serialized bytes or ordering are part of the change, assert the deterministic JSON output as well.
5. Run the focused contract tests, then the repository validation commands in [`AGENTS.md`](../AGENTS.md). A contract test must fail if an unsupported schema version, invalid required field, incompatible field change, or non-round-trippable representative payload is introduced.
6. Add a `CHANGELOG.md` entry for an externally observable contract change. State the affected schema, compatibility impact, and migration action. A documentation-only clarification that changes no contract does not require a changelog entry.
7. Before release, verify that package and documentation examples use the intended schema version and that the final changelog and package version remain coherent.

## Versioning decisions

- Preserve version `1` only for changes that meet the compatibility rules above and have the required fixture, round-trip, and focused-test evidence.
- Bump the affected schema version for incompatible changes. Keep the old-version behavior available for the documented migration period when practical, and document the accepted versions and migration path.
- Never make a compatibility claim from a single successful comparison or a single fixture. The report remains evidence of tested behavior, not an automatic breaking-change judgment.
