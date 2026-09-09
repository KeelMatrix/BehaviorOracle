using System.Globalization;

namespace BehaviorOracleCorpus;

public enum CustomerTier
{
    Basic = 0,
    Premium = 1,
    Enterprise = 2
}

public sealed class Order
{
    public int Total { get; set; }

    public string? Label { get; set; }
}

public sealed class Calculator
{
    public int Offset { get; }

    public int Add(int left, int right) => left + right + Offset;

    public int Apply(Order order) => order.Total + Offset >= 100 ? order.Total : 0;
}

public static class SemanticChanges
{
    public static int Bucket(int value) => value >= 100 ? 1 : 0;

    public static string Normalize(string? value) => value?.Trim() ?? "default";

    public static int Parse(int value) => value < 0
        ? throw new ArgumentOutOfRangeException(nameof(value))
        : value;

    public static int[] Ordered() => [1, 2, 3];

    public static int Mutate(List<int> values)
    {
        values.Add(99);
        return values.Count;
    }

    public static async Task<int> AsyncResult(int value) => await Task.FromResult(value + 1);

    public static async ValueTask<int> ValueTaskResult(int value) => await ValueTask.FromResult(value + 1);

    public static string Nondeterministic() => Guid.NewGuid().ToString("D");

    public static DateTime Today() => DateTime.Today;

    public static int ReadReferencedEnvironment() => HiddenStateBridge.ReadEnvironment();

    public static string ReadExternal(Stream stream) => stream.Length.ToString(CultureInfo.InvariantCulture);

    public static int TierValue(CustomerTier tier) => (int)tier;
}
