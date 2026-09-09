namespace BehaviorOracleCorpus;

public static class HiddenStateBridge
{
    public static int ReadEnvironment() =>
        Environment.GetEnvironmentVariable("BEHAVIOR_ORACLE_HIDDEN")?.Length ?? 0;
}
