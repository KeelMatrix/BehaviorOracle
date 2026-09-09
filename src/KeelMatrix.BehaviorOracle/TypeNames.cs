using System.Reflection;

namespace KeelMatrix.BehaviorOracle;

internal static class TypeNames
{
    public static string For(Type type)
    {
        if (type.IsByRef)
        {
            return For(type.GetElementType()!) + "&";
        }

        if (type.IsPointer)
        {
            return For(type.GetElementType()!) + "*";
        }

        if (type.IsArray)
        {
            return For(type.GetElementType()!) + "[" + new string(',', type.GetArrayRank() - 1) + "]";
        }

        if (type.IsGenericParameter)
        {
            return new string((char)96, type.GenericParameterPosition == 0 ? 1 : 1) +
                type.GenericParameterPosition;
        }

        if (type.IsGenericType)
        {
            var definitionName = type.GetGenericTypeDefinition().FullName!;
            var tick = definitionName.IndexOf((char)96);
            if (tick >= 0)
            {
                definitionName = definitionName[..tick];
            }

            return definitionName + "<" + string.Join(",", type.GetGenericArguments().Select(For)) + ">";
        }

        return type.FullName ?? type.Name;
    }

    public static string Method(MethodBase method)
    {
        var declaringType = TypeForSignature(method.DeclaringType!);
        var parameters = string.Join(",", method.GetParameters().Select(parameter => TypeForSignature(parameter.ParameterType)));
        var returnType = method is MethodInfo info ? TypeForSignature(info.ReturnType) : "System.Void";
        var name = method is ConstructorInfo ? ".ctor" : method.Name;
        var genericArity = method is MethodInfo genericMethod && genericMethod.IsGenericMethodDefinition
            ? new string((char)96, 2) + genericMethod.GetGenericArguments().Length
            : string.Empty;

        return $"{declaringType}::{name}{genericArity}({parameters})->{returnType}";
    }

    private static string TypeForSignature(Type type)
    {
        if (type.IsByRef)
        {
            return TypeForSignature(type.GetElementType()!) + "&";
        }

        if (type.IsPointer)
        {
            return TypeForSignature(type.GetElementType()!) + "*";
        }

        if (type.IsArray)
        {
            return TypeForSignature(type.GetElementType()!) + "[" + new string(',', type.GetArrayRank() - 1) + "]";
        }

        if (type.IsGenericParameter)
        {
            return (type.DeclaringMethod is not null ? new string((char)96, 2) : new string((char)96, 1)) +
                type.GenericParameterPosition;
        }

        if (type.IsGenericType)
        {
            var definitionName = type.GetGenericTypeDefinition().FullName!;
            var tick = definitionName.IndexOf((char)96);
            if (tick >= 0)
            {
                definitionName = definitionName[..tick];
            }

            return definitionName + "<" + string.Join(",", type.GetGenericArguments().Select(TypeForSignature)) + ">";
        }

        return type.FullName ?? type.Name;
    }
}

