using System.Collections;
using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace KeelMatrix.BehaviorOracle;

internal static class TypeSupport
{
    private const int MaxDependencyDepth = 32;

    private static readonly HashSet<Type> SimpleTypes =
    [
        typeof(string),
        typeof(char),
        typeof(bool),
        typeof(byte),
        typeof(sbyte),
        typeof(short),
        typeof(ushort),
        typeof(int),
        typeof(uint),
        typeof(long),
        typeof(ulong),
        typeof(nint),
        typeof(nuint),
        typeof(float),
        typeof(double),
        typeof(decimal),
        typeof(DateTime),
        typeof(DateTimeOffset),
        typeof(TimeSpan),
        typeof(Guid)
    ];

    private static readonly HashSet<Type> DisallowedTypes =
    [
        typeof(Stream),
        typeof(TextReader),
        typeof(TextWriter),
        typeof(HttpClient),
        typeof(CancellationToken),
        typeof(IFormatProvider),
        typeof(Random),
        typeof(RandomNumberGenerator)
    ];

    public static string? UnsupportedReason(Type type) =>
        UnsupportedReason(type, new HashSet<Type>(), 0);

    public static bool IsSupported(Type type) => UnsupportedReason(type) is null;

    public static string? UnsupportedReason(MethodInfo method) =>
        AnalyzeCallable(method);

    private static string? AnalyzeCallable(MethodInfo method)
    {
        var visitingMethods = new HashSet<MethodBase>();
        var reason = AnalyzeMethod(method, visitingMethods, depth: 0);
        if (reason is not null)
        {
            return reason;
        }

        if (!method.IsStatic)
        {
            reason = AnalyzeConstruction(method.DeclaringType!, new HashSet<Type>(), visitingMethods, depth: 0);
            if (reason is not null)
            {
                return $"receiver construction is unsupported: {reason}";
            }

            reason = AnalyzeObservation(method.DeclaringType!, new HashSet<Type>(), visitingMethods, depth: 0);
            if (reason is not null)
            {
                return $"receiver observation is unsupported: {reason}";
            }
        }

        foreach (var parameter in method.GetParameters())
        {
            reason = AnalyzeConstruction(parameter.ParameterType, new HashSet<Type>(), visitingMethods, depth: 0);
            if (reason is not null)
            {
                return $"input construction is unsupported: {reason}";
            }

            reason = AnalyzeObservation(parameter.ParameterType, new HashSet<Type>(), visitingMethods, depth: 0);
            if (reason is not null)
            {
                return $"input observation is unsupported: {reason}";
            }
        }

        reason = AnalyzeObservation(method.ReturnType, new HashSet<Type>(), visitingMethods, depth: 0);
        return reason is null ? null : $"return observation is unsupported: {reason}";
    }

