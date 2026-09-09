using System.Diagnostics;

namespace KeelMatrix.BehaviorOracle;

internal sealed class ComparisonEngine
{
    private readonly ApiSurfaceDiscoverer discoverer;
    private readonly ScenarioGenerator generator;
    private readonly WorkerRunner baselineRunner;
    private readonly WorkerRunner candidateRunner;
    private readonly WitnessMinimizer minimizer;

    public ComparisonEngine(
        ApiSurfaceDiscoverer? discoverer = null,
        ScenarioGenerator? generator = null,
        WorkerRunner? baselineRunner = null,
        WorkerRunner? candidateRunner = null,
        WitnessMinimizer? minimizer = null)
    {
        this.discoverer = discoverer ?? new ApiSurfaceDiscoverer();
        this.generator = generator ?? new ScenarioGenerator();
        this.baselineRunner = baselineRunner ?? new WorkerRunner();
        this.candidateRunner = candidateRunner ?? new WorkerRunner();
        this.minimizer = minimizer ?? new WitnessMinimizer();
    }

    public async Task<ProbeReport> CompareAsync(
        string baselineDirectory,
        string candidateDirectory,
        ProbeOptions options,
        CancellationToken cancellationToken = default)
    {
        options.Validate();
        var baseline = discoverer.DiscoverDirectory(baselineDirectory);
        var candidate = discoverer.DiscoverDirectory(candidateDirectory);
        var baselineMethods = baseline.CallableMembers.ToDictionary(static member => member.Signature, StringComparer.Ordinal);
        var candidateMethods = candidate.CallableMembers.ToDictionary(static member => member.Signature, StringComparer.Ordinal);
        var matchedSignatures = baselineMethods.Keys.Intersect(candidateMethods.Keys, StringComparer.Ordinal)
            .OrderBy(static signature => signature, StringComparer.Ordinal)
            .ToArray();
        var added = candidateMethods.Keys.Except(baselineMethods.Keys, StringComparer.Ordinal)
            .OrderBy(static signature => signature, StringComparer.Ordinal)
            .ToArray();
        var removed = baselineMethods.Keys.Except(candidateMethods.Keys, StringComparer.Ordinal)
            .OrderBy(static signature => signature, StringComparer.Ordinal)
            .ToArray();

        var pairs = matchedSignatures
            .Select(signature => new ApiPair(baselineMethods[signature], candidateMethods[signature]))
            .ToArray();
        var supportedPairs = pairs
            .Where(static pair => pair.Baseline.IsSupported && pair.Candidate.IsSupported)
            .ToArray();
        var unsupportedApiCount = pairs.Length - supportedPairs.Length;
        var unsupportedCount = 0;
        var generated = 0;
        var stable = 0;
        var inconclusive = 0;
        var executionFailures = 0;
        var divergences = new List<DivergenceRecord>();
        var comparisonMilliseconds = new List<double>();
        var minimizationMilliseconds = new List<double>();
        var diagnostics = baseline.LoadErrors.Concat(candidate.LoadErrors).ToList();

        for (var pairIndex = 0; pairIndex < supportedPairs.Length && generated < options.ScenarioBudget; pairIndex++)
        {
            var pair = supportedPairs[pairIndex];
            var remainingApis = supportedPairs.Length - pairIndex;
            var remainingBudget = options.ScenarioBudget - generated;
            var scenarioCount = Math.Max(1, remainingBudget / remainingApis);
            scenarioCount = Math.Min(scenarioCount, remainingBudget);
            var scenarios = ScenarioGenerator.Generate(pair.Baseline, scenarioCount, options.Seed);
            foreach (var scenario in scenarios)
            {
                generated++;
                var stopwatch = Stopwatch.StartNew();
                var outcome = await CompareScenarioAsync(pair, scenario, options, cancellationToken).ConfigureAwait(false);
                stopwatch.Stop();
                comparisonMilliseconds.Add(stopwatch.Elapsed.TotalMilliseconds);
                switch (outcome.Kind)
                {
                    case ProbeResultKind.EquivalentWithinTestedDomain:
                        stable++;
                        break;
                    case ProbeResultKind.BehavioralDivergence:
                        stable++;
                        var minimized = await WitnessMinimizer.MinimizeAsync(
                            scenario,
                            candidateScenario => IsStableDivergenceAsync(pair, candidateScenario, options, cancellationToken),
                            options,
                            cancellationToken).ConfigureAwait(false);
                        minimizationMilliseconds.Add(minimized.Elapsed.TotalMilliseconds);
                        divergences.Add(new DivergenceRecord(
                            pair.Baseline.Signature,
                            scenario,
                            outcome.Baseline!,
                            outcome.Candidate!,
                            minimized.Scenario,
                            minimized.Elapsed,
                            minimized.Attempts));
                        break;
                    case ProbeResultKind.NondeterministicInconclusive:
                        inconclusive++;
                        break;
                    case ProbeResultKind.UnsupportedApi:
                        unsupportedCount++;
                        break;
                    case ProbeResultKind.ExecutionFailure:
                        executionFailures++;
                        diagnostics.Add($"{pair.Baseline.Signature}: {outcome.FailureCategory}");
                        break;
                }

                if (cancellationToken.IsCancellationRequested)
                {
                    break;
                }
            }
        }

        var unsupportedOrInconclusive = unsupportedCount + inconclusive;
        var rate = generated == 0
            ? unsupportedApiCount > 0 ? 1d : 0d
            : (double)unsupportedOrInconclusive / generated;
        return new ProbeReport
        {
            Seed = options.Seed,
            ScenarioBudget = options.ScenarioBudget,
            ConfirmationRuns = options.ConfirmationRuns,
            MatchedCallableApis = matchedSignatures.Length,
            SupportedApisExercised = supportedPairs.Length,
            UnsupportedApiCount = unsupportedApiCount,
            SupportedApiPercentage = matchedSignatures.Length == 0
                ? 0d
                : (double)supportedPairs.Length / matchedSignatures.Length * 100d,
            DiscoveredBaselineApis = baseline.CallableMembers.Count,
            DiscoveredCandidateApis = candidate.CallableMembers.Count,
            AddedApis = added.Length,
            RemovedApis = removed.Length,
            GeneratedScenarios = generated,
            StableScenarios = stable,
            DivergenceCount = divergences.Count,
            InconclusiveCount = inconclusive,
            UnsupportedCount = unsupportedCount,
            ExecutionFailureCount = executionFailures,
            UnsupportedOrInconclusiveRate = rate,
            MedianComparisonMilliseconds = Median(comparisonMilliseconds),
            MedianMinimizationMilliseconds = Median(minimizationMilliseconds),
            MinimizedWitnessSize = divergences.Count == 0 ? 0 : divergences.Min(static item => item.MinimizedInput.Size),
            Trustworthy = executionFailures == 0 && !cancellationToken.IsCancellationRequested,
            AddedApiSignatures = added,
            RemovedApiSignatures = removed,
            Divergences = divergences,
            Diagnostics = diagnostics
        };
    }

