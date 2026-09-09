using System.Collections;
using System.Reflection;
using System.Reflection.Emit;

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

    public static string? UnsupportedReason(MethodInfo method) =>
        AnalyzeMethod(method, new HashSet<MethodBase>(), depth: 0);

    private static string? AnalyzeMethod(MethodInfo method, HashSet<MethodBase> visiting, int depth)
    {
        if (depth > 8 || !visiting.Add(method))
        {
            return null;
        }

        try
        {
            var body = method.GetMethodBody()?.GetILAsByteArray();
            if (body is null)
            {
                return null;
            }

            foreach (var instruction in IlReader.Read(method, body))
            {
                if (instruction.Operand is not int token)
                {
                    continue;
                }

                if (instruction.OpCode.OperandType == OperandType.InlineField)
                {
                    var field = ResolveField(method, token);
                    if (field?.IsStatic == true && !IsImmutableConstant(field))
                    {
                        return "method reads or writes mutable static state outside the probe domain";
                    }
                }
                else if (instruction.OpCode.OperandType is OperandType.InlineMethod or OperandType.InlineTok)
                {
                    var called = ResolveMethod(method, token);
                    if (called is null)
                    {
                        continue;
                    }

                    if (IsExternalStateApi(called.DeclaringType))
                    {
                        return "method accesses filesystem, environment, process, network, database, or console state";
                    }

                    if (called is MethodInfo calledMethod && called.DeclaringType?.Assembly == method.DeclaringType?.Assembly)
                    {
                        var reason = AnalyzeMethod(calledMethod, visiting, depth + 1);
                        if (reason is not null)
                        {
                            return reason;
                        }
                    }
                }
            }

            return null;
        }
        finally
        {
            visiting.Remove(method);
        }
    }

    private static FieldInfo? ResolveField(MethodInfo method, int token)
    {
        try
        {
            return method.Module.ResolveField(token, method.DeclaringType?.GetGenericArguments(), method.GetGenericArguments());
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    private static MethodBase? ResolveMethod(MethodInfo method, int token)
    {
        try
        {
            return method.Module.ResolveMethod(token, method.DeclaringType?.GetGenericArguments(), method.GetGenericArguments());
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    private static bool IsExternalStateApi(Type? type)
    {
        if (type is null)
        {
            return false;
        }

        var fullName = type.FullName ?? string.Empty;
        return type == typeof(Environment) ||
            type == typeof(Console) ||
            fullName.StartsWith("System.IO.", StringComparison.Ordinal) ||
            fullName.StartsWith("System.Net.", StringComparison.Ordinal) ||
            fullName.StartsWith("System.Diagnostics.", StringComparison.Ordinal) ||
            fullName.StartsWith("System.Data.", StringComparison.Ordinal) ||
            fullName.StartsWith("Microsoft.Win32.", StringComparison.Ordinal);
    }

    private static bool IsImmutableConstant(FieldInfo field) =>
        field.IsLiteral ||
        (field.IsInitOnly &&
            (field.FieldType == typeof(string) || field.FieldType.IsPrimitive || field.FieldType.IsEnum));

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

internal static class IlReader
{
    private static readonly OpCode[] OneByteOpCodes = BuildOpCodes(singleByte: true);
    private static readonly OpCode[] TwoByteOpCodes = BuildOpCodes(singleByte: false);

    public static IEnumerable<IlInstruction> Read(MethodInfo method, byte[] body)
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
