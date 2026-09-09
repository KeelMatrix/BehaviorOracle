using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Text;

namespace KeelMatrix.BehaviorOracle;

internal static class WorkerHost
{
    public static async Task<int> RunAsync()
    {
        try
        {
            CultureInfoDefaults.Apply();
            var line = await Console.In.ReadLineAsync().ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(line))
            {
                Write(new WorkerResponse(false, null, "empty-request"));
                return 2;
            }

            var request = ObservationCodec.Deserialize<WorkerRequest>(line);
            if (request is null)
            {
                Write(new WorkerResponse(false, null, "invalid-request"));
                return 2;
            }

            Directory.SetCurrentDirectory(request.WorkingDirectory);
            var response = await ExecuteAsync(request).ConfigureAwait(false);
            Write(response);
            return response.Success ? 0 : 2;
        }
        catch (Exception exception)
        {
            Write(new WorkerResponse(false, null, FailureCategory(exception)));
            return 2;
        }
    }

    private static async Task<WorkerResponse> ExecuteAsync(WorkerRequest request)
    {
        try
        {
            using var loadContext = new ProbeLoadContext(request.AssemblyPath);
            var assembly = loadContext.LoadFromAssemblyPath(Path.GetFullPath(request.AssemblyPath));
            var descriptor = new ApiDescriptor(
                request.MethodSignature,
                DeclaringTypeName(request.MethodSignature),
                MethodName(request.MethodSignature),
                request.AssemblyPath,
                IsStatic: false,
                IsConstructor: false,
                ParameterTypeNames: [],
                ReturnTypeName: "System.Void",
                UnsupportedReason: null);
            var method = ReflectionLookup.FindMethod(assembly, descriptor);
            if (method is null)
            {
                return new WorkerResponse(false, null, "method-not-found");
            }

            var parameters = method.GetParameters();
            if (parameters.Length != request.Arguments.Count)
            {
                return new WorkerResponse(false, null, "argument-count-mismatch");
            }

            var arguments = new object?[parameters.Length];
            for (var index = 0; index < parameters.Length; index++)
            {
                arguments[index] = ValueInstantiator.Create(request.Arguments[index], parameters[index].ParameterType);
            }

            var limits = new ObservationLimits(new ProbeOptions(
                MaxObservationDepth: request.MaxObservationDepth,
                MaxObservationNodes: request.MaxObservationNodes,
                MaxCollectionItems: request.MaxCollectionItems));
            var before = arguments
                .Select((argument, index) => ValueObserver.Capture(argument, parameters[index].ParameterType, limits))
                .ToArray();
            object? receiver = null;
            if (!method.IsStatic)
            {
                if (!TypeSupport.HasConstructiblePublicPath(method.DeclaringType!))
                {
                    return new WorkerResponse(false, null, "receiver-not-constructible");
                }

                receiver = Activator.CreateInstance(method.DeclaringType!);
                if (receiver is null)
                {
                    return new WorkerResponse(false, null, "receiver-construction-failed");
                }
            }

            object? returned;
            try
            {
                returned = method.Invoke(receiver, arguments);
                returned = await InvocationAwaiter.UnwrapAsync(returned, method.ReturnType).ConfigureAwait(false);
            }
            catch (Exception exception)
            {
                var actual = Unwrap(exception);
                var afterThrow = arguments
                    .Select((argument, index) => ValueObserver.Capture(argument, parameters[index].ParameterType, limits))
                    .ToArray();
                var receiverAfterThrow = receiver is null
                    ? null
                    : ValueObserver.Capture(receiver, method.DeclaringType!, limits);
                var exceptionObservation = new Observation(
                    Outcome: "threw",
                    ReturnValue: null,
                    ExceptionType: actual.GetType().FullName,
                    ArgumentsBefore: before,
                    ArgumentsAfter: afterThrow,
                    ReceiverAfter: receiverAfterThrow,
                    IsRepresentable: before.All(IsRepresentable) && afterThrow.All(IsRepresentable) &&
                        (receiverAfterThrow is null || IsRepresentable(receiverAfterThrow)));
                return new WorkerResponse(true, exceptionObservation, null);
            }

            var after = arguments
                .Select((argument, index) => ValueObserver.Capture(argument, parameters[index].ParameterType, limits))
                .ToArray();
            var receiverAfter = receiver is null
                ? null
                : ValueObserver.Capture(receiver, method.DeclaringType!, limits);
            var returnObservation = ValueObserver.Capture(returned, method.ReturnType, limits);
            var observation = new Observation(
                Outcome: "returned",
                ReturnValue: returnObservation,
                ExceptionType: null,
                ArgumentsBefore: before,
                ArgumentsAfter: after,
                ReceiverAfter: receiverAfter,
                IsRepresentable: IsRepresentable(returnObservation) &&
                    before.All(IsRepresentable) &&
                    after.All(IsRepresentable) &&
                    (receiverAfter is null || IsRepresentable(receiverAfter)));
            return new WorkerResponse(true, observation, null);
        }
        catch (ValueInstantiationException)
        {
            return new WorkerResponse(false, null, "unrepresentable-input");
        }
        catch (Exception exception)
        {
            return new WorkerResponse(false, null, FailureCategory(exception));
        }
    }

    private static bool IsRepresentable(ObservedValue value) =>
        !string.Equals(value.Kind, "unrepresentable", StringComparison.Ordinal) &&
        (value.Items is null || value.Items.All(IsRepresentable)) &&
        (value.Members is null || value.Members.Values.All(IsRepresentable));

    private static Exception Unwrap(Exception exception)
    {
        if (exception is TargetInvocationException invocation &&
            invocation.InnerException is Exception inner)
        {
            return Unwrap(inner);
        }

        return exception;
    }

    private static string FailureCategory(Exception exception) =>
        exception switch
        {
            BadImageFormatException => "invalid-assembly",
            FileNotFoundException => "assembly-dependency-not-found",
            DirectoryNotFoundException => "working-directory-not-found",
            UnauthorizedAccessException => "access-denied",
            ValueInstantiationException => "unrepresentable-input",
            _ => "worker-failure"
        };

    private static string DeclaringTypeName(string signature)
    {
        var separator = signature.IndexOf("::", StringComparison.Ordinal);
        return separator < 0 ? string.Empty : signature[..separator];
    }

    private static string MethodName(string signature)
    {
        var start = signature.IndexOf("::", StringComparison.Ordinal);
        var open = signature.IndexOf('(', start + 2);
        return start < 0 || open < 0 ? string.Empty : signature[(start + 2)..open];
    }

    private static void Write(WorkerResponse response)
    {
        Console.Out.WriteLine(ObservationCodec.Serialize(response));
        Console.Out.Flush();
    }
}

