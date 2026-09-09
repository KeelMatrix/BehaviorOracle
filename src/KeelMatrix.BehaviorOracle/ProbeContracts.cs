using System.Text.Json;
using System.Text.Json.Serialization;

namespace KeelMatrix.BehaviorOracle;

internal enum ProbeResultKind
{
    EquivalentWithinTestedDomain,
    BehavioralDivergence,
    NondeterministicInconclusive,
    UnsupportedApi,
    ExecutionFailure
}

internal enum GeneratedValueKind
{
    Null,
    Boolean,
    Integer,
    FloatingPoint,
    Decimal,
    String,
    Enum,
    Collection,
    Object
}

internal sealed record GeneratedValue
{
    public GeneratedValueKind Kind { get; init; }
    public string? TypeName { get; init; }
    public bool BooleanValue { get; init; }
    public long IntegerValue { get; init; }
    public double FloatingPointValue { get; init; }
    public string? TextValue { get; init; }
    public IReadOnlyList<GeneratedValue>? Items { get; init; }
    public IReadOnlyDictionary<string, GeneratedValue>? Members { get; init; }

    public static GeneratedValue Null(string? typeName) => new() { Kind = GeneratedValueKind.Null, TypeName = typeName };
}

internal sealed record GeneratedScenario(
    int Index,
    long Seed,
    IReadOnlyList<GeneratedValue> Arguments)
{
    public int Size => Arguments.Sum(static argument => ValueSize(argument));

    private static int ValueSize(GeneratedValue value)
    {
        var size = 1;
        if (value.Items is not null)
        {
            size += value.Items.Sum(ValueSize);
        }

        if (value.Members is not null)
        {
            size += value.Members.Values.Sum(ValueSize);
        }

        if (value.TextValue is not null)
        {
            size += value.TextValue.Length;
        }

        return size;
    }
}

internal sealed record ApiDescriptor(
    string Signature,
    string DeclaringTypeName,
    string MethodName,
    string AssemblyPath,
    bool IsStatic,
    bool IsConstructor,
    IReadOnlyList<string> ParameterTypeNames,
    string ReturnTypeName,
    string? UnsupportedReason)
{
    [JsonIgnore]
    public bool IsSupported => UnsupportedReason is null;
}

internal sealed record SurfaceMember(
    string Signature,
    string DeclaringTypeName,
    string MemberName,
    bool IsConstructor,
    bool IsStatic,
    IReadOnlyList<string> ParameterTypeNames,
    string ReturnTypeName,
    string? UnsupportedReason);

internal sealed record ApiSurface(
    string AssemblyPath,
    IReadOnlyList<SurfaceMember> Members,
    IReadOnlyList<ApiDescriptor> CallableMembers,
    IReadOnlyList<string> LoadErrors);

internal sealed record ApiPair(ApiDescriptor Baseline, ApiDescriptor Candidate);

internal sealed record WorkerRequest(
    string AssemblyPath,
    string MethodSignature,
    IReadOnlyList<GeneratedValue> Arguments,
    string WorkingDirectory,
    int MaxObservationDepth = 6,
    int MaxObservationNodes = 512,
    int MaxCollectionItems = 32);

internal sealed record WorkerResponse(
    bool Success,
    Observation? Observation,
    string? FailureCategory,
    int? OutputBytes = null);

internal sealed record ObservedValue(
    string Kind,
    string? TypeName = null,
    string? Scalar = null,
    IReadOnlyList<ObservedValue>? Items = null,
    IReadOnlyDictionary<string, ObservedValue>? Members = null);

internal sealed record Observation(
    string Outcome,
    ObservedValue? ReturnValue,
    string? ExceptionType,
    IReadOnlyList<ObservedValue>? ArgumentsBefore,
    IReadOnlyList<ObservedValue>? ArgumentsAfter,
    ObservedValue? ReceiverAfter,
    bool IsRepresentable)
{
    [JsonIgnore]
    public string Canonical => ObservationCodec.Serialize(this);
}

internal sealed record DivergenceRecord(
    string ApiSignature,
    GeneratedScenario Input,
    Observation Baseline,
    Observation Candidate,
    GeneratedScenario MinimizedInput,
    TimeSpan MinimizationTime,
    int MinimizationAttempts);

internal sealed record BenchmarkMetrics(
    int PlantedDivergences,
    int TrueDetectedDivergences,
    int FalseDivergences,
    double Precision,
    double Recall,
    int ExpectedScenarioCount,
    int ScenarioOutcomeMismatches);

internal sealed record ScenarioResult(
    string ApiSignature,
    int ScenarioIndex,
    string Classification,
    string? FailureCategory = null);

internal sealed record ProbeReport
{
    public int ReportVersion { get; init; } = 1;
    public long Seed { get; init; }
    public int ScenarioBudget { get; init; }
    public int ConfirmationRuns { get; init; }
    public int MatchedCallableApis { get; init; }
    public int EligibleSupportedApiPairs { get; init; }
    public int ExercisedApiCount { get; init; }
    public int UnsupportedApiCount { get; init; }
    public double SupportedApiPercentage { get; init; }
    public int DiscoveredBaselineApis { get; init; }
    public int DiscoveredCandidateApis { get; init; }
    public int AddedApis { get; init; }
    public int RemovedApis { get; init; }
    public int GeneratedScenarios { get; init; }
    public int StableScenarios { get; init; }
    public int DivergenceCount { get; init; }
    public int InconclusiveCount { get; init; }
    public int UnsupportedCount { get; init; }
    public int ExecutionFailureCount { get; init; }
    public double UnsupportedOrInconclusiveRate { get; init; }
    public double MedianComparisonMilliseconds { get; init; }
    public double MedianMinimizationMilliseconds { get; init; }
    public int MinimizedWitnessSize { get; init; }
    public bool Trustworthy { get; init; }
    public IReadOnlyList<string> AddedApiSignatures { get; init; } = [];
    public IReadOnlyList<string> RemovedApiSignatures { get; init; } = [];
    public IReadOnlyList<DivergenceRecord> Divergences { get; init; } = [];
    public IReadOnlyList<ScenarioResult> ScenarioResults { get; init; } = [];
    public BenchmarkMetrics? Benchmark { get; init; }
    public IReadOnlyList<string> Diagnostics { get; init; } = [];
}

internal static class ObservationCodec
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };

    public static string Serialize<T>(T value) =>
        JsonSerializer.Serialize(value, Options);

    public static T? Deserialize<T>(string json) =>
        JsonSerializer.Deserialize<T>(json, Options);
}
