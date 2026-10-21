using System.Globalization;

namespace QuotaMeterWindows;

internal static class UsageDisplay
{
    private static readonly CultureInfo Numbers = CultureInfo.InvariantCulture;
    public static string Count(double? value) => value is { } n && double.IsFinite(n) ? n.ToString("N0", Numbers) : "—";
    public static string Money(double? value, string unit)
    {
        if (value is not { } n || !double.IsFinite(n)) return "—";
        var amount = n.ToString("#,##0.00##", Numbers);
        return unit.ToUpperInvariant() switch
        {
            "USD" or "DOLLARS" => "$" + amount,
            "CNY" or "RMB" => "¥" + amount,
            "EUR" => "€" + amount,
            "CREDITS" or "CREDIT" => amount + " credits",
            "" => amount,
            _ => amount + " " + unit
        };
    }
    public static string SummaryTitle(UsageSnapshot snapshot, bool today)
    {
        var prefix = today ? "今日" : "累计";
        if (snapshot.IsLocal) return prefix + "消耗（本机）";
        return prefix + (snapshot.HasTokens ? " token" : "使用");
    }
    public static string SummaryValue(UsageSnapshot snapshot, bool today) => snapshot.HasTokens
        ? Count(today ? snapshot.TodayTokens : snapshot.TotalTokens)
        : Money(today ? snapshot.TodayAmount : snapshot.TotalAmount, snapshot.Unit);
    public static string WindowName(string value) => value switch
    {
        "5h" => "5 小时", "1d" or "daily" => "每日", "7d" or "weekly" => "每周",
        "month" or "monthly" => "每月", "key" => "密钥额度", _ => value
    };
}
