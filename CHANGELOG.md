# Changelog

All notable changes to BehaviorOracle are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Changed

- Keep installation, comparison, and CI validation guidance aligned with the current tool behavior.

## [0.1.0] - Unreleased

### Added

- `KeelMatrix.BehaviorOracle`, a .NET 8 tool with the `behavior-oracle` command for comparing two library builds within a bounded supported domain.
- Deterministic scenario generation, independent stability confirmation, conservative unsupported/inconclusive results, and minimized behavioral witnesses.
- Versioned console and JSON reports with stable result states, exit codes, and local evidence.
- A composite GitHub Action that builds selected baseline and candidate revisions before invoking the comparison tool.

### Privacy

- Local comparison inputs, observations, and witnesses stay local. Best-effort telemetry is limited to the shared activation and heartbeat contract and is disabled for KeelMatrix development and CI.
