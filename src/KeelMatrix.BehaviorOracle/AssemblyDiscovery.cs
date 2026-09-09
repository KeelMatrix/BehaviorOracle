using System.Reflection;
using System.Runtime.Loader;

namespace KeelMatrix.BehaviorOracle;

internal sealed class ApiSurfaceDiscoverer
{
    public ApiSurface DiscoverDirectory(string directory)
    {
        GC.KeepAlive(this);
        if (!Directory.Exists(directory))
        {
            throw new DirectoryNotFoundException($"Artifact directory does not exist: {directory}");
        }

        var paths = Directory.EnumerateFiles(directory, "*.dll", SearchOption.TopDirectoryOnly)
            .Where(static path => !path.EndsWith(".resources.dll", StringComparison.OrdinalIgnoreCase))
            .OrderBy(static path => path, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (paths.Length == 0)
        {
            throw new InvalidDataException($"No assemblies were found in {directory}.");
        }

        return DiscoverFiles(paths);
    }

    public static ApiSurface DiscoverFiles(IEnumerable<string> assemblyPaths)
    {
        var members = new Dictionary<string, SurfaceMember>(StringComparer.Ordinal);
        var callable = new Dictionary<string, ApiDescriptor>(StringComparer.Ordinal);
        var errors = new List<string>();
        var firstPath = string.Empty;

        foreach (var path in assemblyPaths.OrderBy(static path => path, StringComparer.OrdinalIgnoreCase))
        {
            firstPath = firstPath.Length == 0 ? Path.GetFullPath(path) : firstPath;
            try
            {
                using var loadContext = new ProbeLoadContext(path);
                var assembly = loadContext.LoadFromAssemblyPath(Path.GetFullPath(path));
                foreach (var type in GetPublicTypes(assembly, errors))
                {
                    if (type.IsSpecialName || type.IsCompilerGenerated())
                    {
                        continue;
                    }

                    AddConstructors(type, path, members, callable);
                    AddMethods(type, path, members, callable);
                }
            }
            catch (Exception exception) when (exception is FileLoadException or BadImageFormatException or ReflectionTypeLoadException or IOException)
            {
                errors.Add($"{Path.GetFileName(path)}: assembly could not be inspected ({exception.GetType().Name}).");
            }
        }

        return new ApiSurface(
            firstPath,
            members.Values.OrderBy(static member => member.Signature, StringComparer.Ordinal).ToArray(),
            callable.Values.OrderBy(static member => member.Signature, StringComparer.Ordinal).ToArray(),
            errors);
    }

    private static IEnumerable<Type> GetPublicTypes(Assembly assembly, List<string> errors)
    {
        try
        {
            return assembly.GetExportedTypes();
        }
        catch (ReflectionTypeLoadException exception)
        {
            foreach (var loaderException in exception.LoaderExceptions.OfType<Exception>())
            {
                errors.Add($"{assembly.GetName().Name}: type could not be inspected ({loaderException.GetType().Name}).");
            }

            return exception.Types.OfType<Type>();
        }
    }

    private static void AddConstructors(
        Type type,
        string assemblyPath,
        IDictionary<string, SurfaceMember> members,
        IDictionary<string, ApiDescriptor> callable)
    {
        if (type.IsInterface || type.IsAbstract || type.IsEnum)
        {
            return;
        }

        foreach (var constructor in type.GetConstructors(BindingFlags.Public | BindingFlags.Instance)
                     .OrderBy(TypeNames.Method, StringComparer.Ordinal))
        {
            var parameters = constructor.GetParameters();
            var reason = TypeSupport.HasConstructiblePublicPath(type)
                ? FirstUnsupported(parameters.Select(static parameter => parameter.ParameterType))
                : "no deterministic public construction path exists";
            var signature = TypeNames.Method(constructor);
            var member = new SurfaceMember(
                signature,
                TypeNames.For(type),
                ".ctor",
                IsConstructor: true,
                IsStatic: false,
                parameters.Select(static parameter => TypeNames.For(parameter.ParameterType)).ToArray(),
                "System.Void",
                reason);
            members.TryAdd(signature, member);
        }
    }

    private static void AddMethods(
        Type type,
        string assemblyPath,
        IDictionary<string, SurfaceMember> members,
        IDictionary<string, ApiDescriptor> callable)
    {
        var methods = type.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static);
        foreach (var method in methods
                     .Where(method => !method.IsSpecialName &&
                         method.DeclaringType != typeof(object) &&
                         method.DeclaringType?.Assembly == type.Assembly)
                     .OrderBy(TypeNames.Method, StringComparer.Ordinal))
        {
            var parameters = method.GetParameters();
            var reason = method.ContainsGenericParameters
                ? "open generic methods are outside the probe domain"
                : FirstUnsupported(parameters.Select(static parameter => parameter.ParameterType)) ??
                  TypeSupport.UnsupportedReason(method.ReturnType) ??
                  TypeSupport.UnsupportedReason(method);
            if (!method.IsStatic)
            {
                reason ??= TypeSupport.UnsupportedReason(type);
                if (type.IsAbstract || type.IsInterface)
                {
                    reason ??= "instance methods require a constructible public type";
                }
            }

            var signature = TypeNames.Method(method);
            var member = new SurfaceMember(
                signature,
                TypeNames.For(method.DeclaringType ?? type),
                method.Name,
                IsConstructor: false,
                method.IsStatic,
                parameters.Select(static parameter => TypeNames.For(parameter.ParameterType)).ToArray(),
                TypeNames.For(method.ReturnType),
                reason);
            members.TryAdd(signature, member);
            callable.TryAdd(signature, new ApiDescriptor(
                signature,
                member.DeclaringTypeName,
                method.Name,
                Path.GetFullPath(assemblyPath),
                method.IsStatic,
                IsConstructor: false,
                member.ParameterTypeNames,
                member.ReturnTypeName,
                reason));
        }
    }

    private static string? FirstUnsupported(IEnumerable<Type> types) =>
        types.Select(TypeSupport.UnsupportedReason).FirstOrDefault(static reason => reason is not null);
}

internal sealed class ProbeLoadContext : AssemblyLoadContext, IDisposable
{
    private readonly AssemblyDependencyResolver resolver;

    public ProbeLoadContext(string mainAssemblyPath)
        : base($"BehaviorOracle-{Guid.NewGuid():N}", isCollectible: true)
    {
        resolver = new AssemblyDependencyResolver(Path.GetFullPath(mainAssemblyPath));
    }

    protected override Assembly? Load(AssemblyName assemblyName)
    {
        var path = resolver.ResolveAssemblyToPath(assemblyName);
        return path is null ? null : LoadFromAssemblyPath(path);
    }

    public void Dispose() => Unload();
}

internal static class ReflectionExtensions
{
    public static bool IsCompilerGenerated(this Type type) =>
        type.GetCustomAttributes(typeof(System.Runtime.CompilerServices.CompilerGeneratedAttribute), inherit: false).Length > 0;
}
