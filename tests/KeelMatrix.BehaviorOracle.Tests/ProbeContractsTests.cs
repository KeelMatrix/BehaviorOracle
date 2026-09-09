using System.Collections;
using System.Collections.Generic;
using System.Reflection;
using System.Threading;
using Xunit;

namespace KeelMatrix.BehaviorOracle.Tests;

public sealed class SurfaceFixture
{
    public SurfaceFixture()
    {
    }

    public int Offset { get; set; }

    public int Increment(int value) => value + Offset;
}

public sealed class NestedValue
{
    public int Amount { get; set; }
}

public sealed class GraphFixture
{
    public NestedValue? Nested { get; set; }
    public string? Name { get; set; }
}

public static class ProbeFixture
{
    public static int Add(int value) => value + 1;

    public static int Add(string value) => value.Length;

    public static T Identity<T>(T value) => value;

    public static string FromStream(Stream value) => value.Length.ToString(System.Globalization.CultureInfo.InvariantCulture);

    public static Task<int> Async(int value) => Task.FromResult(value + 1);

    public static int Sleep(int milliseconds)
    {
        Thread.Sleep(milliseconds);
        return milliseconds;
    }
}

public sealed class RecursiveSequence : IEnumerable<RecursiveSequence>
{
    IEnumerator<RecursiveSequence> IEnumerable<RecursiveSequence>.GetEnumerator() => throw new NotSupportedException();

    IEnumerator IEnumerable.GetEnumerator() => throw new NotSupportedException();
}

public sealed class SurfaceDiscoveryTests
{
    [Fact]
    public void Discovers_overloads_instances_constructors_async_and_unsupported_signatures()
    {
        var surface = ApiSurfaceDiscoverer.DiscoverFiles([typeof(ProbeFixture).Assembly.Location]);
        var fixtureMembers = surface.Members
            .Where(member => member.DeclaringTypeName.Contains(nameof(ProbeFixture), StringComparison.Ordinal))
            .ToArray();
        var signatures = fixtureMembers.Select(static member => member.Signature).ToArray();

        Assert.Equal(2, signatures.Count(signature => signature.Contains("::Add(", StringComparison.Ordinal)));
        Assert.Contains(signatures, signature => signature.Contains("::Async(System.Int32)->System.Threading.Tasks.Task<System.Int32>", StringComparison.Ordinal));
        Assert.Contains(fixtureMembers, member =>
            member.MemberName == "FromStream" &&
            member.UnsupportedReason is not null);
        Assert.Contains(fixtureMembers, member =>
            member.MemberName == "Identity" &&
            member.UnsupportedReason is not null);

        var constructible = surface.Members
            .Where(member => member.DeclaringTypeName.Contains(nameof(SurfaceFixture), StringComparison.Ordinal))
            .ToArray();
        Assert.Contains(constructible, member => member.IsConstructor);
        Assert.Contains(constructible, member => member.MemberName == "Increment");
    }
}

public sealed class ScenarioGenerationTests
{
    [Fact]
    public void Generation_is_seeded_and_bounded()
    {
        var method = typeof(ProbeFixture).GetMethod(nameof(ProbeFixture.Add), [typeof(int)])!;
        var descriptor = new ApiDescriptor(
            TypeNames.Method(method),
            TypeNames.For(typeof(ProbeFixture)),
            method.Name,
            typeof(ProbeFixture).Assembly.Location,
            IsStatic: true,
            IsConstructor: false,
            method.GetParameters().Select(parameter => TypeNames.For(parameter.ParameterType)).ToArray(),
            TypeNames.For(method.ReturnType),
            UnsupportedReason: null);

        var first = ScenarioGenerator.Generate(descriptor, 30, 9876);
        var second = ScenarioGenerator.Generate(descriptor, 30, 9876);

        Assert.Equal(ObservationCodec.Serialize(first), ObservationCodec.Serialize(second));
        Assert.Equal(30, first.Count);
        Assert.All(first, scenario => Assert.InRange(scenario.Size, 1, 1000));
        Assert.Contains(first, scenario => scenario.Arguments[0].IntegerValue == 100);
    }

    [Fact]
    public void Object_graph_generation_stays_finite()
    {
        var value = GeneratedValueFactory.Create(
            typeof(GraphFixture),
            new DeterministicRandom(4),
            depth: 0,
            maxDepth: 3,
            maxCollectionItems: 4,
            variant: 1);

        Assert.Equal(GeneratedValueKind.Object, value.Kind);
        Assert.NotNull(value.Members);
        Assert.True(value.Members!.Count <= 2);
        Assert.True(new GeneratedScenario(0, 4, [value]).Size < 100);
    }

