using System.Globalization;
using Xunit;

namespace KeelMatrix.BehaviorOracle.Tests;

public sealed class CliContractTests
{
    private static readonly SemaphoreSlim ConsoleLock = new(1, 1);

    [Fact]
    public async Task Equivalent_comparison_uses_required_wording_and_zero_exit()
    {
        using var fixture = ComparisonFixture.Create(equalArtifacts: true);
        var result = await RunAsync(
            fixture,
            ["compare", "--baseline", fixture.Baseline, "--candidate", fixture.Candidate, "--config", fixture.Config, "--format", "console"]);

        Assert.Equal(0, result.ExitCode);
        Assert.Contains("EQUIVALENT WITHIN TESTED DOMAIN", result.Stdout, StringComparison.Ordinal);
        Assert.DoesNotContain("BEHAVIORAL DIVERGENCE", result.Stdout, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Divergence_console_includes_both_observations_and_minimized_witness()
    {
        using var fixture = ComparisonFixture.Create(equalArtifacts: false, scenarioBudget: 20);
        var result = await RunAsync(
            fixture,
            ["compare", "--baseline", fixture.Baseline, "--candidate", fixture.Candidate, "--config", fixture.Config, "--format", "console"]);

        Assert.Equal(1, result.ExitCode);
        Assert.Contains("BEHAVIORAL DIVERGENCE", result.Stdout, StringComparison.Ordinal);
        Assert.Contains("API:", result.Stdout, StringComparison.Ordinal);
        Assert.Contains("Input witness:", result.Stdout, StringComparison.Ordinal);
        Assert.Contains("Baseline:", result.Stdout, StringComparison.Ordinal);
        Assert.Contains("Candidate:", result.Stdout, StringComparison.Ordinal);
        Assert.Contains("Minimized witness:", result.Stdout, StringComparison.Ordinal);
        Assert.Contains("Reproduce with seed: 12345", result.Stdout, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Equivalent_json_report_is_byte_deterministic_for_the_same_inputs()
    {
        using var fixture = ComparisonFixture.Create(equalArtifacts: true, scenarioBudget: 8);
        var arguments = new[]
        {
            "compare", "--baseline", fixture.Baseline, "--candidate", fixture.Candidate,
            "--config", fixture.Config, "--format", "json"
        };

        var first = await RunAsync(fixture, arguments);
        var second = await RunAsync(fixture, arguments);

        Assert.Equal(0, first.ExitCode);
        Assert.Equal(0, second.ExitCode);
        Assert.Equal(first.Stdout, second.Stdout);
        Assert.Contains("\"resultState\":\"EQUIVALENT_WITHIN_TESTED_DOMAIN\"", first.Stdout, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Invalid_config_version_is_a_configuration_failure()
    {
        using var fixture = ComparisonFixture.Create(equalArtifacts: true);
        await File.WriteAllTextAsync(fixture.Config, "{\"version\":2,\"seed\":12345}");

        var result = await RunAsync(
            fixture,
            ["compare", "--baseline", fixture.Baseline, "--candidate", fixture.Candidate, "--config", fixture.Config]);

        Assert.Equal(2, result.ExitCode);
        Assert.Contains("Configuration error:", result.Stderr, StringComparison.Ordinal);
        Assert.Contains("version 2", result.Stderr, StringComparison.Ordinal);
    }

    private static async Task<CliResult> RunAsync(ComparisonFixture fixture, IReadOnlyList<string> arguments)
    {
        await ConsoleLock.WaitAsync();
        var oldOut = Console.Out;
        var oldError = Console.Error;
        var stdout = new StringWriter(CultureInfo.InvariantCulture);
        var stderr = new StringWriter(CultureInfo.InvariantCulture);
        var oldOptOut = Environment.GetEnvironmentVariable("KEELMATRIX_NO_TELEMETRY");
        try
        {
            Environment.SetEnvironmentVariable("KEELMATRIX_NO_TELEMETRY", "1");
            Console.SetOut(stdout);
            Console.SetError(stderr);
            var exitCode = await Program.Main(arguments.ToArray());
            return new CliResult(exitCode, stdout.ToString(), stderr.ToString());
        }
        finally
        {
            Console.SetOut(oldOut);
            Console.SetError(oldError);
            Environment.SetEnvironmentVariable("KEELMATRIX_NO_TELEMETRY", oldOptOut);
            stdout.Dispose();
            stderr.Dispose();
            ConsoleLock.Release();
        }
    }

    private sealed record CliResult(int ExitCode, string Stdout, string Stderr);

    private sealed class ComparisonFixture : IDisposable
    {
        private readonly DirectoryInfo root;

        private ComparisonFixture(DirectoryInfo root, string baseline, string candidate, string config)
        {
            this.root = root;
            Baseline = baseline;
            Candidate = candidate;
            Config = config;
        }

        public string Baseline { get; }
        public string Candidate { get; }
        public string Config { get; }

        public static ComparisonFixture Create(bool equalArtifacts, int scenarioBudget = 8)
        {
            var root = Directory.CreateTempSubdirectory("behavior-oracle-cli-");
            var baseline = Directory.CreateDirectory(Path.Combine(root.FullName, "baseline")).FullName;
            var candidate = Directory.CreateDirectory(Path.Combine(root.FullName, "candidate")).FullName;
            var baselineAssembly = Path.Combine(AppContext.BaseDirectory, "Fixtures", "BehaviorOracleCorpus.Baseline.dll");
            var candidateAssembly = Path.Combine(AppContext.BaseDirectory, "Fixtures", "BehaviorOracleCorpus.Candidate.dll");
            File.Copy(baselineAssembly, Path.Combine(baseline, Path.GetFileName(baselineAssembly)));
            File.Copy(
                equalArtifacts ? baselineAssembly : candidateAssembly,
                Path.Combine(candidate, equalArtifacts ? Path.GetFileName(baselineAssembly) : Path.GetFileName(candidateAssembly)));
            var config = Path.Combine(root.FullName, "oracle.json");
            File.WriteAllText(
                config,
                $$"""{"version":1,"seed":12345,"scenarioBudget":{{scenarioBudget}},"confirmationRuns":2}""");
            return new ComparisonFixture(root, baseline, candidate, config);
        }

        public void Dispose()
        {
            for (var attempt = 0; attempt < 10; attempt++)
            {
                try
                {
                    root.Delete(recursive: true);
                    return;
                }
                catch (UnauthorizedAccessException) when (attempt < 9)
                {
                    GC.Collect();
                    GC.WaitForPendingFinalizers();
                    Thread.Sleep(50);
                }
            }

            root.Delete(recursive: true);
        }
    }
}
