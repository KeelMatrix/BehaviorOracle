using System.Collections;
using System.Globalization;
using System.Reflection;
using System.Runtime.CompilerServices;

namespace KeelMatrix.BehaviorOracle;

internal sealed class ObservationLimits
{
    public ObservationLimits(ProbeOptions options)
    {
        MaxDepth = options.MaxObservationDepth;
        MaxNodes = options.MaxObservationNodes;
        MaxCollectionItems = options.MaxCollectionItems;
    }

    public int MaxDepth { get; }
    public int MaxNodes { get; }
    public int MaxCollectionItems { get; }
}

internal sealed class ValueObserver
{
    public static ObservedValue Capture(object? value, Type declaredType, ObservationLimits limits)
    {
        var state = new CaptureState(limits);
        return Capture(value, declaredType, state, 0);
    }

    private static ObservedValue Capture(object? value, Type declaredType, CaptureState state, int depth)
    {
        if (++state.Nodes > state.Limits.MaxNodes)
        {
            return Unrepresentable("observation node budget exceeded");
        }

        if (value is null)
        {
            return new ObservedValue("null", TypeNames.For(declaredType));
        }

        if (depth > state.Limits.MaxDepth)
        {
            return Unrepresentable("observation depth budget exceeded");
        }

        var actualType = value.GetType();
        if (IsSimple(actualType))
        {
            return new ObservedValue(
                Kind: actualType.IsEnum ? "enum" : "scalar",
                TypeName: TypeNames.For(actualType),
                Scalar: Scalar(value, actualType));
        }

        if (!state.Seen.Add(value))
        {
            return Unrepresentable("cyclic observation");
        }

        try
        {
            if (value is Array array)
            {
                var items = new List<ObservedValue>();
                var elementType = actualType.GetElementType()!;
                for (var index = 0; index < array.Length; index++)
                {
                    if (index >= state.Limits.MaxCollectionItems)
                    {
                        return Unrepresentable("collection item budget exceeded");
                    }

                    items.Add(Capture(array.GetValue(index), elementType, state, depth + 1));
                }

                return new ObservedValue("array", TypeNames.For(actualType), Items: items);
            }

            if (value is IDictionary dictionary)
            {
                var items = new List<ObservedValue>();
                var count = 0;
                foreach (DictionaryEntry entry in dictionary)
                {
                    if (count++ >= state.Limits.MaxCollectionItems)
                    {
                        return Unrepresentable("collection item budget exceeded");
                    }

                    var pair = new Dictionary<string, ObservedValue>(StringComparer.Ordinal)
                    {
                        ["key"] = Capture(entry.Key, entry.Key?.GetType() ?? typeof(object), state, depth + 1),
                        ["value"] = Capture(entry.Value, entry.Value?.GetType() ?? typeof(object), state, depth + 1)
                    };
                    items.Add(new ObservedValue("entry", "System.Collections.Generic.KeyValuePair", Members: pair));
                }

                return new ObservedValue("dictionary", TypeNames.For(actualType), Items: items);
            }

            if (value is IEnumerable enumerable && actualType != typeof(string))
            {
                var items = new List<ObservedValue>();
                var count = 0;
                foreach (var item in enumerable)
                {
                    if (count++ >= state.Limits.MaxCollectionItems)
                    {
                        return Unrepresentable("collection item budget exceeded");
                    }

                    items.Add(Capture(item, item?.GetType() ?? typeof(object), state, depth + 1));
                }

                return new ObservedValue("collection", TypeNames.For(actualType), Items: items);
            }

            if (!TypeSupport.IsSupported(actualType))
            {
                return Unrepresentable("returned object is outside the supported observation domain");
            }

            var members = new Dictionary<string, ObservedValue>(StringComparer.Ordinal);
            foreach (var member in TypeSupport.ReadableMembers(actualType))
            {
                object? memberValue;
                try
                {
                    memberValue = member.Member switch
                    {
                        PropertyInfo property => property.GetValue(value),
                        FieldInfo field => field.GetValue(value),
                        _ => throw new InvalidOperationException("unsupported member")
                    };
                }
                catch
                {
                    return Unrepresentable("public member could not be observed");
                }

                members[member.Name] = Capture(memberValue, member.MemberType, state, depth + 1);
            }

            return new ObservedValue("object", TypeNames.For(actualType), Members: members);
        }
        catch
        {
            return Unrepresentable("value could not be represented");
        }
        finally
        {
            state.Seen.Remove(value);
        }
    }

    private static bool IsSimple(Type type) =>
        type.IsEnum ||
        type.IsPrimitive ||
        type == typeof(decimal) ||
        type == typeof(string) ||
        type == typeof(DateTime) ||
        type == typeof(DateTimeOffset) ||
        type == typeof(TimeSpan) ||
        type == typeof(Guid);

    private static string Scalar(object value, Type type) =>
        type.IsEnum
            ? $"{Enum.GetName(type, value)}:{Convert.ToUInt64(value, CultureInfo.InvariantCulture)}"
            : value is string text
                ? text
                : value is char character
                    ? character.ToString()
            : value switch
            {
                IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture) ?? string.Empty,
                _ => string.Empty
            };

    private static ObservedValue Unrepresentable(string reason) =>
        new("unrepresentable", Scalar: reason);

    private sealed class CaptureState
    {
        public CaptureState(ObservationLimits limits)
        {
            Limits = limits;
        }

        public ObservationLimits Limits { get; }
        public int Nodes { get; set; }
        public HashSet<object> Seen { get; } = new(ReferenceEqualityComparer.Instance);
    }
}

internal static class ObservationComparer
{
    public static bool AreEqual(Observation left, Observation right) =>
        left.IsRepresentable &&
        right.IsRepresentable &&
        string.Equals(left.Canonical, right.Canonical, StringComparison.Ordinal);
}
