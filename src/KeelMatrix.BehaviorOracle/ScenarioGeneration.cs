using System.Globalization;
using System.Reflection;

namespace KeelMatrix.BehaviorOracle;

internal sealed class ScenarioGenerator
{
    private const int DefaultMaxDepth = 3;
    private const int DefaultMaxCollectionItems = 4;

    public static IReadOnlyList<GeneratedScenario> Generate(ApiDescriptor descriptor, int count, long seed)
    {
        if (!descriptor.IsSupported || descriptor.IsConstructor)
        {
            return [];
        }

        using var loadContext = new ProbeLoadContext(descriptor.AssemblyPath);
        var assembly = loadContext.LoadFromAssemblyPath(Path.GetFullPath(descriptor.AssemblyPath));
        var method = ReflectionLookup.FindMethod(assembly, descriptor);
        if (method is null)
        {
            return [];
        }

        var scenarios = new List<GeneratedScenario>(count);
        for (var index = 0; index < count; index++)
        {
            var random = new DeterministicRandom(seed, index);
            var arguments = method.GetParameters()
                .Select((parameter, argumentIndex) =>
                    GeneratedValueFactory.Create(
                        parameter.ParameterType,
                        random.Fork(argumentIndex),
                        depth: 0,
                        maxDepth: DefaultMaxDepth,
                        maxCollectionItems: DefaultMaxCollectionItems,
                        variant: index + argumentIndex * 17))
                .ToArray();
            scenarios.Add(new GeneratedScenario(index, seed, arguments));
        }

        return scenarios;
    }
}

internal sealed class DeterministicRandom
{
    private ulong state;

    public DeterministicRandom(long seed, int discriminator = 0)
    {
        state = unchecked((ulong)seed) ^ (unchecked((ulong)(uint)discriminator) * 0x9E3779B97F4A7C15UL);
        if (state == 0)
        {
            state = 0xA0761D6478BD642FUL;
        }
    }

    public DeterministicRandom Fork(int discriminator) =>
        new(unchecked((long)(NextUInt64() ^ unchecked((ulong)(uint)discriminator))));

    public int NextInt(int exclusiveMax)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(exclusiveMax);
        return (int)(NextUInt64() % (uint)exclusiveMax);
    }

    public long NextInt64(long minInclusive, long maxInclusive)
    {
        ArgumentOutOfRangeException.ThrowIfGreaterThan(minInclusive, maxInclusive);

        var range = unchecked((ulong)(maxInclusive - minInclusive));
        if (range == ulong.MaxValue)
        {
            return unchecked((long)NextUInt64());
        }

        return minInclusive + unchecked((long)(NextUInt64() % (range + 1)));
    }

    public ulong NextUInt64()
    {
        var z = (state += 0x9E3779B97F4A7C15UL);
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
        return z ^ (z >> 31);
    }
}