internal sealed class WorkerRunner
{
    private readonly string workerAssemblyPath;

    public WorkerRunner(string? workerAssemblyPath = null)
    {
        this.workerAssemblyPath = workerAssemblyPath ??
            typeof(WorkerHost).Assembly.Location;
    }

    public async Task<WorkerResponse> ExecuteAsync(
        string assemblyPath,
        string methodSignature,
        GeneratedScenario scenario,
        ProbeOptions options,
        CancellationToken cancellationToken = default)
    {
        var tempPath = Path.Combine(Path.GetTempPath(), "behavior-oracle", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempPath);
        using var process = new Process();
        process.StartInfo = BuildStartInfo(tempPath);
        Task<BoundedText>? standardOutputTask = null;
        Task<BoundedText>? standardErrorTask = null;
        try
        {
            if (!process.Start())
            {
                return new WorkerResponse(false, null, "process-start-failed");
            }

            var request = new WorkerRequest(
                Path.GetFullPath(assemblyPath),
                methodSignature,
                scenario.Arguments,
                tempPath,
                options.MaxObservationDepth,
                options.MaxObservationNodes,
                options.MaxCollectionItems);
            await process.StandardInput.WriteLineAsync(ObservationCodec.Serialize(request)).ConfigureAwait(false);
            await process.StandardInput.FlushAsync(CancellationToken.None).ConfigureAwait(false);
            process.StandardInput.Close();

            standardOutputTask = ReadBoundedAsync(process.StandardOutput, options.MaxStdoutBytes);
            standardErrorTask = ReadBoundedAsync(process.StandardError, options.MaxStderrBytes);
            var exitTask = process.WaitForExitAsync(CancellationToken.None);
            var timeoutTask = Task.Delay(options.WorkerTimeoutMilliseconds, cancellationToken);
            var completed = await Task.WhenAny(exitTask, timeoutTask).ConfigureAwait(false);
            if (cancellationToken.IsCancellationRequested)
            {
                TryKill(process);
                await DrainOutputAsync(standardOutputTask, standardErrorTask).ConfigureAwait(false);
                return new WorkerResponse(false, null, "cancelled");
            }

            if (completed != exitTask)
            {
                TryKill(process);
                await DrainOutputAsync(standardOutputTask, standardErrorTask).ConfigureAwait(false);
                return new WorkerResponse(false, null, "timeout");
            }

            var output = await standardOutputTask.ConfigureAwait(false);
            var error = await standardErrorTask.ConfigureAwait(false);
            if (output.ExceededLimit)
            {
                return new WorkerResponse(false, null, "stdout-limit", output.Bytes);
            }

            if (error.ExceededLimit)
            {
                return new WorkerResponse(false, null, "stderr-limit", error.Bytes);
            }

            if (process.ExitCode != 0)
            {
                return new WorkerResponse(false, null, "worker-crash", output.Bytes);
            }

            var response = ObservationCodec.Deserialize<WorkerResponse>(output.Text.Trim());
            return response ?? new WorkerResponse(false, null, "invalid-worker-response", output.Bytes);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            TryKill(process);
            return new WorkerResponse(false, null, "cancelled");
        }
        catch
        {
            TryKill(process);
            return new WorkerResponse(false, null, "worker-launch-failure");
        }
        finally
        {
            TryKill(process);
            if (standardOutputTask is not null && standardErrorTask is not null)
            {
                await DrainOutputAsync(standardOutputTask, standardErrorTask).ConfigureAwait(false);
            }

            TryDelete(tempPath);
        }
    }