    private static string? AnalyzeMethod(MethodBase method, HashSet<MethodBase> visiting, int depth)
    {
        if (depth > MaxDependencyDepth)
        {
            return "method dependency closure exceeded the analysis depth limit";
        }

        if (!visiting.Add(method))
        {
            return null;
        }

        try
        {
            var declaringType = method.DeclaringType;
            if (IsPlatformAssembly(declaringType?.Assembly))
            {
                if (IsHiddenStateApi(method))
                {
                    return "method accesses hidden external state such as time, randomness, culture, process, or I/O";
                }

                if (!IsAllowedPlatformDependency(method))
                {
                    return "method calls an API outside the conservative deterministic allowlist";
                }
            }

            if (!IsPlatformAssembly(declaringType?.Assembly) &&
                declaringType?.TypeInitializer is MethodBase typeInitializer &&
                !ReferenceEquals(typeInitializer, method))
            {
                var initializerReason = AnalyzeMethod(typeInitializer, visiting, depth + 1);
                if (initializerReason is not null)
                {
                    return initializerReason;
                }
            }

            var body = method.GetMethodBody()?.GetILAsByteArray();
            if (body is null)
            {
                return IsPlatformAssembly(declaringType?.Assembly)
                    ? null
                    : "method body cannot be inspected";
            }

            foreach (var instruction in IlReader.Read(method, body))
            {
                if (instruction.Operand is not int token)
                {
                    if (instruction.OpCode.OperandType == OperandType.InlineSig)
                    {
                        return "method contains an unresolved indirect call";
                    }

                    continue;
                }

                if (instruction.OpCode.OperandType == OperandType.InlineField)
                {
                    var field = ResolveField(method, token);
                    if (field is null)
                    {
                        return "method references an unresolved field";
                    }

                    if (IsHiddenStateType(field.DeclaringType))
                    {
                        return "method accesses a field on a hidden external-state type";
                    }

                    if (field.IsStatic && !IsImmutableConstant(field))
                    {
                        return "method reads or writes mutable static state outside the probe domain";
                    }
                }
                else if (instruction.OpCode.OperandType == OperandType.InlineTok)
                {
                    var member = ResolveMember(method, token);
                    if (member is FieldInfo tokenField)
                    {
                        if (IsHiddenStateType(tokenField.DeclaringType))
                        {
                            return "method accesses a field on a hidden external-state type";
                        }

                        if (tokenField.IsStatic && !IsImmutableConstant(tokenField))
                        {
                            return "method reads or writes mutable static state outside the probe domain";
                        }

                        continue;
                    }

                    if (member is not MethodBase tokenMethod)
                    {
                        return "method contains an unresolved metadata token";
                    }

                    var reason = AnalyzeCall(tokenMethod, visiting, depth);
                    if (reason is not null)
                    {
                        return reason;
                    }
                }
                else if (instruction.OpCode.OperandType == OperandType.InlineMethod)
                {
                    var called = ResolveMethod(method, token);
                    if (called is null)
                    {
                        return "method contains an unresolved call target";
                    }

                    var reason = AnalyzeCall(called, visiting, depth);
                    if (reason is not null)
                    {
                        return reason;
                    }
                }
            }

            return AnalyzeStateMachine(method, visiting, depth);
        }
        finally
        {
            visiting.Remove(method);
        }
    }

    private static FieldInfo? ResolveField(MethodBase method, int token)
    {
        try
        {
            return method.Module.ResolveField(token, method.DeclaringType?.GetGenericArguments(), MethodGenericArguments(method));
        }
        catch (Exception exception) when (IsUnresolvableMetadataException(exception))
        {
            return null;
        }
    }

    private static MethodBase? ResolveMethod(MethodBase method, int token)
    {
        try
        {
            return method.Module.ResolveMethod(token, method.DeclaringType?.GetGenericArguments(), MethodGenericArguments(method));
        }
        catch (Exception exception) when (IsUnresolvableMetadataException(exception))
        {
            return null;
        }
    }

    private static MemberInfo? ResolveMember(MethodBase method, int token)
    {
        try
        {
            return method.Module.ResolveMember(token, method.DeclaringType?.GetGenericArguments(), MethodGenericArguments(method));
        }
        catch (Exception exception) when (IsUnresolvableMetadataException(exception))
        {
            return null;
        }
    }

    private static bool IsUnresolvableMetadataException(Exception exception) =>
        exception is ArgumentException or
            FileNotFoundException or
            FileLoadException or
            BadImageFormatException or
            TypeLoadException or
            MissingMemberException or
            MemberAccessException;

    private static string? AnalyzeCall(MethodBase called, HashSet<MethodBase> visiting, int depth)
    {
        if (IsHiddenStateApi(called))
        {
            return "method accesses hidden external state such as time, randomness, culture, process, or I/O";
        }

        if (IsPlatformAssembly(called.DeclaringType?.Assembly))
        {
            return IsAllowedPlatformDependency(called)
                ? null
                : $"method calls an API outside the conservative deterministic allowlist ({called.DeclaringType?.FullName}.{called.Name})";
        }

        return AnalyzeMethod(called, visiting, depth + 1);
    }

    private static Type[] MethodGenericArguments(MethodBase method) =>
        method is MethodInfo methodInfo ? methodInfo.GetGenericArguments() : Type.EmptyTypes;

    private static bool IsPlatformAssembly(Assembly? assembly)
    {
        if (assembly is null)
        {
            return false;
        }

        var name = assembly.GetName().Name ?? string.Empty;
        return name == "System.Private.CoreLib" ||
            name == "netstandard" ||
            name.StartsWith("System.", StringComparison.Ordinal) ||
            name.StartsWith("Microsoft.", StringComparison.Ordinal);
    }

