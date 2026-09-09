using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
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
    private static int mutableState;

    public static int Add(int value) => value + 1;

    public static int Add(string value) => value.Length;

    public static T Identity<T>(T value) => value;

    public static string FromStream(Stream value) => value.Length.ToString(System.Globalization.CultureInfo.InvariantCulture);

    public static string Normalize(string? value) => value?.Trim() ?? "default";

    public static int MutableStaticState() => ++mutableState;

    public static int CallsMutableStaticState() => MutableStaticState();

    public static int ReadsEnvironment() => Environment.GetEnvironmentVariable("BEHAVIOR_ORACLE_TEST")?.Length ?? 0;

    public static int ReadsFile() => File.Exists("fixture.txt") ? 1 : 0;

    public static DateTime Today() => DateTime.Today;

    public static DateTimeOffset UtcNow() => DateTimeOffset.UtcNow;

    public static int RandomValue() => Random.Shared.Next();

    public static string CurrentCultureName() => System.Globalization.CultureInfo.CurrentCulture.Name;

    public static int ExitWithoutResponse()
    {
        Environment.Exit(17);
        return 0;
    }

    public static int WriteLargeStdout()
    {
        Console.Out.Write(new string('o', 70_000));
        return 1;
    }

    public static int WriteLargeStderr()
    {
        Console.Error.Write(new string('e', 70_000));
        return 1;
    }

    public static int SpawnDescendantAndWait()
    {
        var marker = Path.Combine(Path.GetTempPath(), $"behavior-oracle-descendant-{Environment.ProcessId}-{Guid.NewGuid():N}.pid");
        var startInfo = OperatingSystem.IsWindows()
            ? new ProcessStartInfo("cmd.exe", "/c ping 127.0.0.1 -n 30 > NUL")
            : new ProcessStartInfo("/bin/sh", "-c 'sleep 30'");
        startInfo.UseShellExecute = false;
        using var child = Process.Start(startInfo) ?? throw new InvalidOperationException("Could not start descendant.");
        File.WriteAllText(marker, child.Id.ToString(System.Globalization.CultureInfo.InvariantCulture));
        try
        {
            child.WaitForExit();
            return child.ExitCode;
        }
        finally
        {
            File.Delete(marker);
        }
    }

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

    [Fact]
    public void Pure_string_normalization_is_not_rejected_by_method_support_analysis()
    {
        var method = typeof(ProbeFixture).GetMethod(nameof(ProbeFixture.Normalize))!;

        Assert.Null(TypeSupport.UnsupportedReason(method));
    }

    [Fact]
    public void Hidden_external_and_mutable_static_state_is_skipped()
    {
        var surface = ApiSurfaceDiscoverer.DiscoverFiles([typeof(ProbeFixture).Assembly.Location]);
        var names = new[] { nameof(ProbeFixture.MutableStaticState), nameof(ProbeFixture.CallsMutableStaticState), nameof(ProbeFixture.ReadsEnvironment), nameof(ProbeFixture.ReadsFile) };
        var descriptors = surface.CallableMembers.Where(member => names.Contains(member.MethodName, StringComparer.Ordinal)).ToArray();

        Assert.Equal(names.Length, descriptors.Length);
        Assert.All(descriptors, descriptor => Assert.False(descriptor.IsSupported));
    }

    [Fact]
    public void Clock_reads_are_skipped_instead_of_claimed_supported()
    {
        var method = typeof(ProbeFixture).GetMethod(nameof(ProbeFixture.Today))!;

        Assert.NotNull(TypeSupport.UnsupportedReason(method));
    }

    [Fact]
    public void Other_hidden_state_reads_are_skipped_instead_of_claimed_supported()
    {
        var names = new[] { nameof(ProbeFixture.UtcNow), nameof(ProbeFixture.RandomValue), nameof(ProbeFixture.CurrentCultureName) };
        var methods = names.Select(name => typeof(ProbeFixture).GetMethod(name)!).ToArray();

        Assert.All(methods, method => Assert.NotNull(TypeSupport.UnsupportedReason(method)));
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
    public void Different_seeds_change_the_generated_scalar_corpus()
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

        var first = ScenarioGenerator.Generate(descriptor, 30, 1001);
        var second = ScenarioGenerator.Generate(descriptor, 30, 2002);

        Assert.NotEqual(ObservationCodec.Serialize(first), ObservationCodec.Serialize(second));
        Assert.True(first.Skip(3).Zip(second.Skip(3)).Count(pair =>
            !string.Equals(ObservationCodec.Serialize(pair.First), ObservationCodec.Serialize(pair.Second), StringComparison.Ordinal)) > 10);
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
    private static string[] WorkerDirectories() =>
        Directory.Exists(Path.Combine(Path.GetTempPath(), "behavior-oracle"))
            ? Directory.GetDirectories(Path.Combine(Path.GetTempPath(), "behavior-oracle"))
            : [];

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

    [Fact]
    public async Task Worker_crash_is_a_failure_and_temp_directory_is_cleaned()
    {
        var method = typeof(ProbeFixture).GetMethod(nameof(ProbeFixture.ExitWithoutResponse))!;
        var before = WorkerDirectories();
        var response = await new WorkerRunner().ExecuteAsync(
            typeof(ProbeFixture).Assembly.Location,
            TypeNames.Method(method),
            new GeneratedScenario(0, 1, []),
            new ProbeOptions(WorkerTimeoutMilliseconds: 5000));

        Assert.False(response.Success);
        Assert.Equal("worker-crash", response.FailureCategory);
        Assert.Equal(before, WorkerDirectories());
    }

    [Fact]
    public async Task Worker_cancellation_is_a_failure_and_temp_directory_is_cleaned()
    {
        var method = typeof(ProbeFixture).GetMethod(nameof(ProbeFixture.Sleep))!;
        using var cancellation = new CancellationTokenSource(100);
        var before = WorkerDirectories();
        var response = await new WorkerRunner().ExecuteAsync(
            typeof(ProbeFixture).Assembly.Location,
            TypeNames.Method(method),
            new GeneratedScenario(0, 1, [new GeneratedValue { Kind = GeneratedValueKind.Integer, TypeName = "System.Int32", IntegerValue = 5000 }]),
            new ProbeOptions(WorkerTimeoutMilliseconds: 5000),
            cancellation.Token);

        Assert.False(response.Success);
        Assert.Equal("cancelled", response.FailureCategory);
        Assert.Equal(before, WorkerDirectories());
    }

    [Fact]
    public async Task Worker_enforces_stdout_and_stderr_limits()
    {
        var options = new ProbeOptions(MaxStdoutBytes: 1024, MaxStderrBytes: 1024, WorkerTimeoutMilliseconds: 5000);
        var stdoutMethod = typeof(ProbeFixture).GetMethod(nameof(ProbeFixture.WriteLargeStdout))!;
        var stderrMethod = typeof(ProbeFixture).GetMethod(nameof(ProbeFixture.WriteLargeStderr))!;

        var stdout = await new WorkerRunner().ExecuteAsync(typeof(ProbeFixture).Assembly.Location, TypeNames.Method(stdoutMethod), new GeneratedScenario(0, 1, []), options);
        var stderr = await new WorkerRunner().ExecuteAsync(typeof(ProbeFixture).Assembly.Location, TypeNames.Method(stderrMethod), new GeneratedScenario(0, 1, []), options);

        Assert.False(stdout.Success);
        Assert.Equal("stdout-limit", stdout.FailureCategory);
        Assert.False(stderr.Success);
        Assert.Equal("stderr-limit", stderr.FailureCategory);
    }

    [Fact]
    public async Task Worker_timeout_terminates_descendant_processes()
    {
        var method = typeof(ProbeFixture).GetMethod(nameof(ProbeFixture.SpawnDescendantAndWait))!;
        var before = Directory.GetFiles(Path.GetTempPath(), "behavior-oracle-descendant-*.pid");
        var response = await new WorkerRunner().ExecuteAsync(
            typeof(ProbeFixture).Assembly.Location,
            TypeNames.Method(method),
            new GeneratedScenario(0, 1, []),
            new ProbeOptions(WorkerTimeoutMilliseconds: 500));

        var markers = Directory.GetFiles(Path.GetTempPath(), "behavior-oracle-descendant-*.pid")
            .Except(before, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        try
        {
            Assert.False(response.Success);
            Assert.Equal("timeout", response.FailureCategory);
            Assert.NotEmpty(markers);
            foreach (var marker in markers)
            {
                var pid = int.Parse(File.ReadAllText(marker), System.Globalization.CultureInfo.InvariantCulture);
                Assert.True(SpinWait.SpinUntil(() => !IsRunning(pid), TimeSpan.FromSeconds(2)), $"Descendant {pid} is still running.");
            }
        }
        finally
        {
            foreach (var marker in markers)
            {
                File.Delete(marker);
            }
        }
    }

    private static bool IsRunning(int processId)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }
}
