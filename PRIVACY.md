# BehaviorOracle privacy

BehaviorOracle keeps comparison inputs, observations, and minimized witnesses local. It has no hosted comparison backend.

The optional `KeelMatrix.Telemetry` integration emits only the shared anonymous activation and weekly heartbeat contract after a successful comparison. It does not transmit API names, type names, inputs, witnesses, return values, exception text or traces, assembly/package identity, repository names, paths, source, configuration, report contents, or customer outputs.

Telemetry is best-effort, opt-out, and never changes comparison results. Set `KEELMATRIX_NO_TELEMETRY=1` for local or CI validation. KeelMatrix development and validation runs must suppress telemetry and are not demand measurements.

See the [KeelMatrix.Telemetry privacy policy](https://github.com/KeelMatrix/Telemetry/blob/main/PRIVACY.md) for storage, retention, identifier, and opt-out details.