    private static bool IsHiddenStateApi(MethodBase method)
    {
        var type = method.DeclaringType;
        if (type is null)
        {
            return true;
        }

        if (type == typeof(DateTime) && method.Name is "get_Now" or "get_Today" or "get_UtcNow")
        {
            return true;
        }

        if (type == typeof(DateTimeOffset) && method.Name is "get_Now" or "get_UtcNow")
        {
            return true;
        }

        if (type == typeof(Guid) && method.Name == "NewGuid")
        {
            return true;
        }

        if (type == typeof(Random) || typeof(Random).IsAssignableFrom(type) ||
            type == typeof(RandomNumberGenerator) || typeof(RandomNumberGenerator).IsAssignableFrom(type))
        {
            return true;
        }

        if (type == typeof(CultureInfo) ||
            type == typeof(Thread) ||
            type == typeof(AppContext) ||
            type == typeof(Environment) ||
            type == typeof(Console))
        {
            return true;
        }

        var fullName = type.FullName ?? string.Empty;
        return fullName.StartsWith("System.IO.", StringComparison.Ordinal) ||
            fullName.StartsWith("System.Net.", StringComparison.Ordinal) ||
            fullName.StartsWith("System.Data.", StringComparison.Ordinal) ||
            fullName.StartsWith("System.Diagnostics.", StringComparison.Ordinal) ||
            fullName.StartsWith("System.Globalization.", StringComparison.Ordinal) ||
            fullName.StartsWith("System.Security.Cryptography.", StringComparison.Ordinal) ||
            (fullName.StartsWith("System.Threading.", StringComparison.Ordinal) &&
                !fullName.StartsWith("System.Threading.Tasks.", StringComparison.Ordinal)) ||
            fullName.StartsWith("Microsoft.Win32.", StringComparison.Ordinal);
    }

    private static bool IsHiddenStateType(Type? type)
    {
        if (type is null)
        {
            return true;
        }

        if (type == typeof(Random) || typeof(Random).IsAssignableFrom(type) ||
            type == typeof(RandomNumberGenerator) || typeof(RandomNumberGenerator).IsAssignableFrom(type))
        {
            return true;
        }

        var fullName = type.FullName ?? string.Empty;
        return fullName.StartsWith("System.IO.", StringComparison.Ordinal) ||
            fullName.StartsWith("System.Net.", StringComparison.Ordinal) ||
            fullName.StartsWith("System.Data.", StringComparison.Ordinal) ||
            fullName.StartsWith("System.Diagnostics.", StringComparison.Ordinal) ||
            fullName.StartsWith("System.Globalization.", StringComparison.Ordinal) ||
            fullName.StartsWith("System.Security.Cryptography.", StringComparison.Ordinal) ||
            (fullName.StartsWith("System.Threading.", StringComparison.Ordinal) &&
                !fullName.StartsWith("System.Threading.Tasks.", StringComparison.Ordinal)) ||
            fullName.StartsWith("Microsoft.Win32.", StringComparison.Ordinal);
    }

