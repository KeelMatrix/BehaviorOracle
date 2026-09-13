# Privacy

BehaviorOracle keeps comparison inputs, observations, and minimized witnesses local. It has no hosted comparison backend.

## Product data boundary

The comparison command does not transmit API names, type names, inputs, witnesses, return values, exception text or traces, assembly/package identity, repository names, paths, source, configuration, report contents, or customer outputs. BehaviorOracle does not upload comparison artifacts to a KeelMatrix service.

## Optional telemetry

The optional `KeelMatrix.Telemetry` integration requests only the shared anonymous activation and weekly heartbeat contract after a successful comparison. Installation, invalid configuration, a comparison with no executable supported scenario, and a failed comparison do not activate telemetry.

Telemetry is best-effort and opt-out. Network or telemetry failure cannot affect comparison results.

## Local state and controls

BehaviorOracle does not persist comparison inputs, observations, reports, or witnesses. The shared telemetry dependency may create local marker or queue files to support delivery and opt-out; its maintained policy documents those details.

Set `KEELMATRIX_NO_TELEMETRY=1` for local or CI validation. KeelMatrix development and validation runs must suppress telemetry and are not demand measurements. The shared telemetry package also honors its documented process and repository-local opt-out controls.

## Shared telemetry policy

See the [KeelMatrix.Telemetry privacy policy](https://github.com/KeelMatrix/Telemetry/blob/main/PRIVACY.md) for storage, retention, identifier, and opt-out details.
