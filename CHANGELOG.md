# Changelog

All notable changes to BehaviorOracle are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

## [0.1.0] - 2026-09-15

### Added

- A .NET 8 tool with the `behavior-oracle` command compares two library builds within a deliberately bounded supported domain.
- Deterministic, seed-driven scenario generation and independent stability confirmation identify stable behavioral differences while classifying unsupported or nondeterministic cases conservatively.
- Versioned console and JSON reports provide stable result states, documented exit codes, and minimized deterministic witnesses for reproducible local or CI investigation.
- A composite GitHub Action builds selected baseline and candidate revisions, validates requested revisions, and runs comparisons with documented full-history and tag-checkout requirements.
- Comparisons run in separate bounded child processes, remain read-only with respect to input artifact directories, and keep inputs, observations, and witnesses local by default; best-effort telemetry uses only the shared activation and heartbeat contract and is disabled for KeelMatrix development and CI.