    private static bool IsAllowedPlatformDependency(MethodBase method)
    {
        var type = method.DeclaringType;
        if (type is null || IsHiddenStateApi(method))
        {
            return false;
        }

        if (method is ConstructorInfo && typeof(Exception).IsAssignableFrom(type))
        {
            return true;
        }

        if (type == typeof(string))
        {
            return method.Name is "get_Length" or "get_Chars" or "Trim" or "TrimStart" or "TrimEnd";
        }

        if (type == typeof(Guid))
        {
            return method.Name == "ToString";
        }

        if (type == typeof(Array))
        {
            return method.Name == "Empty";
        }

        if (type == typeof(Math) || type == typeof(MathF))
        {
            return true;
        }

        if (type == typeof(System.Runtime.CompilerServices.RuntimeHelpers))
        {
            return method.Name == "InitializeArray";
        }

        if (type.IsGenericType && type.GetGenericTypeDefinition() == typeof(Nullable<>))
        {
            return method.Name is "get_HasValue" or "get_Value" or "GetValueOrDefault";
        }

        if (type.IsGenericType && type.GetGenericTypeDefinition() == typeof(List<>))
        {
            return method.Name is "get_Count" or "Add" or "Insert";
        }

        if (type.IsGenericType && type.GetGenericTypeDefinition() == typeof(HashSet<>))
        {
            return method.Name is "get_Count" or "Add";
        }

        if (type.IsGenericType && type.GetGenericTypeDefinition() == typeof(Dictionary<,>))
        {
            return method.Name is "get_Count" or "Add" or "set_Item";
        }

        if (type == typeof(Task) ||
            (type.IsGenericType && type.GetGenericTypeDefinition() == typeof(Task<>)))
        {
            return method.Name is "FromResult" or "get_Result" or "GetAwaiter" or "get_CompletedTask";
        }

        if (type == typeof(ValueTask) ||
            (type.IsGenericType && type.GetGenericTypeDefinition() == typeof(ValueTask<>)))
        {
            return method.Name is "FromResult" or "GetAwaiter" or "get_Result";
        }

        if (type.IsGenericType &&
            (type.GetGenericTypeDefinition() == typeof(System.Runtime.CompilerServices.AsyncTaskMethodBuilder<>) ||
             type.GetGenericTypeDefinition() == typeof(System.Runtime.CompilerServices.AsyncValueTaskMethodBuilder<>)))
        {
            return method.Name is "Create" or "Start" or "AwaitOnCompleted" or "AwaitUnsafeOnCompleted" or
                "SetException" or "SetResult" or "get_Task";
        }

        if (type.IsGenericType &&
            (type.GetGenericTypeDefinition() == typeof(System.Runtime.CompilerServices.TaskAwaiter<>) ||
             type.GetGenericTypeDefinition() == typeof(System.Runtime.CompilerServices.ValueTaskAwaiter<>)))
        {
            return method.Name is "GetResult" or "get_IsCompleted" or "OnCompleted" or "UnsafeOnCompleted";
        }

        return method is ConstructorInfo && type == typeof(object);
    }

    private static bool IsImmutableConstant(FieldInfo field) =>
        field.IsLiteral ||
        (field.IsInitOnly &&
            (field.FieldType == typeof(string) || field.FieldType.IsPrimitive || field.FieldType.IsEnum ||
             field.DeclaringType?.IsDefined(typeof(CompilerGeneratedAttribute), inherit: false) == true));

    private static string? UnsupportedReason(Type type, HashSet<Type> visiting, int depth)
    {
        if (type.IsByRef || type.IsPointer || type.IsFunctionPointer)
        {
            return "by-reference and pointer values are outside the probe domain";
        }

        if (type == typeof(void))
        {
            return null;
        }

        if (DisallowedTypes.Contains(type) ||
            IsHiddenStateType(type) ||
            typeof(Delegate).IsAssignableFrom(type) ||
            typeof(System.Linq.Expressions.Expression).IsAssignableFrom(type))
        {
            return "external-state, callback, or expression values are outside the probe domain";
        }

        if (type.IsGenericParameter || type.ContainsGenericParameters)
        {
            return "open generic values are outside the probe domain";
        }

        if (type.IsEnum || SimpleTypes.Contains(type))
        {
            return null;
        }

        if (depth > 4)
        {
            return "object graph recursion limit exceeded";
        }

        if (Nullable.GetUnderlyingType(type) is Type nullableType)
        {
            return UnsupportedReason(nullableType, visiting, depth + 1);
        }

        if (IsTaskLike(type))
        {
            return UnsupportedReason(type.GetGenericArguments()[0], visiting, depth + 1);
        }

        if (type.IsArray)
        {
            if (type.GetArrayRank() != 1)
            {
                return "only one-dimensional arrays are supported";
            }

            return UnsupportedReason(type.GetElementType()!, visiting, depth + 1);
        }

        var enumerableElementType = GenericEnumerableElementType(type);
        if (enumerableElementType is not null && !TryGetCollectionShape(type, out _, out _, out _))
        {
            var elementReason = UnsupportedReason(enumerableElementType, visiting, depth + 1);
            return elementReason is null
                ? "no deterministic public collection construction path exists"
                : $"collection element is unsupported: {elementReason}";
        }

        if (TryGetCollectionShape(type, out var elementType, out var keyType, out var valueType))
        {
            if (keyType is not null)
            {
                return UnsupportedReason(keyType, visiting, depth + 1) ??
                    UnsupportedReason(valueType!, visiting, depth + 1);
            }

            return UnsupportedReason(elementType!, visiting, depth + 1);
        }

        if (!type.IsPublic && !type.IsNestedPublic)
        {
            return "the type is not public";
        }

        if (type.IsInterface || type.IsAbstract || !HasConstructiblePublicPath(type))
        {
            return "no deterministic public construction path exists";
        }

        if (!visiting.Add(type))
        {
            return "cyclic object graphs are outside the bounded probe domain";
        }

        foreach (var member in WritableMembers(type))
        {
            var reason = UnsupportedReason(member.MemberType, visiting, depth + 1);
            if (reason is not null)
            {
                visiting.Remove(type);
                return $"member {member.Name} is unsupported: {reason}";
            }
        }

        visiting.Remove(type);
        return null;
    }

