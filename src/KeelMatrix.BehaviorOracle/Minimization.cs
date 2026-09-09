using System.Globalization;

namespace KeelMatrix.BehaviorOracle;

internal sealed record MinimizationResult(
    GeneratedScenario Scenario,
    TimeSpan Elapsed,
    int Attempts);

internal sealed class WitnessMinimizer
{
    public static async Task<MinimizationResult> MinimizeAsync(
        GeneratedScenario original,
        Func<GeneratedScenario, Task<bool>> StillDivergesAsync,
        ProbeOptions options,
        CancellationToken cancellationToken = default)
    {
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        var current = original;
        var attempts = 0;
        var changed = true;
        while (changed &&
               attempts < options.MinimizationMaxAttempts &&
               stopwatch.ElapsedMilliseconds < options.MinimizationTimeoutMilliseconds &&
               !cancellationToken.IsCancellationRequested)
        {
            changed = false;
            foreach (var candidate in Shrink(current))
            {
                if (attempts++ >= options.MinimizationMaxAttempts ||
                    stopwatch.ElapsedMilliseconds >= options.MinimizationTimeoutMilliseconds)
                {
                    break;
                }

                if (candidate.Size >= current.Size)
                {
                    continue;
                }

                if (await StillDivergesAsync(candidate).ConfigureAwait(false))
                {
                    current = candidate;
                    changed = true;
                    break;
                }
            }
        }

        stopwatch.Stop();
        return new MinimizationResult(current, stopwatch.Elapsed, attempts);
    }

    private static IEnumerable<GeneratedScenario> Shrink(GeneratedScenario scenario)
    {
        for (var argumentIndex = 0; argumentIndex < scenario.Arguments.Count; argumentIndex++)
        {
            foreach (var value in ShrinkValue(scenario.Arguments[argumentIndex]))
            {
                var arguments = scenario.Arguments.ToArray();
                arguments[argumentIndex] = value;
                yield return scenario with { Arguments = arguments };
            }
        }
    }

    private static IEnumerable<GeneratedValue> ShrinkValue(GeneratedValue value)
    {
        switch (value.Kind)
        {
            case GeneratedValueKind.Integer:
                foreach (var candidate in new[] { 0L, 1L, -1L, value.IntegerValue / 2 })
                {
                    if (candidate != value.IntegerValue)
                    {
                        yield return value with { IntegerValue = candidate };
                    }
                }

                break;
            case GeneratedValueKind.FloatingPoint:
                foreach (var candidate in new[] { 0d, 1d, -1d, value.FloatingPointValue / 2 })
                {
                    if (candidate != value.FloatingPointValue)
                    {
                        yield return value with { FloatingPointValue = candidate };
                    }
                }

                break;
            case GeneratedValueKind.Decimal:
                foreach (var candidate in new[] { "0", "1", "-1", "100" })
                {
                    if (!string.Equals(candidate, value.TextValue, StringComparison.Ordinal))
                    {
                        yield return value with { TextValue = candidate };
                    }
                }

                break;
            case GeneratedValueKind.String:
                foreach (var candidate in StringCandidates(value.TextValue))
                {
                    if (!string.Equals(candidate, value.TextValue, StringComparison.Ordinal))
                    {
                        yield return value with { TextValue = candidate };
                    }
                }

                break;
            case GeneratedValueKind.Collection:
                if (value.Items is { Count: > 0 })
                {
                    yield return value with { Items = [] };
                    for (var index = 0; index < value.Items.Count; index++)
                    {
                        var items = value.Items.Where((_, itemIndex) => itemIndex != index).ToArray();
                        yield return value with { Items = items };
                    }

                    for (var index = 0; index < value.Items.Count; index++)
                    {
                        foreach (var item in ShrinkValue(value.Items[index]))
                        {
                            var items = value.Items.ToArray();
                            items[index] = item;
                            yield return value with { Items = items };
                        }
                    }
                }

                break;
            case GeneratedValueKind.Object:
                if (value.Members is { Count: > 0 })
                {
                    foreach (var name in value.Members.Keys.OrderBy(static name => name, StringComparer.Ordinal))
                    {
                        var members = value.Members
                            .Where(pair => !string.Equals(pair.Key, name, StringComparison.Ordinal))
                            .ToDictionary(static pair => pair.Key, static pair => pair.Value, StringComparer.Ordinal);
                        yield return value with { Members = members };
                    }

                    foreach (var pair in value.Members.OrderBy(static pair => pair.Key, StringComparer.Ordinal))
                    {
                        foreach (var member in ShrinkValue(pair.Value))
                        {
                            var members = value.Members.ToDictionary(static item => item.Key, static item => item.Value, StringComparer.Ordinal);
                            members[pair.Key] = member;
                            yield return value with { Members = members };
                        }
                    }
                }

                break;
        }
    }

    private static IEnumerable<string> StringCandidates(string? value)
    {
        yield return string.Empty;
        if (!string.IsNullOrEmpty(value))
        {
            yield return value[..(value.Length / 2)];
            yield return value[..1];
        }
    }
}
