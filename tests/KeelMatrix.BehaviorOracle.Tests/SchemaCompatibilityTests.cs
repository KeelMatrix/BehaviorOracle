using System.Text.Json;
using Xunit;

namespace KeelMatrix.BehaviorOracle.Tests;

public sealed class SchemaCompatibilityTests
{
    private static readonly string[] ConfigurationPropertyNames =
        ["version", "seed", "scenarioBudget", "confirmationRuns"];

    private static readonly string FixtureDirectory = Path.Combine(
        AppContext.BaseDirectory,
        "Fixtures",
        "Schema",
        "v1");

    [Fact]
    public void Version_1_configuration_fixture_uses_the_documented_shape_and_values()
    {
        var json = ReadFixture("oracle.json");
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;

        Assert.Equal(JsonValueKind.Object, root.ValueKind);
        Assert.Equal(
            ConfigurationPropertyNames,
            root.EnumerateObject().Select(static property => property.Name).ToArray());
        Assert.Equal(1, root.GetProperty("version").GetInt32());

        var path = Path.Combine(FixtureDirectory, "oracle.json");
        var options = ProbeOptions.FromFile(path);

        Assert.Equal(12345, options.Seed);
        Assert.Equal(20, options.ScenarioBudget);
        Assert.Equal(2, options.ConfirmationRuns);
        options.Validate();
    }

    [Fact]
    public void Version_1_configuration_reader_rejects_unsupported_versions_and_unknown_properties()
    {
        var fixture = ReadFixture("oracle.json");
        var root = Directory.CreateTempSubdirectory("behavior-oracle-schema-");
        try
        {
            var unsupportedVersionPath = Path.Combine(root.FullName, "unsupported-version.json");
            File.WriteAllText(unsupportedVersionPath, fixture.Replace("\"version\": 1", "\"version\": 2", StringComparison.Ordinal));
            var versionException = Assert.Throws<InvalidDataException>(() => ProbeOptions.FromFile(unsupportedVersionPath));
            Assert.Contains("version 2", versionException.Message, StringComparison.Ordinal);

            var unknownPropertyPath = Path.Combine(root.FullName, "unknown-property.json");
            File.WriteAllText(
                unknownPropertyPath,
                fixture.Replace("\n}", ",\n  \"unsupported\": true\n}", StringComparison.Ordinal));
            var propertyException = Assert.Throws<InvalidDataException>(() => ProbeOptions.FromFile(unknownPropertyPath));
            Assert.Contains("unsupported", propertyException.Message, StringComparison.Ordinal);
        }
        finally
        {
            root.Delete(recursive: true);
        }
    }

    [Fact]
    public void Version_1_report_fixture_round_trips_to_the_committed_deterministic_golden()
    {
        var json = ReadFixture("report.json");
        var report = ObservationCodec.Deserialize<ProbeReport>(json);

        Assert.NotNull(report);
        Assert.Equal(1, report!.ReportVersion);
        Assert.Equal(ProbeResultStates.BehavioralDivergence, report.ResultState);
        Assert.True(report.Trustworthy);
        Assert.Single(report.Divergences);
        Assert.Equal(report.DivergenceCount, report.Divergences.Count);
        var scenarioResult = Assert.Single(report.ScenarioResults);
        Assert.Equal("DIVERGENCE", scenarioResult.Classification);
        Assert.Null(report.Benchmark);
        Assert.DoesNotContain("medianComparisonMilliseconds", json, StringComparison.Ordinal);
        Assert.DoesNotContain("medianMinimizationMilliseconds", json, StringComparison.Ordinal);

        Assert.Equal(json.TrimEnd('\r', '\n'), ObservationCodec.Serialize(report));
    }

    private static string ReadFixture(string name) =>
        File.ReadAllText(Path.Combine(FixtureDirectory, name));
}