    public static bool IsTaskLike(Type type) =>
        type.IsGenericType &&
        (type.GetGenericTypeDefinition() == typeof(Task<>) ||
         type.GetGenericTypeDefinition() == typeof(ValueTask<>));

    public static bool TryGetCollectionShape(
        Type type,
        out Type? elementType,
        out Type? keyType,
        out Type? valueType)
    {
        elementType = null;
        keyType = null;
        valueType = null;

        if (type == typeof(string) || type.IsArray)
        {
            return false;
        }

        if (type.IsGenericType)
        {
            var definition = type.GetGenericTypeDefinition();
            var args = type.GetGenericArguments();
            if (args.Length == 1 &&
                (definition == typeof(List<>) ||
                 definition == typeof(HashSet<>)))
            {
                elementType = args[0];
                return HasConstructiblePublicPath(type) && HasPublicAdd(type, elementType);
            }

            if (args.Length == 1 &&
                (definition == typeof(IList<>) ||
                 definition == typeof(ICollection<>) ||
                 definition == typeof(IEnumerable<>) ||
                 definition == typeof(IReadOnlyCollection<>) ||
                 definition == typeof(IReadOnlyList<>) ||
                 definition == typeof(ISet<>)))
            {
                elementType = args[0];
                return true;
            }

            if (args.Length == 2 &&
                (definition == typeof(Dictionary<,>) ||
                 definition == typeof(IDictionary<,>) ||
                 definition == typeof(IReadOnlyDictionary<,>)))
            {
                keyType = args[0];
                valueType = args[1];
                return true;
            }
        }

        var enumerable = GenericEnumerableInterface(type);
        if (enumerable is not null &&
            (type.IsPublic || type.IsNestedPublic) &&
            HasConstructiblePublicPath(type) &&
            HasPublicAdd(type, enumerable.GetGenericArguments()[0]))
        {
            elementType = enumerable.GetGenericArguments()[0];
            return true;
        }

        return false;
    }

