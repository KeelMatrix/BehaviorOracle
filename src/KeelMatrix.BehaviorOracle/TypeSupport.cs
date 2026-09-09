using System.Collections;
using System.Reflection;

namespace KeelMatrix.BehaviorOracle;

internal static class TypeSupport
{
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
        typeof(IFormatProvider)
    ];

    public static string? UnsupportedReason(Type type) =>
        UnsupportedReason(type, new HashSet<Type>(), 0);

    public static bool IsSupported(Type type) => UnsupportedReason(type) is null;

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
                 definition == typeof(HashSet<>) ||
                 definition == typeof(IList<>) ||
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

        var enumerable = type.GetInterfaces()
            .FirstOrDefault(static candidate =>
                candidate.IsGenericType &&
                candidate.GetGenericTypeDefinition() == typeof(IEnumerable<>));
        if (enumerable is not null && type.IsPublic)
        {
            elementType = enumerable.GetGenericArguments()[0];
            return true;
        }

        return false;
    }

    public static bool HasConstructiblePublicPath(Type type) =>
        type.IsValueType ||
        type.GetConstructor(
            BindingFlags.Public | BindingFlags.Instance,
            binder: null,
            Type.EmptyTypes,
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

internal sealed record WritableMember(string Name, Type MemberType, MemberInfo Member);
internal sealed record ReadableMember(string Name, Type MemberType, MemberInfo Member);
