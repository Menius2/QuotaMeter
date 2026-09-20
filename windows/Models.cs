namespace QuotaMeterWindows;

internal sealed class AppSettings
{
    public string BaseUrl { get; set; } = "";
    public string ApiKey { get; set; } = "";
    public string PlatformToken { get; set; } = "";
    public string ProviderPreset { get; set; } = "auto";
    public string UsagePath { get; set; } = "/v1/usage";
    public int RefreshIntervalSeconds { get; set; } = 30;
}

internal sealed class UsageSnapshot
{
    public double? Balance { get; init; }
    public double? TodayAmount { get; init; }
    public double? TotalAmount { get; init; }
    public double? TodayTokens { get; init; }
    public double? TotalTokens { get; init; }
    public double? TodayRequests { get; init; }
    public double? TotalRequests { get; init; }
    public string Unit { get; init; } = "";
    public string Mode { get; init; } = "";
    public string PlanName { get; init; } = "";
    public bool? IsValid { get; init; }
    public List<DailyUsageRow> DailyUsage { get; init; } = [];
}

internal sealed class DailyUsageRow
{
    public string Date { get; init; } = "";
    public double? Requests { get; init; }
    public double? InputTokens { get; init; }
    public double? OutputTokens { get; init; }
    public double? TotalTokens { get; init; }
    public double? Cost { get; init; }
}
