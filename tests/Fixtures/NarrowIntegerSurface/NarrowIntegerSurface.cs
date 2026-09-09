using System.Collections;

namespace BehaviorOracle.NarrowIntegerSurface;

public static class NarrowIntegerSurface
{
    public static byte AcceptByte(byte value) => value;

    public static sbyte AcceptSByte(sbyte value) => value;

    public static short AcceptShort(short value) => value;

    public static ushort AcceptUShort(ushort value) => value;

    public static int AcceptInt(int value) => value;

    public static uint AcceptUInt(uint value) => value;

    public static long AcceptLong(long value) => value;

    public static ulong AcceptULong(ulong value) => value;

    public static nint AcceptNInt(nint value) => value;

    public static nuint AcceptNUInt(nuint value) => value;
}

public sealed class ReadOnlyEnumerable : IEnumerable<int>
{
    public IEnumerator<int> GetEnumerator() => Enumerable.Empty<int>().GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
}

public sealed class AddableEnumerable : IEnumerable<int>
{
    private readonly List<int> values = [];

    public void Add(int value) => values.Add(value);

    public IEnumerator<int> GetEnumerator() => values.GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
}