    [Fact]
    public void Recursive_collection_shape_is_rejected_within_budget()
    {
        var reason = TypeSupport.UnsupportedReason(typeof(RecursiveSequence));

        Assert.NotNull(reason);
        Assert.Contains("recursion", reason, StringComparison.OrdinalIgnoreCase);
    }
}

public sealed class ObservationTests
{
    private static readonly int[] Increasing = [1, 2, 3];
    private static readonly int[] Decreasing = [3, 2, 1];

    [Fact]
    public void Collection_order_is_observable_but_exception_messages_are_not_part_of_the_contract()
    {
        var options = new ProbeOptions();
        var firstValue = ValueObserver.Capture(Increasing, typeof(int[]), new ObservationLimits(options));
        var secondValue = ValueObserver.Capture(Decreasing, typeof(int[]), new ObservationLimits(options));
        var first = new Observation("returned", firstValue, null, Array.Empty<ObservedValue>(), Array.Empty<ObservedValue>(), null, true);
        var second = new Observation("returned", secondValue, null, Array.Empty<ObservedValue>(), Array.Empty<ObservedValue>(), null, true);
        Assert.False(ObservationComparer.AreEqual(first, second));

        var exceptionA = new Observation("threw", null, typeof(InvalidOperationException).FullName, Array.Empty<ObservedValue>(), Array.Empty<ObservedValue>(), null, true);
        var exceptionB = new Observation("threw", null, typeof(InvalidOperationException).FullName, Array.Empty<ObservedValue>(), Array.Empty<ObservedValue>(), null, true);
        Assert.True(ObservationComparer.AreEqual(exceptionA, exceptionB));
    }

    [Fact]
    public void Unrepresentable_values_are_not_equivalent()
    {
        var unrepresentable = new ObservedValue("unrepresentable", Scalar: "depth");
        var left = new Observation("returned", unrepresentable, null, Array.Empty<ObservedValue>(), Array.Empty<ObservedValue>(), null, false);
        var right = new Observation("returned", unrepresentable, null, Array.Empty<ObservedValue>(), Array.Empty<ObservedValue>(), null, false);

        Assert.False(ObservationComparer.AreEqual(left, right));
    }
}

public sealed class MinimizationTests
{
    [Fact]
    public async Task Shrinking_is_bounded_and_preserves_the_witness_predicate()
    {
        var original = new GeneratedScenario(
            0,
            42,
            [new GeneratedValue
            {
                Kind = GeneratedValueKind.String,
                TypeName = "System.String",
                TextValue = "abcdef"
            }]);
        var options = new ProbeOptions(MinimizationMaxAttempts: 5, MinimizationTimeoutMilliseconds: 1000);

        var result = await WitnessMinimizer.MinimizeAsync(
            original,
            scenario => Task.FromResult(scenario.Arguments[0].TextValue!.Length <= 2),
            options);

        Assert.True(result.Attempts <= 5);
        Assert.InRange(result.Scenario.Arguments[0].TextValue!.Length, 0, 2);
    }
}

public sealed class WorkerProcessTests
{
    [Fact]
    public async Task Worker_executes_a_method_in_a_child_process()
    {
        var method = typeof(ProbeFixture).GetMethod(nameof(ProbeFixture.Add), [typeof(int)])!;
        var scenario = new GeneratedScenario(
            0,
            1,
            [new GeneratedValue { Kind = GeneratedValueKind.Integer, TypeName = "System.Int32", IntegerValue = 2 }]);
        var response = await new WorkerRunner().ExecuteAsync(
            typeof(ProbeFixture).Assembly.Location,
            TypeNames.Method(method),
            scenario,
            new ProbeOptions(WorkerTimeoutMilliseconds: 5000));

        Assert.True(response.Success, response.FailureCategory);
        Assert.Equal("3", response.Observation!.ReturnValue!.Scalar);
    }

    [Fact]
    public async Task Worker_timeout_is_a_failure_not_an_observation()
    {
        var method = typeof(ProbeFixture).GetMethod(nameof(ProbeFixture.Sleep))!;
        var scenario = new GeneratedScenario(
            0,
            1,
            [new GeneratedValue { Kind = GeneratedValueKind.Integer, TypeName = "System.Int32", IntegerValue = 500 }]);
        var response = await new WorkerRunner().ExecuteAsync(
            typeof(ProbeFixture).Assembly.Location,
            TypeNames.Method(method),
            scenario,
            new ProbeOptions(WorkerTimeoutMilliseconds: 100));

        Assert.False(response.Success);
        Assert.Equal("timeout", response.FailureCategory);
        Assert.Null(response.Observation);
    }
}
