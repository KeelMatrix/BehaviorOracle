using System.Text;

namespace KeelMatrix.BehaviorOracle;

internal sealed record BenchmarkManifest(
    int Version,
    string Baseline,
    string Candidate,
    IReadOnlyList<string> PlantedDivergenceSignatures,
    IReadOnlyList<string> NondeterministicSignatures,
    IReadOnlyList<string> UnsupportedSignatures,
    IReadOnlyList<BenchmarkScenarioExpectation> ExpectedScenarios,
    IReadOnlyList<string> EquivalentControlSignatures);

internal sealed record BenchmarkScenarioExpectation(
    string ApiSignature,
    int ScenarioIndex,
    string ExpectedOutcome);

internal sealed class BenchmarkRunner
{
    private readonly ComparisonEngine engine;

    public BenchmarkRunner(ComparisonEngine? engine = null)
    {
        this.engine = engine ?? new ComparisonEngine();
    }

    public async Task<ProbeReport> RunAsync(
        string manifestPath,
        ProbeOptions options,
        string? outputPath,
        CancellationToken cancellationToken = default)
    {
        var manifest = ObservationCodec.Deserialize<BenchmarkManifest>(await File.ReadAllTextAsync(manifestPath, cancellationToken).ConfigureAwait(false)) ??
            throw new InvalidDataException("Benchmark manifest is invalid.");
        if (manifest.Version != 1)
        {
            throw new InvalidDataException("Only benchmark manifest version 1 is supported.");
        }

        var manifestDirectory = Path.GetDirectoryName(Path.GetFullPath(manifestPath))!;
        var baseline = Path.GetFullPath(Path.Combine(manifestDirectory, manifest.Baseline));
        var candidate = Path.GetFullPath(Path.Combine(manifestDirectory, manifest.Candidate));
        var report = await engine.CompareAsync(baseline, candidate, options, cancellationToken).ConfigureAwait(false);
        var expected = manifest.ExpectedScenarios.ToDictionary(
            static scenario => (scenario.ApiSignature, scenario.ScenarioIndex),
            static scenario => scenario.ExpectedOutcome,
            EqualityComparer<(string ApiSignature, int ScenarioIndex)>.Default);
        var actual = report.ScenarioResults.ToDictionary(
            static scenario => (scenario.ApiSignature, scenario.ScenarioIndex),
            static scenario => scenario.Classification,
            EqualityComparer<(string ApiSignature, int ScenarioIndex)>.Default);
        if (expected.Count != manifest.ExpectedScenarios.Count || actual.Count != report.ScenarioResults.Count)
        {
            throw new InvalidDataException("Benchmark scenario expectations contain duplicate addresses.");
        }

        var mismatches = expected
            .Where(pair => !actual.TryGetValue(pair.Key, out var outcome) ||
                !string.Equals(outcome, pair.Value, StringComparison.Ordinal))
            .ToArray();
        var unexpected = actual.Keys.Except(expected.Keys).ToArray();
        if (mismatches.Length > 0 || unexpected.Length > 0)
        {
            var mismatch = mismatches.FirstOrDefault();
            var detail = mismatch.Key == default
                ? "unexpected scenario result"
                : $"{mismatch.Key.ApiSignature} [{mismatch.Key.ScenarioIndex}] expected {mismatch.Value} but got {actual.GetValueOrDefault(mismatch.Key, "missing")}";
            throw new InvalidDataException($"Benchmark scenario expectations failed: {detail}.");
        }

        foreach (var signature in manifest.NondeterministicSignatures)
        {
            if (actual.Where(pair => string.Equals(pair.Key.ApiSignature, signature, StringComparison.Ordinal))
                .Any(static pair => !string.Equals(pair.Value, "INCONCLUSIVE", StringComparison.Ordinal)))
            {
                throw new InvalidDataException($"Nondeterministic signature was not inconclusive: {signature}.");
            }
        }

        foreach (var signature in manifest.UnsupportedSignatures)
        {
            if (actual.Where(pair => string.Equals(pair.Key.ApiSignature, signature, StringComparison.Ordinal))
                .Any(static pair => !string.Equals(pair.Value, "SKIPPED", StringComparison.Ordinal)))
            {
                throw new InvalidDataException($"Unsupported signature was not skipped: {signature}.");
            }
        }

        foreach (var signature in manifest.EquivalentControlSignatures)
        {
            if (actual.Where(pair => string.Equals(pair.Key.ApiSignature, signature, StringComparison.Ordinal))
                .Any(static pair => !string.Equals(pair.Value, "EQUIVALENT", StringComparison.Ordinal)))
            {
                throw new InvalidDataException($"Equivalent control was not clean: {signature}.");
            }
        }

        var expectedDivergences = expected
            .Where(static pair => string.Equals(pair.Value, "DIVERGENCE", StringComparison.Ordinal))
            .Select(static pair => pair.Key)
            .ToHashSet();
        var detectedDivergences = actual
            .Where(static pair => string.Equals(pair.Value, "DIVERGENCE", StringComparison.Ordinal))
            .Select(static pair => pair.Key)
            .ToHashSet();
        foreach (var signature in manifest.PlantedDivergenceSignatures)
        {
            if (!detectedDivergences.Any(key => string.Equals(key.ApiSignature, signature, StringComparison.Ordinal)))
            {
                throw new InvalidDataException($"Planted divergence was not detected: {signature}.");
            }
        }
        var trueDetected = detectedDivergences.Intersect(expectedDivergences).Count();
        var falseDetected = detectedDivergences.Except(expectedDivergences).Count();
        var metrics = new BenchmarkMetrics(
            expectedDivergences.Count,
            trueDetected,
            falseDetected,
            detectedDivergences.Count == 0 ? 1d : (double)trueDetected / detectedDivergences.Count,
            expectedDivergences.Count == 0 ? 1d : (double)trueDetected / expectedDivergences.Count,
            expected.Count,
            0);
        report = report with { Benchmark = metrics };

        if (outputPath is not null)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputPath))!);
            await File.WriteAllTextAsync(outputPath, ObservationCodec.Serialize(report), Encoding.UTF8, cancellationToken).ConfigureAwait(false);
        }

        return report;
    }
}