    private static string? AnalyzeStateMachine(MethodBase method, HashSet<MethodBase> visiting, int depth)
    {
        var stateMachineType = method.GetCustomAttribute<AsyncStateMachineAttribute>()?.StateMachineType ??
            method.GetCustomAttribute<IteratorStateMachineAttribute>()?.StateMachineType;
        if (stateMachineType is null)
        {
            return null;
        }

        var moveNext = stateMachineType.GetMethod(
            "MoveNext",
            BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        return moveNext is null
            ? "compiler-generated state-machine body cannot be inspected"
            : AnalyzeMethod(moveNext, visiting, depth + 1);
    }

    private static string? AnalyzeConstruction(
        Type type,
        HashSet<Type> visitingTypes,
        HashSet<MethodBase> visitingMethods,
        int depth)
    {
        if (depth > 8)
        {
            return "input construction dependency exceeded the analysis depth limit";
        }

        if (Nullable.GetUnderlyingType(type) is Type nullableType)
        {
            return AnalyzeConstruction(nullableType, visitingTypes, visitingMethods, depth + 1);
        }

        if (type.IsByRef || type.IsPointer || type.IsFunctionPointer || type == typeof(void))
        {
            return null;
        }

        if (type.IsEnum || SimpleTypes.Contains(type))
        {
            return null;
        }

        if (IsTaskLike(type))
        {
            return AnalyzeObservation(type.GetGenericArguments()[0], visitingTypes, visitingMethods, depth + 1);
        }

        if (type.IsArray)
        {
            return AnalyzeConstruction(type.GetElementType()!, visitingTypes, visitingMethods, depth + 1);
        }

        if (TryGetCollectionShape(type, out var elementType, out var keyType, out var valueType))
        {
            var reason = keyType is null
                ? AnalyzeConstruction(elementType!, visitingTypes, visitingMethods, depth + 1)
                : AnalyzeConstruction(keyType, visitingTypes, visitingMethods, depth + 1) ??
                  AnalyzeConstruction(valueType!, visitingTypes, visitingMethods, depth + 1);
            if (reason is not null)
            {
                return reason;
            }

            if (IsBuiltInCollection(type))
            {
                return null;
            }

            reason = AnalyzePublicParameterlessConstructor(type, visitingMethods, depth);
            return reason ?? AnalyzeEnumerableExecution(type, visitingMethods, depth);
        }

        var basicReason = UnsupportedShapeReason(type);
        if (basicReason is not null)
        {
            return basicReason;
        }

        if (!visitingTypes.Add(type))
        {
            return "cyclic input construction is outside the bounded probe domain";
        }

        try
        {
            var reason = AnalyzePublicParameterlessConstructor(type, visitingMethods, depth);
            if (reason is not null)
            {
                return reason;
            }

            foreach (var member in WritableMembers(type))
            {
                reason = AnalyzeMemberBody(member, visitingMethods, depth);
                if (reason is not null)
                {
                    return $"member {member.Name} body is unsupported: {reason}";
                }

                reason = AnalyzeConstruction(member.MemberType, visitingTypes, visitingMethods, depth + 1);
                if (reason is not null)
                {
                    return $"member {member.Name} is unsupported: {reason}";
                }
            }

            return null;
        }
        finally
        {
            visitingTypes.Remove(type);
        }
    }

    private static string? AnalyzeObservation(
        Type type,
        HashSet<Type> visitingTypes,
        HashSet<MethodBase> visitingMethods,
        int depth)
    {
        if (depth > 8)
        {
            return "return observation dependency exceeded the analysis depth limit";
        }

        if (Nullable.GetUnderlyingType(type) is Type nullableType)
        {
            return AnalyzeObservation(nullableType, visitingTypes, visitingMethods, depth + 1);
        }

        if (type.IsByRef || type.IsPointer || type.IsFunctionPointer || type == typeof(void) ||
            type.IsEnum || SimpleTypes.Contains(type))
        {
            return null;
        }

        if (type.IsInterface)
        {
            return "interface-typed return observations are outside the probe domain";
        }

        if (IsTaskLike(type))
        {
            return AnalyzeObservation(type.GetGenericArguments()[0], visitingTypes, visitingMethods, depth + 1);
        }

        if (type.IsArray)
        {
            return AnalyzeObservation(type.GetElementType()!, visitingTypes, visitingMethods, depth + 1);
        }

        if (TryGetCollectionShape(type, out var elementType, out var keyType, out var valueType))
        {
            var reason = keyType is null
                ? AnalyzeObservation(elementType!, visitingTypes, visitingMethods, depth + 1)
                : AnalyzeObservation(keyType, visitingTypes, visitingMethods, depth + 1) ??
                  AnalyzeObservation(valueType!, visitingTypes, visitingMethods, depth + 1);
            if (reason is not null)
            {
                return reason;
            }

            return IsBuiltInCollection(type)
                ? null
                : AnalyzeEnumerableExecution(type, visitingMethods, depth);
        }

        var basicReason = UnsupportedShapeReason(type);
        if (basicReason is not null)
        {
            return basicReason;
        }

        if (!visitingTypes.Add(type))
        {
            return "cyclic return observation is outside the bounded probe domain";
        }

        try
        {
            foreach (var member in ReadableMembers(type))
            {
                var reason = AnalyzeMemberBody(member, visitingMethods, depth);
                if (reason is not null)
                {
                    return $"member {member.Name} body is unsupported: {reason}";
                }

                reason = AnalyzeObservation(member.MemberType, visitingTypes, visitingMethods, depth + 1);
                if (reason is not null)
                {
                    return $"member {member.Name} is unsupported: {reason}";
                }
            }

            return null;
        }
        finally
        {
            visitingTypes.Remove(type);
        }
    }

    private static string? AnalyzePublicParameterlessConstructor(
        Type type,
        HashSet<MethodBase> visitingMethods,
        int depth)
    {
        var constructor = type.GetConstructor(
            BindingFlags.Public | BindingFlags.Instance,
            binder: null,
            Type.EmptyTypes,
            modifiers: null);
        return constructor is null
            ? "no deterministic public construction path exists"
            : AnalyzeMethod(constructor, visitingMethods, depth + 1);
    }

    private static string? AnalyzeMemberBody(
        WritableMember member,
        HashSet<MethodBase> visitingMethods,
        int depth)
    {
        return member.Member switch
        {
            PropertyInfo property when property.SetMethod is MethodInfo setter =>
                AnalyzeMethod(setter, visitingMethods, depth + 1),
            _ => null
        };
    }

    private static string? AnalyzeMemberBody(
        ReadableMember member,
        HashSet<MethodBase> visitingMethods,
        int depth)
    {
        return member.Member switch
        {
            PropertyInfo property when property.GetMethod is MethodInfo getter =>
                AnalyzeMethod(getter, visitingMethods, depth + 1),
            _ => null
        };
    }

    private static string? AnalyzeEnumerableExecution(
        Type type,
        HashSet<MethodBase> visitingMethods,
        int depth)
    {
        foreach (var interfaceType in type.GetInterfaces()
                     .Where(static candidate =>
                         candidate == typeof(IEnumerable) ||
                         (candidate.IsGenericType && candidate.GetGenericTypeDefinition() == typeof(IEnumerable<>))))
        {
            var map = type.GetInterfaceMap(interfaceType);
            foreach (var implementation in map.TargetMethods)
            {
                var reason = AnalyzeMethod(implementation, visitingMethods, depth + 1);
                if (reason is not null)
                {
                    return reason;
                }
            }
        }

        foreach (var enumeratorType in UserEnumeratorTypes(type.Assembly))
        {
            foreach (var implementation in EnumeratorMethods(enumeratorType))
            {
                var reason = AnalyzeMethod(implementation, visitingMethods, depth + 1);
                if (reason is not null)
                {
                    return reason;
                }
            }
        }

        return null;
    }

    private static IEnumerable<Type> UserEnumeratorTypes(Assembly assembly)
    {
        Type[] types;
        try
        {
            types = assembly.GetTypes();
        }
        catch (ReflectionTypeLoadException exception)
        {
            types = exception.Types.OfType<Type>().ToArray();
        }

        return types.Where(static candidate =>
            !candidate.IsInterface && !candidate.IsAbstract && typeof(IEnumerator).IsAssignableFrom(candidate));
    }

    private static HashSet<MethodBase> EnumeratorMethods(Type type)
    {
        var methods = new HashSet<MethodBase>();
        foreach (var interfaceType in type.GetInterfaces()
                     .Where(static candidate =>
                         candidate == typeof(IEnumerator) ||
                         (candidate.IsGenericType && candidate.GetGenericTypeDefinition() == typeof(IEnumerator<>))))
        {
            var map = type.GetInterfaceMap(interfaceType);
            foreach (var method in map.TargetMethods)
            {
                methods.Add(method);
            }
        }

        return methods;
    }

    private static string? UnsupportedShapeReason(Type type)
    {
        if (DisallowedTypes.Contains(type) ||
            IsHiddenStateType(type) ||
            typeof(Delegate).IsAssignableFrom(type) ||
            typeof(System.Linq.Expressions.Expression).IsAssignableFrom(type))
        {
            return "external-state, callback, or expression values are outside the probe domain";
        }

        if (type.IsGenericParameter || type.ContainsGenericParameters)
        {
            return "open generic values are outside the probe domain";
        }

        if (!type.IsPublic && !type.IsNestedPublic)
        {
            return "the type is not public";
        }

        if (type.IsInterface || type.IsAbstract || !HasConstructiblePublicPath(type))
        {
            return "no deterministic public construction path exists";
        }

        return null;
    }

    private static bool IsBuiltInCollection(Type type)
    {
        if (!type.IsGenericType)
        {
            return false;
        }

        var definition = type.GetGenericTypeDefinition();
        return definition == typeof(List<>) || definition == typeof(HashSet<>) ||
            definition == typeof(Dictionary<,>);
    }

    private static Type? GenericEnumerableElementType(Type type) =>
        GenericEnumerableInterface(type)?.GetGenericArguments()[0];

    private static Type? GenericEnumerableInterface(Type type) =>
        type.GetInterfaces()
            .FirstOrDefault(static candidate =>
                candidate.IsGenericType &&
                candidate.GetGenericTypeDefinition() == typeof(IEnumerable<>));

    public static bool HasConstructiblePublicPath(Type type) =>
        type.IsValueType ||
        type.GetConstructor(
            BindingFlags.Public | BindingFlags.Instance,
            binder: null,
            Type.EmptyTypes,
            modifiers: null) is not null;

    private static bool HasPublicAdd(Type type, Type elementType) =>
        type.GetMethod(
            "Add",
            BindingFlags.Public | BindingFlags.Instance,
            binder: null,
            [elementType],
            modifiers: null) is not null;

    public static IReadOnlyList<WritableMember> WritableMembers(Type type) =>
        type.GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Where(static property =>
                property.GetIndexParameters().Length == 0 &&
                property.GetMethod is not null &&
                property.SetMethod is not null &&
                property.SetMethod.IsPublic)
            .Select(static property => new WritableMember(property.Name, property.PropertyType, property))
            .Concat(type.GetFields(BindingFlags.Public | BindingFlags.Instance)
                .Where(static field => !field.IsInitOnly && !field.IsLiteral)
                .Select(static field => new WritableMember(field.Name, field.FieldType, field)))
            .OrderBy(static member => member.Name, StringComparer.Ordinal)
            .ToArray();

    public static IReadOnlyList<ReadableMember> ReadableMembers(Type type) =>
        type.GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Where(static property =>
                property.GetIndexParameters().Length == 0 &&
                property.GetMethod is not null &&
                property.GetMethod.IsPublic)
            .Select(static property => new ReadableMember(property.Name, property.PropertyType, property))
            .Concat(type.GetFields(BindingFlags.Public | BindingFlags.Instance)
                .Where(static field => !field.FieldType.IsPointer)
                .Select(static field => new ReadableMember(field.Name, field.FieldType, field)))
            .GroupBy(static member => member.Name, StringComparer.Ordinal)
            .Select(static group => group.First())
            .OrderBy(static member => member.Name, StringComparer.Ordinal)
            .ToArray();
}

internal static class IlReader
{
    private static readonly OpCode[] OneByteOpCodes = BuildOpCodes(singleByte: true);
    private static readonly OpCode[] TwoByteOpCodes = BuildOpCodes(singleByte: false);

