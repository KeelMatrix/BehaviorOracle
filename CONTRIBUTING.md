# Contributing

Contributions are welcome as focused fixes, tests, and documentation improvements.

## Validate locally

Use the commands in [`AGENTS.md`](AGENTS.md) for the repository CI-equivalent path. They cover restore, Release build, tests, formatting, the synthetic benchmark, package inspection, isolated package-consumer smoke, and dependency auditing.

Set `KEELMATRIX_NO_TELEMETRY=1` during local validation. Keep fixtures, reports, and documentation free of credentials, customer data, and machine-specific paths.

Changes to CLI options, configuration, report states, exit codes, or supported semantic behavior should include focused regression coverage and matching README or changelog updates.

Security reports must use the private channels in [`SECURITY.md`](SECURITY.md), not a public issue.
