using System.Collections;
using System.Globalization;
using System.Reflection;

namespace KeelMatrix.BehaviorOracle;

internal sealed class ValueInstantiationException : Exception
{
    public ValueInstantiationException(string message)
        : base(message)
    {
    }
}

internal static class ValueInstantiator
{
    public static object? Create(GeneratedValue value, Type expectedType, int depth = 0)
    {
        if (depth > 8)
        {
            throw new ValueInstantiationException("input graph depth exceeded");
        }

        if (value.Kind == GeneratedValueKind.Null)
        {
            if (expectedType.IsValueType && Nullable.GetUnderlyingType(expectedType) is null)
            {
                throw new ValueInstantiationException("null was generated for a non-nullable value");
            }

            return null;
        }

        if (Nullable.GetUnderlyingType(expectedType) is Type nullableType)
        {
            return Create(value, nullableType, depth + 1);
        }

        if (expectedType == typeof(string))
        {
            return value.TextValue;
        }

        if (expectedType == typeof(bool))
        {
            return value.BooleanValue;
        }

        if (expectedType == typeof(char))
        {
            return Convert.ToChar(value.IntegerValue, CultureInfo.InvariantCulture);
        }

        if (expectedType.IsEnum)
        {
            if (value.TextValue is null)
            {
                throw new ValueInstantiationException("enum name is missing");
            }

            return Enum.Parse(expectedType, value.TextValue, ignoreCase: false);
        }

        if (expectedType == typeof(decimal))
        {
            return decimal.Parse(value.TextValue ?? "0", CultureInfo.InvariantCulture);
        }

        if (expectedType == typeof(float))
        {
            return Convert.ToSingle(value.FloatingPointValue, CultureInfo.InvariantCulture);
        }

        if (expectedType == typeof(double))
        {
            return value.FloatingPointValue;
        }

        if (IsInteger(expectedType))
        {
            return Convert.ChangeType(value.IntegerValue, expectedType, CultureInfo.InvariantCulture);
        }

        if (expectedType == typeof(DateTime))
        {
            return DateTime.Parse(value.TextValue ?? "2020-01-02T03:04:05Z", CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
        }

        if (expectedType == typeof(DateTimeOffset))
        {
            return DateTimeOffset.Parse(value.TextValue ?? "2020-01-02T03:04:05Z", CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
        }

        if (expectedType == typeof(TimeSpan))
        {
            return TimeSpan.Parse(value.TextValue ?? "00:00:01", CultureInfo.InvariantCulture);
        }

        if (expectedType == typeof(Guid))
        {
            return Guid.Parse(value.TextValue ?? Guid.Empty.ToString());
        }

        if (expectedType.IsArray)
        {
            var items = value.Items ?? [];
            var array = Array.CreateInstance(expectedType.GetElementType()!, items.Count);
            for (var index = 0; index < items.Count; index++)
            {
                array.SetValue(Create(items[index], expectedType.GetElementType()!, depth + 1), index);
            }

            return array;
        }

        if (TypeSupport.TryGetCollectionShape(expectedType, out var elementType, out var keyType, out var valueType))
        {
            return CreateCollection(value, expectedType, elementType, keyType, valueType, depth);
        }

        if (value.Kind != GeneratedValueKind.Object || !TypeSupport.HasConstructiblePublicPath(expectedType))
        {
            throw new ValueInstantiationException($"no object construction path exists for {expectedType.FullName}");
        }

        var instance = Activator.CreateInstance(expectedType) ??
            throw new ValueInstantiationException($"constructor returned null for {expectedType.FullName}");
        foreach (var member in TypeSupport.WritableMembers(expectedType))
        {
            if (value.Members is null || !value.Members.TryGetValue(member.Name, out var generated))
            {
                continue;
            }

            var memberValue = Create(generated, member.MemberType, depth + 1);
            switch (member.Member)
            {
                case PropertyInfo property:
                    property.SetValue(instance, memberValue);
                    break;
                case FieldInfo field:
                    field.SetValue(instance, memberValue);
                    break;
            }
        }

        return instance;
    }

    private static object CreateCollection(
        GeneratedValue value,
        Type expectedType,
        Type? elementType,
        Type? keyType,
        Type? valueType,
        int depth)
    {
        var items = value.Items ?? [];
        if (keyType is not null)
        {
            var dictionaryType = typeof(Dictionary<,>).MakeGenericType(keyType, valueType!);
            var dictionary = Activator.CreateInstance(dictionaryType) ??
                throw new ValueInstantiationException("dictionary construction failed");
            var add = dictionaryType.GetMethod("Add")!;
            foreach (var item in items)
            {
                if (item.Members is null ||
                    !item.Members.TryGetValue("Key", out var key) ||
                    !item.Members.TryGetValue("Value", out var itemValue))
                {
                    throw new ValueInstantiationException("dictionary item is malformed");
                }

                add.Invoke(dictionary,
                [
                    Create(key, keyType, depth + 1),
                    Create(itemValue, valueType!, depth + 1)
                ]);
            }

            return dictionary;
        }

        var concreteType = expectedType.IsInterface || expectedType.IsAbstract
            ? typeof(List<>).MakeGenericType(elementType!)
            : expectedType;
        var collection = Activator.CreateInstance(concreteType) ??
            throw new ValueInstantiationException("collection construction failed");
        var addMethod = concreteType.GetMethod("Add", [elementType!]);
        if (addMethod is null)
        {
            throw new ValueInstantiationException($"collection {concreteType.FullName} has no public Add method");
        }

        foreach (var item in items)
        {
            addMethod.Invoke(collection, [Create(item, elementType!, depth + 1)]);
        }

        return collection;
    }

    private static bool IsInteger(Type type) =>
        type == typeof(byte) || type == typeof(sbyte) ||
        type == typeof(short) || type == typeof(ushort) ||
        type == typeof(int) || type == typeof(uint) ||
        type == typeof(long) || type == typeof(ulong) ||
        type == typeof(nint) || type == typeof(nuint);
}

