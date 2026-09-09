using System.Text;

namespace KeelMatrix.BehaviorOracle;

internal sealed record BenchmarkManifest(
    int Version,
    string Baseline,
    string Candidate,
    IReadOnlyList<string> PlantedDivergenceSignatures,
    IReadOnlyList<string> NondeterministicSignatures,
    IReadOnlyList<string> UnsupportedSignatures);

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
        var planted = manifest.PlantedDivergenceSignatures.ToHashSet(StringComparer.Ordinal);
        var detected = report.Divergences.Select(static divergence => divergence.ApiSignature).ToHashSet(StringComparer.Ordinal);
        var trueDetected = detected.Intersect(planted, StringComparer.Ordinal).Count();
        var falseDetected = detected.Except(planted, StringComparer.Ordinal).Count();
        var metrics = new BenchmarkMetrics(
            planted.Count,
            trueDetected,
            falseDetected,
            detected.Count == 0 ? 1d : (double)trueDetected / detected.Count,
            planted.Count == 0 ? 1d : (double)trueDetected / planted.Count);
        report = report with { Benchmark = metrics };

        if (outputPath is not null)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputPath))!);
            await File.WriteAllTextAsync(outputPath, ObservationCodec.Serialize(report), Encoding.UTF8, cancellationToken).ConfigureAwait(false);
        }

        return report;
    }
}

