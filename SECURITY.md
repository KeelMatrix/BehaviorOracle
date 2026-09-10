# Security Policy

## Reporting a vulnerability

Report suspected vulnerabilities privately before any public disclosure:

1. Email **keelmatrix@gmail.com**.
2. Open a private GitHub Security Advisory for this repository.

Do not create a public issue or publicly disclose vulnerability details, exploit steps, credentials, personal data, library inputs, generated witnesses, or private reports.

Include, when safe:

- the affected BehaviorOracle package version, command or Action, target framework, and operating system;
- minimal reproduction steps or a proof of concept;
- the security impact and affected trust boundary, especially where compared assemblies or process execution are involved;
- relevant sanitized logs and suggested mitigation, if known.

We aim to acknowledge reports within five business days and will provide follow-up as the assessment proceeds. Do not include secrets or unnecessary customer data in a report.

## Scope

This policy covers the BehaviorOracle tool package, its comparison workers, report handling, telemetry integration, composite Action, and repository release artifacts. Vulnerabilities in a library being compared, its dependencies, or a user's build environment should be reported to the relevant maintainer, but may be included when they expose a BehaviorOracle security boundary.

## Supported versions

Security fixes are prioritized for the latest maintained BehaviorOracle release line and its supported .NET 8 runtime environments. Older versions and unsupported runtimes may receive fixes on a case-by-case basis.
