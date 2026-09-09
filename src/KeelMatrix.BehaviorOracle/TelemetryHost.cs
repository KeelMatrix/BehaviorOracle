using KeelMatrix.Telemetry;

namespace KeelMatrix.BehaviorOracle;

internal static class TelemetryHost
{
    private static readonly Client Client = new("BehaviorOracle", typeof(TelemetryHost));

    public static void TrackSuccessfulComparison()
    {
        Client.TrackActivation();
        Client.TrackHeartbeat();
    }
}