internal static class GeneratedValueFactory
{
    public static GeneratedValue Create(
        Type type,
        DeterministicRandom random,
        int depth,
        int maxDepth,
        int maxCollectionItems,
        int variant)
    {
        if (Nullable.GetUnderlyingType(type) is Type nullableType)
        {
            return variant % 11 == 0
                ? GeneratedValue.Null(TypeNames.For(type))
                : Create(nullableType, random, depth + 1, maxDepth, maxCollectionItems, variant);
        }

        if (!type.IsValueType && (variant % 13 == 0 || type == typeof(string) && variant % 7 == 0))
        {
            return GeneratedValue.Null(TypeNames.For(type));
        }

        if (type == typeof(string))
        {
            return StringValue(variant);
        }

        if (type == typeof(bool))
        {
            return new GeneratedValue { Kind = GeneratedValueKind.Boolean, TypeName = TypeNames.For(type), BooleanValue = variant % 2 == 0 };
        }

        if (type == typeof(char))
        {
            return new GeneratedValue
            {
                Kind = GeneratedValueKind.Integer,
                TypeName = TypeNames.For(type),
                IntegerValue = variant % 5 == 0 ? 0 : 'A' + variant % 26
            };
        }

        if (type.IsEnum)
        {
            var names = Enum.GetNames(type).OrderBy(static name => name, StringComparer.Ordinal).ToArray();
            return names.Length == 0
                ? GeneratedValue.Null(TypeNames.For(type))
                : new GeneratedValue
                {
                    Kind = GeneratedValueKind.Enum,
                    TypeName = TypeNames.For(type),
                    TextValue = names[variant % names.Length]
                };
        }

        if (type == typeof(float) || type == typeof(double))
        {
            var choices = new[] { 0d, 1d, -1d, 100d, 100.5d, double.Epsilon };
            return new GeneratedValue
            {
                Kind = GeneratedValueKind.FloatingPoint,
                TypeName = TypeNames.For(type),
                FloatingPointValue = choices[variant % choices.Length]
            };
        }

        if (type == typeof(decimal))
        {
            var choices = new[] { "0", "1", "-1", "99.99", "100", "100.01", "1000" };
            return new GeneratedValue
            {
                Kind = GeneratedValueKind.Decimal,
                TypeName = TypeNames.For(type),
                TextValue = choices[variant % choices.Length]
            };
        }

        if (type == typeof(DateTime) || type == typeof(DateTimeOffset) ||
            type == typeof(TimeSpan) || type == typeof(Guid))
        {
            return new GeneratedValue
            {
                Kind = GeneratedValueKind.String,
                TypeName = TypeNames.For(type),
                TextValue = type == typeof(Guid)
                    ? "00000000-0000-0000-0000-" + (variant % 10000000000L).ToString("D12", CultureInfo.InvariantCulture)
                    : variant % 2 == 0 ? "2020-01-02T03:04:05.0000000Z" : "00:00:01"
            };
        }

        if (IsInteger(type))
        {
            var choices = new long[] { 0, 100, -1, 1, 101, 99, 2, 10, 1000, int.MaxValue, int.MinValue };
            return new GeneratedValue
            {
                Kind = GeneratedValueKind.Integer,
                TypeName = TypeNames.For(type),
                IntegerValue = choices[variant % choices.Length]
            };
        }

        if (type.IsArray)
        {
            var length = variant % 4;
            return new GeneratedValue
            {
                Kind = GeneratedValueKind.Collection,
                TypeName = TypeNames.For(type),
                Items = Enumerable.Range(0, length)
                    .Select(index => Create(type.GetElementType()!, random.Fork(index), depth + 1, maxDepth, maxCollectionItems, variant + index + 1))
                    .ToArray()
            };
        }

        if (TypeSupport.TryGetCollectionShape(type, out var elementType, out var keyType, out var valueType))
        {
            var length = Math.Min(maxCollectionItems, variant % 4);
            var items = new List<GeneratedValue>(length);
            for (var index = 0; index < length; index++)
            {
                var item = keyType is not null
                    ? new GeneratedValue
                    {
                        Kind = GeneratedValueKind.Object,
                        TypeName = "System.Collections.Generic.KeyValuePair",
                        Members = new Dictionary<string, GeneratedValue>(StringComparer.Ordinal)
                        {
                            ["Key"] = Create(keyType, random.Fork(index * 2), depth + 1, maxDepth, maxCollectionItems, variant + index),
                            ["Value"] = Create(valueType!, random.Fork(index * 2 + 1), depth + 1, maxDepth, maxCollectionItems, variant + index + 1)
                        }
                    }
                    : Create(elementType!, random.Fork(index), depth + 1, maxDepth, maxCollectionItems, variant + index + 1);
                items.Add(item);
            }

            return new GeneratedValue
            {
                Kind = GeneratedValueKind.Collection,
                TypeName = TypeNames.For(type),
                Items = items
            };
        }

        if (depth >= maxDepth)
        {
            return new GeneratedValue
            {
                Kind = GeneratedValueKind.Object,
                TypeName = TypeNames.For(type),
                Members = new Dictionary<string, GeneratedValue>(StringComparer.Ordinal)
            };
        }

        if (TypeSupport.HasConstructiblePublicPath(type))
        {
            var members = new Dictionary<string, GeneratedValue>(StringComparer.Ordinal);
            foreach (var member in TypeSupport.WritableMembers(type))
            {
                if (variant < 2 || variant % 3 == 0 || members.Count == 0)
                {
                    var memberVariant = variant < 2 ? 1 : variant + members.Count + 1;
                    members[member.Name] = Create(member.MemberType, random.Fork(members.Count), depth + 1, maxDepth, maxCollectionItems, memberVariant);
                }
            }

            return new GeneratedValue
            {
                Kind = GeneratedValueKind.Object,
                TypeName = TypeNames.For(type),
                Members = members
            };
        }

        return GeneratedValue.Null(TypeNames.For(type));
    }

    private static GeneratedValue StringValue(int variant)
    {
        var values = new[]
        {
            string.Empty,
            " ",
            "\t\r\n",
            "alpha",
            "Alpha-123",
            "Δelta-東京",
            new string('x', 256),
            "100",
            "boundary"
        };
        return new GeneratedValue
        {
            Kind = GeneratedValueKind.String,
            TypeName = TypeNames.For(typeof(string)),
            TextValue = values[variant % values.Length]
        };
    }

    private static bool IsInteger(Type type) =>
        type == typeof(byte) || type == typeof(sbyte) ||
        type == typeof(short) || type == typeof(ushort) ||
        type == typeof(int) || type == typeof(uint) ||
        type == typeof(long) || type == typeof(ulong) ||
        type == typeof(nint) || type == typeof(nuint);
}

internal static class ReflectionLookup
{
    public static MethodInfo? FindMethod(Assembly assembly, ApiDescriptor descriptor)
    {
        foreach (var type in assembly.GetExportedTypes())
        {
            if (!string.Equals(TypeNames.For(type), descriptor.DeclaringTypeName, StringComparison.Ordinal))
            {
                continue;
            }

            var method = type.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static)
                .FirstOrDefault(candidate =>
                    !candidate.IsSpecialName &&
                    string.Equals(TypeNames.Method(candidate), descriptor.Signature, StringComparison.Ordinal));
            if (method is not null)
            {
                return method;
            }
        }

        return null;
    }

    public static ConstructorInfo? FindConstructor(Assembly assembly, string signature)
    {
        foreach (var type in assembly.GetExportedTypes())
        {
            var constructor = type.GetConstructors(BindingFlags.Public | BindingFlags.Instance)
                .FirstOrDefault(candidate => string.Equals(TypeNames.Method(candidate), signature, StringComparison.Ordinal));
            if (constructor is not null)
            {
                return constructor;
            }
        }

        return null;
    }
}
