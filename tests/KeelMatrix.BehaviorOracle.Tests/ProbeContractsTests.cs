using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Threading;
using BehaviorOracle.NarrowIntegerSurface;
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

    public static string NewGuid() => Guid.NewGuid().ToString("D");

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

    public static int WriteSustainedStdout()
    {
        var chunk = new string('s', 4096);
        while (true)
        {
            Console.Out.Write(chunk);
            Console.Out.Flush();
        }
    }

    public static int SpawnDescendantAndWait()
    {
        var marker = Path.Combine(Path.GetTempPath(), $"behavior-oracle-descendant-{Environment.ProcessId}-{Guid.NewGuid():N}.pid");
        var startInfo = OperatingSystem.IsWindows()
            ? new ProcessStartInfo("cmd.exe")
            : new ProcessStartInfo("/bin/sh");
        startInfo.ArgumentList.Add(OperatingSystem.IsWindows() ? "/c" : "-c");
        startInfo.ArgumentList.Add(OperatingSystem.IsWindows() ? "ping 127.0.0.1 -n 30 > NUL" : "sleep 30");
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
            if (child.HasExited && child.ExitCode == 0)
            {
                File.Delete(marker);
            }
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

    [Fact]
    public void Guid_generation_is_skipped_instead_of_claimed_supported()
    {
        var method = typeof(ProbeFixture).GetMethod(nameof(ProbeFixture.NewGuid))!;

        var reason = TypeSupport.UnsupportedReason(method);

        Assert.NotNull(reason);
        Assert.Contains("random", reason, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Missing_dependency_keeps_affected_method_visible_as_skipped()
    {
        const string signature = "BehaviorOracleCorpus.SemanticChanges::ReadReferencedEnvironment()->System.Int32";
        var sourceAssembly = Path.Combine(AppContext.BaseDirectory, "Fixtures", "BehaviorOracleCorpus.Baseline.dll");
        var root = Directory.CreateTempSubdirectory("behavior-oracle-missing-dependency-");
        var baseline = Directory.CreateDirectory(Path.Combine(root.FullName, "baseline"));
        var candidate = Directory.CreateDirectory(Path.Combine(root.FullName, "candidate"));
        var assemblyName = Path.GetFileName(sourceAssembly);
        File.Copy(sourceAssembly, Path.Combine(baseline.FullName, assemblyName));
        File.Copy(sourceAssembly, Path.Combine(candidate.FullName, assemblyName));
        var dependencyFileName = Path.GetFileNameWithoutExtension(assemblyName) + ".deps.json";
        File.Copy(
            Path.Combine(AppContext.BaseDirectory, "Fixtures", "MissingDependency.deps.json"),
            Path.Combine(baseline.FullName, dependencyFileName));
        File.Copy(
            Path.Combine(AppContext.BaseDirectory, "Fixtures", "MissingDependency.deps.json"),
            Path.Combine(candidate.FullName, dependencyFileName));

        try
        {
            var surface = new ApiSurfaceDiscoverer().DiscoverDirectory(baseline.FullName);
            var descriptor = Assert.Single(surface.CallableMembers.Where(member => member.Signature == signature));
            Assert.False(descriptor.IsSupported);
            Assert.Contains("unresolved call target", descriptor.UnsupportedReason, StringComparison.OrdinalIgnoreCase);

            var report = await new ComparisonEngine().CompareAsync(
                baseline.FullName,
                candidate.FullName,
                new ProbeOptions(ScenarioBudget: 1, ConfirmationRuns: 2));

            var result = Assert.Single(report.ScenarioResults.Where(result => result.ApiSignature == signature));
            Assert.Equal("SKIPPED", result.Classification);
            Assert.Equal(
                report.UnsupportedApiCount,
                report.ScenarioResults.Count(result => result.Classification == "SKIPPED"));
            Assert.Contains(report.Diagnostics, diagnostic =>
                diagnostic.Contains(signature, StringComparison.Ordinal) &&
                diagnostic.Contains("unresolved call target", StringComparison.OrdinalIgnoreCase));
        }
        finally
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
            root.Delete(recursive: true);
        }
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

    public static IEnumerable<object[]> Supported_integer_types()
    {
        yield return [nameof(NarrowIntegerSurface.AcceptByte), typeof(byte)];
        yield return [nameof(NarrowIntegerSurface.AcceptSByte), typeof(sbyte)];
        yield return [nameof(NarrowIntegerSurface.AcceptShort), typeof(short)];
        yield return [nameof(NarrowIntegerSurface.AcceptUShort), typeof(ushort)];
        yield return [nameof(NarrowIntegerSurface.AcceptInt), typeof(int)];
        yield return [nameof(NarrowIntegerSurface.AcceptUInt), typeof(uint)];
        yield return [nameof(NarrowIntegerSurface.AcceptLong), typeof(long)];
        yield return [nameof(NarrowIntegerSurface.AcceptULong), typeof(ulong)];
        yield return [nameof(NarrowIntegerSurface.AcceptNInt), typeof(nint)];
        yield return [nameof(NarrowIntegerSurface.AcceptNUInt), typeof(nuint)];
    }

    [Theory]
    [MemberData(nameof(Supported_integer_types))]
    public void Every_supported_integer_width_generates_values_that_can_be_instantiated(string methodName, Type parameterType)
    {
        var method = typeof(NarrowIntegerSurface).GetMethod(methodName, [parameterType])!;
        var descriptor = new ApiDescriptor(
            TypeNames.Method(method),
            TypeNames.For(typeof(NarrowIntegerSurface)),
            method.Name,
            typeof(NarrowIntegerSurface).Assembly.Location,
            IsStatic: true,
            IsConstructor: false,
            method.GetParameters().Select(parameter => TypeNames.For(parameter.ParameterType)).ToArray(),
            TypeNames.For(method.ReturnType),
            UnsupportedReason: null);

        var scenarios = ScenarioGenerator.Generate(descriptor, 64, 9876);

        Assert.NotEmpty(scenarios);
        foreach (var scenario in scenarios)
        {
            var instance = ValueInstantiator.Create(scenario.Arguments[0], parameterType);
            Assert.NotNull(instance);
            Assert.Equal(parameterType, instance.GetType());
        }
    }

    [Fact]
    public void Integer_instantiation_rejects_values_outside_the_expected_range()
    {
        var exception = Assert.Throws<ValueInstantiationException>(() => ValueInstantiator.Create(
            new GeneratedValue
            {
                Kind = GeneratedValueKind.Integer,
                TypeName = TypeNames.For(typeof(byte)),
                IntegerValue = -1
            },
            typeof(byte)));

        Assert.Contains("outside the range", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Read_only_custom_enumerables_are_not_admitted_as_collection_shapes()
    {
        Assert.False(TypeSupport.TryGetCollectionShape(typeof(ReadOnlyEnumerable), out _, out _, out _));
        Assert.Contains("construction", TypeSupport.UnsupportedReason(typeof(ReadOnlyEnumerable)), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Public_addable_custom_enumerables_remain_supported()
    {
        Assert.True(TypeSupport.TryGetCollectionShape(typeof(AddableEnumerable), out var elementType, out _, out _));
        Assert.Equal(typeof(int), elementType);

        var value = GeneratedValueFactory.Create(
            typeof(AddableEnumerable),
            new DeterministicRandom(4),
            depth: 0,
            maxDepth: 3,
            maxCollectionItems: 4,
            variant: 3);

        var instance = ValueInstantiator.Create(value, typeof(AddableEnumerable));

        Assert.IsType<AddableEnumerable>(instance);
    }

    [Fact]
    public void Interface_typed_collections_use_assignable_public_concrete_types()
    {
        foreach (var type in new[] { typeof(IEnumerable<byte>), typeof(ICollection<byte>), typeof(IList<byte>), typeof(IReadOnlyCollection<byte>), typeof(IReadOnlyList<byte>), typeof(ISet<byte>) })
        {
            var value = GeneratedValueFactory.Create(
                type,
                new DeterministicRandom(7),
                depth: 0,
                maxDepth: 3,
                maxCollectionItems: 4,
                variant: 3);

            var instance = ValueInstantiator.Create(value, type);

            Assert.NotNull(instance);
            Assert.True(type.IsInstanceOfType(instance), $"{instance.GetType()} is not assignable to {type}.");
        }
    }

    [Fact]
    public void Dictionary_generation_avoids_duplicate_keys()
    {
        var value = GeneratedValueFactory.Create(
            typeof(Dictionary<bool, int>),
            new DeterministicRandom(8),
            depth: 0,
            maxDepth: 3,
            maxCollectionItems: 4,
            variant: 3);

        var instance = Assert.IsType<Dictionary<bool, int>>(ValueInstantiator.Create(value, typeof(Dictionary<bool, int>)));
        Assert.Equal(instance.Keys.Distinct().Count(), instance.Count);
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
    public async Task Worker_terminates_sustained_output_at_the_first_bound_breach()
    {
        var options = new ProbeOptions(MaxStdoutBytes: 1024, MaxStderrBytes: 1024, WorkerTimeoutMilliseconds: 5000);
        var method = typeof(ProbeFixture).GetMethod(nameof(ProbeFixture.WriteSustainedStdout))!;
        var before = WorkerDirectories();
        var stopwatch = Stopwatch.StartNew();

        var response = await new WorkerRunner().ExecuteAsync(
            typeof(ProbeFixture).Assembly.Location,
            TypeNames.Method(method),
            new GeneratedScenario(0, 1, []),
            options);

        stopwatch.Stop();
        Assert.False(response.Success);
        Assert.Equal("stdout-limit", response.FailureCategory);
        Assert.InRange(stopwatch.Elapsed, TimeSpan.Zero, TimeSpan.FromSeconds(3));
        Assert.InRange(response.OutputBytes ?? 0, 1, options.MaxStdoutBytes + 4096);
        Assert.Equal(before, WorkerDirectories());
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