    private ProcessStartInfo BuildStartInfo(string tempPath)
    {
        var host = Environment.ProcessPath ??
            throw new InvalidOperationException("The current process path is unavailable.");
        var startInfo = new ProcessStartInfo
        {
            WorkingDirectory = tempPath,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        var hostName = Path.GetFileName(host);
        if (hostName.Equals("dotnet", StringComparison.OrdinalIgnoreCase) ||
            hostName.Equals("dotnet.exe", StringComparison.OrdinalIgnoreCase) ||
            hostName.Contains("testhost", StringComparison.OrdinalIgnoreCase))
        {
            startInfo.FileName = hostName.Contains("testhost", StringComparison.OrdinalIgnoreCase)
                ? "dotnet"
                : host;
            startInfo.ArgumentList.Add(workerAssemblyPath);
            startInfo.ArgumentList.Add("--worker");
        }
        else
        {
            startInfo.FileName = host;
            startInfo.ArgumentList.Add("--worker");
        }

        return startInfo;
    }

    private static async Task<BoundedText> ReadBoundedAsync(StreamReader reader, int limit)
    {
        var buffer = new char[4096];
        var builder = new StringBuilder(Math.Min(limit, 64 * 1024));
        var bytes = 0;
        var exceeded = false;
        int read;
        while ((read = await reader.ReadAsync(buffer.AsMemory()).ConfigureAwait(false)) > 0)
        {
            bytes += Encoding.UTF8.GetByteCount(buffer, 0, read);
            if (builder.Length < limit)
            {
                var take = Math.Min(read, limit - builder.Length);
                builder.Append(buffer, 0, take);
            }

            exceeded |= bytes > limit;
        }

        return new BoundedText(builder.ToString(), bytes, exceeded);
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(1000);
            }
        }
        catch
        {
        }
    }

    private static async Task DrainOutputAsync(
        Task<BoundedText> standardOutputTask,
        Task<BoundedText> standardErrorTask)
    {
        try
        {
            await Task.WhenAll(standardOutputTask, standardErrorTask)
                .WaitAsync(TimeSpan.FromSeconds(1))
                .ConfigureAwait(false);
        }
        catch
        {
        }
    }

    private static void TryDelete(string path)
    {
        for (var attempt = 0; attempt < 4; attempt++)
        {
            try
            {
                if (!Directory.Exists(path))
                {
                    return;
                }

                Directory.Delete(path, recursive: true);
                return;
            }
            catch
            {
                Thread.Sleep(10);
            }
        }
    }

    private sealed record BoundedText(string Text, int Bytes, bool ExceededLimit);
}

internal static class InvocationAwaiter
{
    public static async Task<object?> UnwrapAsync(object? result, Type returnType)
    {
        if (result is null)
        {
            return null;
        }

        if (result is Task task)
        {
            await task.ConfigureAwait(false);
            return returnType.IsGenericType
                ? returnType.GetProperty("Result")?.GetValue(result)
                : null;
        }

        if (returnType.IsGenericType &&
            returnType.GetGenericTypeDefinition() == typeof(ValueTask<>))
        {
            var asTask = returnType.GetMethod("AsTask")!;
            var taskResult = (Task)asTask.Invoke(result, null)!;
            await taskResult.ConfigureAwait(false);
            return taskResult.GetType().GetProperty("Result")?.GetValue(taskResult);
        }

        return result;
    }
}

internal static class CultureInfoDefaults
{
    public static void Apply()
    {
        var culture = CultureInfo.InvariantCulture;
        CultureInfo.DefaultThreadCurrentCulture = culture;
        CultureInfo.DefaultThreadCurrentUICulture = culture;
        CultureInfo.CurrentCulture = culture;
        CultureInfo.CurrentUICulture = culture;
    }
}
