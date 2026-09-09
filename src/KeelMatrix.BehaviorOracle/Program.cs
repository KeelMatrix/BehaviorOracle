using System.Globalization;
using System.Text;
using System.Text.Json;

namespace KeelMatrix.BehaviorOracle;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        CultureInfoDefaults.Apply();
        if (args.FirstOrDefault() is "--worker")
        {
            return await WorkerHost.RunAsync().ConfigureAwait(false);
        }

        if (args.Length == 0 || args.Contains("--help", StringComparer.OrdinalIgnoreCase) ||
            args.Contains("-h", StringComparer.OrdinalIgnoreCase))
        {
            PrintHelp();
            return 0;
        }

        try
        {
            var command = args[0].ToLowerInvariant();
            return command switch
            {
                "compare" => await RunCompareAsync(args[1..]).ConfigureAwait(false),
                "benchmark" => await RunBenchmarkAsync(args[1..]).ConfigureAwait(false),
                _ => throw new ArgumentException($"Unknown command '{args[0]}'.")
            };
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidDataException or DirectoryNotFoundException or IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"Configuration error: {exception.Message}");
            return 2;
        }
    }

    private static async Task<int> RunCompareAsync(string[] args)
    {
        var values = ArgumentMap.Parse(args);
        var baseline = values.Required("baseline");
        var candidate = values.Required("candidate");
        _ = values.Required("config");
        var options = values.ToOptions();
        var report = await new ComparisonEngine().CompareAsync(baseline, candidate, options).ConfigureAwait(false);
        WriteReport(report, values.Get("format") ?? "console");
        if (report.HasSuccessfulSupportedScenario)
        {
            TelemetryHost.TrackSuccessfulComparison();
        }

        return report.Trustworthy
            ? report.DivergenceCount == 0 ? 0 : 1
            : 2;
    }

    private static async Task<int> RunBenchmarkAsync(string[] args)
    {
        var values = ArgumentMap.Parse(args);
        var manifest = values.Required("manifest");
        var options = values.ToOptions();
        var report = await new BenchmarkRunner().RunAsync(
            manifest,
            options,
            values.Get("output")).ConfigureAwait(false);
        WriteReport(report, values.Get("format") ?? "console");
        return report.Trustworthy
            ? report.DivergenceCount == 0 ? 0 : 1
            : 2;
    }

    private static void WriteReport(ProbeReport report, string format)
    {
        if (string.Equals(format, "json", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine(ObservationCodec.Serialize(report));
            return;
        }

        if (!string.Equals(format, "console", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("Format must be console or json.");
        }

        Console.WriteLine(report.ResultState switch
        {
            ProbeResultStates.EquivalentWithinTestedDomain => "EQUIVALENT WITHIN TESTED DOMAIN",
            ProbeResultStates.BehavioralDivergence => "BEHAVIORAL DIVERGENCE",
            ProbeResultStates.NondeterministicInconclusive => "NONDETERMINISTIC_INCONCLUSIVE",
            ProbeResultStates.UnsupportedApi => "UNSUPPORTED_API",
            _ => "EXECUTION_FAILURE"
        });
        Console.WriteLine($"Matched callable APIs: {report.MatchedCallableApis}");
        Console.WriteLine($"Eligible supported API pairs: {report.EligibleSupportedApiPairs}");
        Console.WriteLine($"APIs actually exercised: {report.ExercisedApiCount}");
        Console.WriteLine($"Unsupported APIs: {report.UnsupportedApiCount}");
        Console.WriteLine($"Generated scenarios: {report.GeneratedScenarios}");
        Console.WriteLine($"Stable scenarios: {report.StableScenarios}");
        Console.WriteLine($"Behavioral divergences: {report.DivergenceCount}");
        Console.WriteLine($"Unsupported/inconclusive scenarios: {report.UnsupportedCount + report.InconclusiveCount}");
        Console.WriteLine($"Median comparison time: {report.MedianComparisonMilliseconds.ToString("F1", CultureInfo.InvariantCulture)} ms");
        Console.WriteLine($"Seed: {report.Seed}");

        foreach (var divergence in report.Divergences.Take(10))
        {
            Console.WriteLine();
            Console.WriteLine("API:");
            Console.WriteLine($"  {divergence.ApiSignature}");
            Console.WriteLine("Input witness:");
            Console.WriteLine(FormatWitness(divergence.Input));
            Console.WriteLine("Baseline:");
            Console.WriteLine($"  {ObservationCodec.Serialize(divergence.Baseline)}");
            Console.WriteLine("Candidate:");
            Console.WriteLine($"  {ObservationCodec.Serialize(divergence.Candidate)}");
            Console.WriteLine("Minimized witness:");
            Console.WriteLine(FormatWitness(divergence.MinimizedInput));
            Console.WriteLine($"Reproduce with seed: {divergence.MinimizedInput.Seed}");
            Console.WriteLine("This is evidence of a behavioral difference, not an automatic breaking-change judgment.");
        }

        if (report.DivergenceCount > report.Divergences.Count)
        {
            Console.WriteLine();
            Console.WriteLine($"Additional divergences omitted from the bounded report: {report.DivergenceCount - report.Divergences.Count}");
        }
    }

    private static string FormatWitness(GeneratedScenario scenario)
    {
        if (scenario.Arguments.Count == 0)
        {
            return "  (no arguments)";
        }

        return string.Join(
            Environment.NewLine,
            scenario.Arguments.Select((argument, index) => $"  arg{index} = {FormatValue(argument, 0)}"));
    }

    private static string FormatValue(GeneratedValue value, int depth)
    {
        if (depth > 6)
        {
            return "<depth limit>";
        }

        return value.Kind switch
        {
            GeneratedValueKind.Null => "null",
            GeneratedValueKind.Boolean => value.BooleanValue ? "true" : "false",
            GeneratedValueKind.Integer => value.UnsignedIntegerValue?.ToString(CultureInfo.InvariantCulture) ?? value.IntegerValue.ToString(CultureInfo.InvariantCulture),
            GeneratedValueKind.FloatingPoint => value.FloatingPointValue.ToString("R", CultureInfo.InvariantCulture),
            GeneratedValueKind.Decimal => value.TextValue ?? "0",
            GeneratedValueKind.String => JsonSerializer.Serialize(value.TextValue ?? string.Empty),
            GeneratedValueKind.Enum => value.TextValue ?? "<enum>",
            GeneratedValueKind.Collection => "[" + string.Join(", ", (value.Items ?? []).Take(16).Select(item => FormatValue(item, depth + 1))) + "]",
            GeneratedValueKind.Object => "{" + string.Join(", ", (value.Members ?? new Dictionary<string, GeneratedValue>()).OrderBy(pair => pair.Key, StringComparer.Ordinal).Take(16).Select(pair => $"{pair.Key}: {FormatValue(pair.Value, depth + 1)}")) + "}",
            _ => "<unknown>"
        };
    }

    private static void PrintHelp()
    {
        Console.WriteLine(
            """
            BehaviorOracle

            behavior-oracle compare --baseline <dir> --candidate <dir> [options]
            behavior-oracle benchmark --manifest <file> [options]

            Options:
              --config <file>              Read version-1 JSON options (required for compare).
              --seed <number>              Deterministic scenario seed.
              --scenario-budget <number>   Total generated scenarios.
              --confirmation-runs <number> Stable confirmation runs (default 3).
              --timeout <milliseconds>     Per-worker timeout.
              --format console|json        Report format.
              --output <file>              Write a benchmark JSON report.

            A successful result is equivalent only within the tested semantic domain.
            """
        );
    }
}

internal sealed class ArgumentMap
{
    private readonly Dictionary<string, string> values;
    private static readonly HashSet<string> KnownKeys =
    [
        "baseline", "candidate", "config", "seed", "scenario-budget", "confirmation-runs",
        "timeout", "format", "manifest", "output"
    ];

    private ArgumentMap(Dictionary<string, string> values)
    {
        this.values = values;
    }

    public static ArgumentMap Parse(IEnumerable<string> args)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var arguments = args.ToArray();
        for (var index = 0; index < arguments.Length; index++)
        {
            var argument = arguments[index];
            if (!argument.StartsWith("--", StringComparison.Ordinal))
            {
                throw new ArgumentException($"Unexpected argument '{argument}'.");
            }

            var key = argument[2..];
            if (key is "help" or "h")
            {
                continue;
            }

            if (!KnownKeys.Contains(key))
            {
                throw new ArgumentException($"Unknown option '--{key}'.");
            }

            if (++index >= arguments.Length || arguments[index].StartsWith("--", StringComparison.Ordinal))
            {
                throw new ArgumentException($"Option '--{key}' requires a value.");
            }

            if (!values.TryAdd(key, arguments[index]))
            {
                throw new ArgumentException($"Option '--{key}' was specified more than once.");
            }
        }

        return new ArgumentMap(values);
    }

    public string Required(string key) =>
        Get(key) ?? throw new ArgumentException($"Option '--{key}' is required.");

    public string? Get(string key) => values.GetValueOrDefault(key);

    public ProbeOptions ToOptions()
    {
        var options = Get("config") is string config
            ? ProbeOptions.FromFile(config)
            : new ProbeOptions();
        return options with
        {
            Seed = Long("seed", options.Seed),
            ScenarioBudget = Integer("scenario-budget", options.ScenarioBudget),
            ConfirmationRuns = Integer("confirmation-runs", options.ConfirmationRuns),
            WorkerTimeoutMilliseconds = Integer("timeout", options.WorkerTimeoutMilliseconds)
        };
    }

    private int Integer(string key, int fallback)
    {
        if (Get(key) is not string value)
        {
            return fallback;
        }

        return int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : throw new ArgumentException($"Option '--{key}' must be an integer.");
    }

    private long Long(string key, long fallback)
    {
        if (Get(key) is not string value)
        {
            return fallback;
        }

        return long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : throw new ArgumentException($"Option '--{key}' must be an integer.");
    }
}
