using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace QuotaMeterWindows;

/// <summary>
/// Tracks decreases from balance-only APIs locally. A balance endpoint cannot
/// reveal historical token or request counts, so this records only observed
/// monetary/credit consumption after the first successful refresh.
/// </summary>
internal sealed class BalanceUsageTracker
{
    private static readonly string StatePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "QuotaMeter",
        "balance-usage.json"
    );

    public UsageSnapshot Observe(UsageSnapshot snapshot, AppSettings settings)
    {
        if (snapshot.TodayAmount.HasValue || snapshot.TotalAmount.HasValue ||
            snapshot.TodayTokens.HasValue || snapshot.TotalTokens.HasValue ||
            snapshot.DailyUsage.Count > 0 || !snapshot.Balance.HasValue)
        {
            return snapshot;
        }

        var key = MakeKey(settings);
        var states = LoadStates();
        var unit = snapshot.Unit.ToUpperInvariant();
        var today = DateTime.Now.ToString("yyyy-MM-dd");
        if (!states.TryGetValue(key, out var state) || !state.Unit.Equals(unit, StringComparison.Ordinal))
        {
            states[key] = new BalanceState { Unit = unit, LastBalance = snapshot.Balance.Value };
            SaveStates(states);
            return snapshot;
        }

        var decrease = Math.Max(state.LastBalance - snapshot.Balance.Value, 0);
        if (decrease > 0)
        {
            state.TotalSpent += decrease;
            state.DailySpent[today] = state.DailySpent.GetValueOrDefault(today) + decrease;
        }
        state.LastBalance = snapshot.Balance.Value;
        states[key] = state;
        SaveStates(states);

        var daily = state.DailySpent
            .Where(entry => entry.Value > 0)
            .OrderByDescending(entry => entry.Key)
            .Take(7)
            .Select(entry => new DailyUsageRow { Date = entry.Key, Cost = entry.Value })
            .ToList();

        return snapshot with
        {
            TodayAmount = state.DailySpent.GetValueOrDefault(today),
            TotalAmount = state.TotalSpent,
            Mode = string.IsNullOrWhiteSpace(snapshot.Mode) ? "compatible-local" : snapshot.Mode + "-local",
            DailyUsage = daily
        };
    }

    private static string MakeKey(AppSettings settings)
    {
        var source = $"{settings.BaseUrl.Trim().ToLowerInvariant()}|{settings.ProviderPreset}|{settings.ApiKey}";
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(source))).ToLowerInvariant();
    }

    private static Dictionary<string, BalanceState> LoadStates()
    {
        try
        {
            return File.Exists(StatePath)
                ? JsonSerializer.Deserialize<Dictionary<string, BalanceState>>(File.ReadAllText(StatePath)) ?? []
                : [];
        }
        catch
        {
            return [];
        }
    }

    private static void SaveStates(Dictionary<string, BalanceState> states)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(StatePath)!);
            File.WriteAllText(StatePath, JsonSerializer.Serialize(states));
        }
        catch
        {
            // Usage tracking is optional and must never break the monitor.
        }
    }

    private sealed class BalanceState
    {
        public string Unit { get; set; } = "";
        public double LastBalance { get; set; }
        public double TotalSpent { get; set; }
        public Dictionary<string, double> DailySpent { get; set; } = [];
    }
}