    public static IEnumerable<IlInstruction> Read(MethodBase method, byte[] body)
    {
        var position = 0;
        while (position < body.Length)
        {
            var opcode = body[position++] == 0xFE
                ? TwoByteOpCodes[body[position++]]
                : OneByteOpCodes[body[position - 1]];
            object? operand = null;
            switch (opcode.OperandType)
            {
                case OperandType.InlineField:
                case OperandType.InlineMethod:
                case OperandType.InlineSig:
                case OperandType.InlineString:
                case OperandType.InlineTok:
                case OperandType.InlineType:
                case OperandType.InlineI:
                case OperandType.InlineBrTarget:
                    operand = BitConverter.ToInt32(body, position);
                    position += 4;
                    break;
                case OperandType.InlineI8:
                case OperandType.InlineR:
                    position += 8;
                    break;
                case OperandType.ShortInlineI:
                case OperandType.ShortInlineBrTarget:
                case OperandType.ShortInlineR:
                case OperandType.ShortInlineVar:
                    position++;
                    break;
                case OperandType.InlineVar:
                    position += 2;
                    break;
                case OperandType.InlineSwitch:
                    var count = BitConverter.ToInt32(body, position);
                    position += 4 + (count * 4);
                    break;
            }

            yield return new IlInstruction(opcode, operand);
        }
    }

    private static OpCode[] BuildOpCodes(bool singleByte)
    {
        var result = new OpCode[0x100];
        foreach (var field in typeof(OpCodes).GetFields(BindingFlags.Public | BindingFlags.Static))
        {
            if (field.GetValue(null) is not OpCode opcode)
            {
                continue;
            }

            var value = unchecked((ushort)opcode.Value);
            if (singleByte && value < 0x100)
            {
                result[value] = opcode;
            }
            else if (!singleByte && (value & 0xFF00) == 0xFE00)
            {
                result[value & 0xFF] = opcode;
            }
        }

        return result;
    }
}

internal sealed record IlInstruction(OpCode OpCode, object? Operand);

internal sealed record WritableMember(string Name, Type MemberType, MemberInfo Member);
internal sealed record ReadableMember(string Name, Type MemberType, MemberInfo Member);
