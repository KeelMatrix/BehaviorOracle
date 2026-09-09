using System.Text.Json;

namespace KeelMatrix.BehaviorOracle;

internal sealed record ProbeOptions(
    long Seed = 12345,
    int ScenarioBudget = 500,
    int ConfirmationRuns = 3,
    int WorkerTimeoutMilliseconds = 2000,
    int MaxStdoutBytes = 64 * 1024,
    int MaxStderrBytes = 64 * 1024,
    int MaxObservationDepth = 6,
    int MaxObservationNodes = 512,
    int MaxCollectionItems = 32,
    int MinimizationMaxAttempts = 100,
    int MinimizationTimeoutMilliseconds = 1500)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    public static ProbeOptions FromFile(string path)
    {
        var json = File.ReadAllText(path);
        var value = JsonSerializer.Deserialize<ProbeOptions>(json, JsonOptions);

        return value ?? throw new InvalidDataException("Configuration is empty.");
    }

    public void Validate()
    {
        if (ScenarioBudget is < 1 or > 100_000)
        {
            throw new ArgumentOutOfRangeException(nameof(ScenarioBudget), "Scenario budget must be between 1 and 100000.");
        }

        if (ConfirmationRuns is < 2 or > 9)
        {
            throw new ArgumentOutOfRangeException(nameof(ConfirmationRuns), "Confirmation runs must be between 2 and 9.");
        }

        if (WorkerTimeoutMilliseconds is < 50 or > 120_000)
        {
            throw new ArgumentOutOfRangeException(nameof(WorkerTimeoutMilliseconds), "Worker timeout must be between 50 and 120000 milliseconds.");
        }

        if (MaxStdoutBytes is < 1024 or > 4 * 1024 * 1024 ||
            MaxStderrBytes is < 1024 or > 4 * 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(nameof(MaxStdoutBytes), "Worker output bounds are invalid.");
        }

        if (MaxObservationDepth is < 1 or > 20 ||
            MaxObservationNodes is < 32 or > 100_000 ||
            MaxCollectionItems is < 1 or > 1_000)
        {
            throw new ArgumentOutOfRangeException(nameof(MaxObservationDepth), "Observation bounds are invalid.");
        }

        if (MinimizationMaxAttempts is < 0 or > 10_000 ||
            MinimizationTimeoutMilliseconds is < 0 or > 120_000)
        {
            throw new ArgumentOutOfRangeException(nameof(MinimizationMaxAttempts), "Minimization bounds are invalid.");
        }
    }
}
