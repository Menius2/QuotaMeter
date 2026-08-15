using System.Globalization;
using System.Net.Http.Headers;
using System.Text.Json;

namespace QuotaMeterWindows;

internal sealed class UsageClient
{
    private static readonly HttpClient Client = new()
    {
        Timeout = TimeSpan.FromSeconds(20)
    };

    public async Task<UsageSnapshot> FetchAsync(AppSettings settings, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(settings.ApiKey))
        {
            throw new InvalidOperationException("请先输入 API Key。");
        }

        if (!Uri.TryCreate(settings.BaseUrl.Trim(), UriKind.Absolute, out var baseUri) ||
            baseUri.Scheme is not ("http" or "https"))
        {
            throw new InvalidOperationException("Base URL 无效。");
        }

        var isOpenRouter = settings.ProviderPreset.Equals("openRouter", StringComparison.OrdinalIgnoreCase) ||
                           baseUri.Host.Contains("openrouter.ai", StringComparison.OrdinalIgnoreCase);
        var endpoint = isOpenRouter
            ? BuildOpenRouterUri(baseUri)
            : BuildCompatibleUri(baseUri, settings.UsagePath);

        using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", settings.ApiKey);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

        using var response = await Client.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                string.IsNullOrWhiteSpace(body)
                    ? $"请求失败：HTTP {(int)response.StatusCode}"
                    : $"请求失败：{ExtractMessage(body)}"
            );
        }

        using var document = JsonDocument.Parse(body);
        return isOpenRouter
            ? ParseOpenRouter(document.RootElement)
            : ParseCompatible(document.RootElement);
    }

    private static Uri BuildCompatibleUri(Uri baseUri, string usagePath)
    {
        var path = baseUri.AbsolutePath.TrimEnd('/');
        if (!path.EndsWith("/v1", StringComparison.OrdinalIgnoreCase))
        {
            path += "/v1";
        }

        var suffix = string.IsNullOrWhiteSpace(usagePath) ? "/usage" : usagePath.Trim();
        if (!suffix.StartsWith('/'))
        {
            suffix = "/" + suffix;
        }

        var builder = new UriBuilder(baseUri)
        {
            Path = path + suffix.TrimEnd('/'),
            Query = $"start_date={DateTime.Now.Date.AddDays(-3650):yyyy-MM-dd}" +
                    $"&end_date={DateTime.Now:yyyy-MM-dd}" +
                    $"&timezone={Uri.EscapeDataString(TimeZoneInfo.Local.Id)}"
        };
        return builder.Uri;
    }

    private static Uri BuildOpenRouterUri(Uri baseUri)
    {
        var path = baseUri.AbsolutePath.TrimEnd('/');
        if (string.IsNullOrWhiteSpace(path))
        {
            path = "/api/v1";
        }
        else if (path.Equals("/api", StringComparison.OrdinalIgnoreCase))
        {
            path += "/v1";
        }
        else if (!path.EndsWith("/v1", StringComparison.OrdinalIgnoreCase))
        {
            path += "/v1";
        }

        return new UriBuilder(baseUri) { Path = path + "/key" }.Uri;
    }

    private static UsageSnapshot ParseOpenRouter(JsonElement root)
    {
        var data = GetObject(root, "data") ?? root;
        var limit = GetNumber(data, "limit");
        var remaining = GetNumber(data, "limit_remaining", "limitRemaining");
        var total = GetNumber(data, "usage") ?? 0;
        var today = GetNumber(data, "usage_daily", "usageDaily") ?? total;
        var used = limit.HasValue && remaining.HasValue
            ? Math.Max(limit.Value - remaining.Value, 0)
            : total;

        return new UsageSnapshot
        {
            Balance = remaining ?? limit,
            TodayAmount = today,
            TotalAmount = total,
            Unit = "credits",
            Mode = "openrouter",
            PlanName = GetString(data, "label") ?? "OpenRouter",
            IsValid = true
        };
    }

    private static UsageSnapshot ParseCompatible(JsonElement root)
    {
        var data = LooksLikeUsage(root)
            ? root
            : GetObject(root, "data") ?? GetObject(root, "result") ?? root;
        var quota = GetObject(data, "quota");
        var usage = GetObject(data, "usage");
        var today = usage is { } usageObject ? GetObject(usageObject, "today") : null;
        var total = usage is { } totalObject ? GetObject(totalObject, "total") : null;

        var balance = GetNumber(data, "remaining", "balance") ??
                      (quota is { } quotaObject ? GetNumber(quotaObject, "remaining") : null);
        var todayTokens = today is { } todayObject
            ? GetNumber(todayObject, "total_tokens", "totalTokens")
            : null;
        var totalTokens = total is { } totalObjectValue
            ? GetNumber(totalObjectValue, "total_tokens", "totalTokens")
            : null;
        var todayAmount = today is { } todayAmountObject
            ? GetNumber(todayAmountObject, "actual_cost", "actualCost", "cost") ?? todayTokens
            : null;
        var totalAmount = total is { } totalAmountObject
            ? GetNumber(totalAmountObject, "actual_cost", "actualCost", "cost") ?? totalTokens
            : null;

        return new UsageSnapshot
        {
            Balance = balance,
            TodayAmount = todayAmount,
            TotalAmount = totalAmount,
            TodayTokens = todayTokens,
            TotalTokens = totalTokens,
            TodayRequests = today is { } todayRequests ? GetNumber(todayRequests, "requests") : null,
            TotalRequests = total is { } totalRequests ? GetNumber(totalRequests, "requests") : null,
            Unit = GetString(data, "unit") ?? "",
            Mode = GetString(data, "mode") ?? "",
            PlanName = GetString(data, "plan_name", "planName") ?? "兼容接口",
            IsValid = GetBool(data, "is_valid", "isValid"),
            DailyUsage = ParseDailyUsage(data)
        };
    }

    private static List<DailyUsageRow> ParseDailyUsage(JsonElement data)
    {
        var rows = new List<DailyUsageRow>();
        if (!TryGet(data, out var daily, "daily_usage", "dailyUsage") || daily.ValueKind != JsonValueKind.Array)
        {
            return rows;
        }

        foreach (var item in daily.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object)
            {
                continue;
            }

            rows.Add(new DailyUsageRow
            {
                Date = GetString(item, "date") ?? "",
                Requests = GetNumber(item, "requests"),
                InputTokens = GetNumber(item, "input_tokens", "inputTokens"),
                OutputTokens = GetNumber(item, "output_tokens", "outputTokens"),
                TotalTokens = GetNumber(item, "total_tokens", "totalTokens"),
                Cost = GetNumber(item, "actual_cost", "actualCost", "cost")
            });
        }

        return rows.OrderByDescending(row => row.Date).Take(7).ToList();
    }

    private static bool LooksLikeUsage(JsonElement value)
    {
        return value.ValueKind == JsonValueKind.Object &&
               (TryGet(value, out _, "balance", "remaining", "quota", "usage", "daily_usage", "dailyUsage"));
    }

    private static JsonElement? GetObject(JsonElement value, params string[] names)
    {
        return TryGet(value, out var result, names) && result.ValueKind == JsonValueKind.Object
            ? result
            : null;
    }

    private static string? GetString(JsonElement value, params string[] names)
    {
        return TryGet(value, out var result, names) && result.ValueKind == JsonValueKind.String
            ? result.GetString()
            : null;
    }

    private static bool? GetBool(JsonElement value, params string[] names)
    {
        if (!TryGet(value, out var result, names))
        {
            return null;
        }

        if (result.ValueKind == JsonValueKind.True || result.ValueKind == JsonValueKind.False)
        {
            return result.GetBoolean();
        }

        return bool.TryParse(result.ToString(), out var parsed) ? parsed : null;
    }

    private static double? GetNumber(JsonElement value, params string[] names)
    {
        if (!TryGet(value, out var result, names))
        {
            return null;
        }

        if (result.ValueKind == JsonValueKind.Number && result.TryGetDouble(out var number))
        {
            return number;
        }

        return double.TryParse(
            result.ToString(),
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out var parsed
        ) ? parsed : null;
    }

    private static bool TryGet(JsonElement value, out JsonElement result, params string[] names)
    {
        foreach (var name in names)
        {
            if (value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out result))
            {
                return true;
            }
        }

        result = default;
        return false;
    }

    private static string ExtractMessage(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            var error = GetObject(root, "error");
            return GetString(error ?? root, "message") ??
                   GetString(root, "message") ??
                   body;
        }
        catch
        {
            return body;
        }
    }
}