    private async Task<ScenarioOutcome> CompareScenarioAsync(
        ApiPair pair,
        GeneratedScenario scenario,
        ProbeOptions options,
        CancellationToken cancellationToken)
    {
        var baselineObservations = await RunConfirmationsAsync(
            baselineRunner,
            pair.Baseline.AssemblyPath,
            pair.Baseline.Signature,
            scenario,
            options,
            cancellationToken).ConfigureAwait(false);
        if (!baselineObservations.Success)
        {
            return ScenarioOutcome.Failure(baselineObservations.FailureCategory!);
        }

        var candidateObservations = await RunConfirmationsAsync(
            candidateRunner,
            pair.Candidate.AssemblyPath,
            pair.Candidate.Signature,
            scenario,
            options,
            cancellationToken).ConfigureAwait(false);
        if (!candidateObservations.Success)
        {
            return ScenarioOutcome.Failure(candidateObservations.FailureCategory!);
        }

        if (!baselineObservations.Stable || !candidateObservations.Stable)
        {
            return ScenarioOutcome.Inconclusive();
        }

        var baselineObservation = baselineObservations.Observation!;
        var candidateObservation = candidateObservations.Observation!;
        if (!baselineObservation.IsRepresentable || !candidateObservation.IsRepresentable)
        {
            return ScenarioOutcome.Unsupported();
        }

        return ObservationComparer.AreEqual(baselineObservation, candidateObservation)
            ? ScenarioOutcome.Equivalent(baselineObservation, candidateObservation)
            : ScenarioOutcome.Divergence(baselineObservation, candidateObservation);
    }

    private async Task<bool> IsStableDivergenceAsync(
        ApiPair pair,
        GeneratedScenario scenario,
        ProbeOptions options,
        CancellationToken cancellationToken)
    {
        var outcome = await CompareScenarioAsync(pair, scenario, options, cancellationToken).ConfigureAwait(false);
        return outcome.Kind == ProbeResultKind.BehavioralDivergence;
    }

    private static async Task<ConfirmationResult> RunConfirmationsAsync(
        WorkerRunner runner,
        string assemblyPath,
        string signature,
        GeneratedScenario scenario,
        ProbeOptions options,
        CancellationToken cancellationToken)
    {
        var observations = new List<Observation>(options.ConfirmationRuns);
        for (var run = 0; run < options.ConfirmationRuns; run++)
        {
            var response = await runner.ExecuteAsync(
                assemblyPath,
                signature,
                scenario,
                options,
                cancellationToken).ConfigureAwait(false);
            if (!response.Success || response.Observation is null)
            {
                return ConfirmationResult.Failure(response.FailureCategory ?? "worker-failure");
            }

            observations.Add(response.Observation);
        }

        var first = observations[0];
        return new ConfirmationResult(
            Success: true,
            Stable: observations.All(observation => ObservationComparer.AreEqual(first, observation)),
            Observation: first,
            FailureCategory: null);
    }

    private static double Median(IReadOnlyList<double> values)
    {
        if (values.Count == 0)
        {
            return 0;
        }

        var ordered = values.OrderBy(static value => value).ToArray();
        return ordered[ordered.Length / 2];
    }

    private sealed record ConfirmationResult(
        bool Success,
        bool Stable,
        Observation? Observation,
        string? FailureCategory)
    {
        public static ConfirmationResult Failure(string category) =>
            new(false, false, null, category);
    }

    private sealed record ScenarioOutcome(
        ProbeResultKind Kind,
        Observation? Baseline,
        Observation? Candidate,
        string? FailureCategory)
    {
        public static ScenarioOutcome Equivalent(Observation baseline, Observation candidate) =>
            new(ProbeResultKind.EquivalentWithinTestedDomain, baseline, candidate, null);

        public static ScenarioOutcome Divergence(Observation baseline, Observation candidate) =>
            new(ProbeResultKind.BehavioralDivergence, baseline, candidate, null);

        public static ScenarioOutcome Inconclusive() =>
            new(ProbeResultKind.NondeterministicInconclusive, null, null, null);

        public static ScenarioOutcome Unsupported() =>
            new(ProbeResultKind.UnsupportedApi, null, null, null);

        public static ScenarioOutcome Failure(string category) =>
            new(ProbeResultKind.ExecutionFailure, null, null, category);
    }
}
