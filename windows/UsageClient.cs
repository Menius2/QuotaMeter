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

        if (!TryCreateBaseUri(settings.BaseUrl, out var baseUri))
        {
            throw new InvalidOperationException("Base URL 格式无效，请填写完整的 http:// 或 https:// 地址。");
        }

        var dashboardMessage = GetWebDashboardMessage(baseUri);
        if (dashboardMessage is not null)
        {
            throw new InvalidOperationException(dashboardMessage);
        }

        var isDeepSeek = settings.ProviderPreset.Equals("deepSeek", StringComparison.OrdinalIgnoreCase) ||
                         baseUri.Host.Equals("api.deepseek.com", StringComparison.OrdinalIgnoreCase);
        if (isDeepSeek)
        {
            return await FetchDeepSeekAsync(baseUri, settings.ApiKey, settings.PlatformToken, cancellationToken);
        }

        var isOpenRouter = settings.ProviderPreset.Equals("openRouter", StringComparison.OrdinalIgnoreCase) ||
                           baseUri.Host.Contains("openrouter.ai", StringComparison.OrdinalIgnoreCase);
        var endpoints = isOpenRouter
            ? new List<Uri> { BuildOpenRouterUri(baseUri) }
            : BuildCompatibleUriCandidates(baseUri, settings.UsagePath);

        Exception? lastError = null;
        for (var index = 0; index < endpoints.Count; index++)
        {
            var endpoint = endpoints[index];
            try
            {
                var credential = isOpenRouter || string.IsNullOrWhiteSpace(settings.PlatformToken)
                    ? settings.ApiKey
                    : settings.PlatformToken;
                return await FetchSnapshotAsync(endpoint, credential, isOpenRouter, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (RequestFailedException ex) when (index < endpoints.Count - 1)
            {
                lastError = ex;
            }
            catch (TaskCanceledException ex) when (!cancellationToken.IsCancellationRequested && index < endpoints.Count - 1)
            {
                lastError = ex;
            }
            catch (HttpRequestException ex) when (index < endpoints.Count - 1)
            {
                lastError = ex;
            }
        }

        throw lastError ?? new InvalidOperationException("请求失败。");
    }

    private static async Task<UsageSnapshot> FetchSnapshotAsync(
        Uri endpoint,
        string apiKey,
        bool isOpenRouter,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

        using var response = await Client.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var message = ExtractMessage(body);
            if (response.StatusCode is System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden)
            {
                throw new RequestFailedException((int)response.StatusCode,
                    string.IsNullOrWhiteSpace(message) ? "密钥无效或已停用。" : message);
            }

            throw new RequestFailedException((int)response.StatusCode,
                string.IsNullOrWhiteSpace(message)
                    ? $"请求失败：HTTP {(int)response.StatusCode}"
                    : message);
        }

        try
        {
            using var document = JsonDocument.Parse(body);
            return isOpenRouter
                ? ParseOpenRouter(document.RootElement)
                : ParseCompatible(document.RootElement);
        }
        catch (JsonException ex)
        {
            throw new RequestFailedException(null, "无法识别接口返回格式。", ex);
        }
    }

    private static async Task<UsageSnapshot> FetchDeepSeekAsync(
        Uri baseUri,
        string apiKey,
        string platformToken,
        CancellationToken cancellationToken)
    {
        var endpoint = new UriBuilder(baseUri)
        {
            Path = "/user/balance",
            Query = "",
            Fragment = ""
        }.Uri;

        using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

        using var response = await Client.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var message = ExtractMessage(body);
            if (response.StatusCode is System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden)
            {
                throw new RequestFailedException((int)response.StatusCode,
                    string.IsNullOrWhiteSpace(message) ? "DeepSeek API Key 无效或已停用。" : message);
            }

            throw new RequestFailedException((int)response.StatusCode,
                string.IsNullOrWhiteSpace(message)
                    ? $"请求失败：HTTP {(int)response.StatusCode}"
                    : message);
        }

        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            var available = GetBool(root, "is_available", "isAvailable");
            if (!TryGet(root, out var balances, "balance_infos", "balanceInfos") ||
                balances.ValueKind != JsonValueKind.Array)
            {
                throw new RequestFailedException(null, "DeepSeek 返回中没有余额信息。");
            }

            var balanceInfo = balances.EnumerateArray()
                .FirstOrDefault(item =>
                    item.ValueKind == JsonValueKind.Object &&
                    string.Equals(GetString(item, "currency"), "USD", StringComparison.OrdinalIgnoreCase));
            if (balanceInfo.ValueKind != JsonValueKind.Object)
            {
                balanceInfo = balances.EnumerateArray()
                    .FirstOrDefault(item => item.ValueKind == JsonValueKind.Object);
            }

            var balance = GetNumber(balanceInfo, "total_balance", "totalBalance");
            var currency = GetString(balanceInfo, "currency") ?? "credits";
            if (!balance.HasValue)
            {
                throw new RequestFailedException(null, "DeepSeek 返回中没有可识别的余额。");
            }

            var balanceSnapshot = new UsageSnapshot
            {
                Balance = balance,
                Unit = currency.ToUpperInvariant(),
                Mode = "deepseek",
                PlanName = "DeepSeek API",
                IsValid = available ?? true
            };
            if (!string.IsNullOrWhiteSpace(platformToken))
            {
                var platformSnapshot = await FetchDeepSeekPlatformAsync(balanceSnapshot, platformToken, cancellationToken);
                if (platformSnapshot is not null)
                {
                    return platformSnapshot;
                }
            }
            return balanceSnapshot;
        }
        catch (JsonException ex)
        {
            throw new RequestFailedException(null, "无法识别 DeepSeek 返回格式。", ex);
        }
    }

    private static async Task<UsageSnapshot?> FetchDeepSeekPlatformAsync(
        UsageSnapshot balance,
        string platformToken,
        CancellationToken cancellationToken)
    {
        var now = DateTimeOffset.UtcNow;
        var start = now.ToUnixTimeSeconds() - 10L * 365 * 24 * 60 * 60;
        var end = now.ToUnixTimeSeconds();
        var tz = (int)TimeZoneInfo.Local.GetUtcOffset(DateTime.Now).TotalSeconds;
        var query = $"start={start}&end={end}&tz={tz}";
        var amount = await SendPlatformJsonAsync(
            new Uri($"https://platform.deepseek.com/api/v0/usage/by_api_key/amount?{query}"),
            platformToken,
            cancellationToken);
        JsonDocument? cost = null;
        try
        {
            cost = await SendPlatformJsonAsync(
                new Uri($"https://platform.deepseek.com/api/v0/usage/by_api_key/cost?{query}"),
                platformToken,
                cancellationToken);
        }
        catch (RequestFailedException)
        {
            // Token usage remains useful if the optional cost endpoint changes.
        }

        var rows = new Dictionary<string, PlatformAccumulator>(StringComparer.Ordinal);
        var amountData = GetObject(GetObject(amount.RootElement, "data"), "biz_data", "bizData") ??
                         GetObject(amount.RootElement, "data") ?? amount.RootElement;
        var series = GetArray(amountData, "series");
        if (series is not null)
        {
            foreach (var modelSeries in series.Value.EnumerateArray())
            {
                var buckets = GetArray(modelSeries, "buckets");
                if (buckets is null) continue;
                foreach (var bucket in buckets.Value.EnumerateArray())
                {
                    var usage = GetObject(bucket, "usage");
                    var date = PlatformDate(bucket, "time", "timestamp");
                    if (usage is null || date is null) continue;
                    var hit = GetNumber(usage.Value, "PROMPT_CACHE_HIT_TOKEN", "prompt_cache_hit_tokens") ?? 0;
                    var miss = GetNumber(usage.Value, "PROMPT_CACHE_MISS_TOKEN", "prompt_cache_miss_tokens") ?? 0;
                    var output = GetNumber(usage.Value, "RESPONSE_TOKEN", "response_tokens", "output_tokens") ?? 0;
                    var requests = GetNumber(usage.Value, "REQUEST", "requests", "request_count") ?? 0;
                    if (!rows.TryGetValue(date, out var row)) row = new PlatformAccumulator();
                    row.InputTokens += hit + miss;
                    row.CacheReadTokens += hit;
                    row.OutputTokens += output;
                    row.TotalTokens += hit + miss + output;
                    row.Requests += requests;
                    rows[date] = row;
                }
            }
        }

        if (cost is not null)
        {
            var costData = GetObject(cost.RootElement, "data");
            costData = GetObject(costData, "biz_data", "bizData") ?? costData;
            var currencies = GetArray(costData, "data");
            var costSeries = currencies is not null && currencies.Value.GetArrayLength() > 0
                ? GetArray(currencies.Value[0], "series")
                : null;
            if (costSeries is not null)
            {
                foreach (var modelSeries in costSeries.Value.EnumerateArray())
                {
                    var buckets = GetArray(modelSeries, "buckets");
                    if (buckets is null) continue;
                    foreach (var bucket in buckets.Value.EnumerateArray())
                    {
                        var date = PlatformDate(bucket, "time", "timestamp");
                        var value = GetNumber(bucket, "cost", "amount");
                        if (date is null || !value.HasValue) continue;
                        if (!rows.TryGetValue(date, out var row)) row = new PlatformAccumulator();
                        row.Cost += value.Value;
                        rows[date] = row;
                    }
                }
            }
        }

        if (rows.Count == 0) return null;
        var today = DateTime.Now.ToString("yyyy-MM-dd");
        rows.TryGetValue(today, out var todayRow);
        todayRow ??= new PlatformAccumulator();
        var total = new PlatformAccumulator();
        foreach (var row in rows.Values)
        {
            total.InputTokens += row.InputTokens;
            total.OutputTokens += row.OutputTokens;
            total.TotalTokens += row.TotalTokens;
            total.Requests += row.Requests;
            total.CacheReadTokens += row.CacheReadTokens;
            total.Cost += row.Cost;
        }
        var daily = rows.OrderByDescending(item => item.Key).Take(90).Select(item => new DailyUsageRow
        {
            Date = item.Key,
            Requests = item.Value.Requests,
            InputTokens = item.Value.InputTokens,
            OutputTokens = item.Value.OutputTokens,
            TotalTokens = item.Value.TotalTokens,
            Cost = item.Value.Cost
        }).ToList();
        return new UsageSnapshot
        {
            Balance = balance.Balance,
            TodayAmount = todayRow.Cost,
            TotalAmount = total.Cost,
            TodayTokens = todayRow.TotalTokens,
            TotalTokens = total.TotalTokens,
            TodayRequests = todayRow.Requests,
            TotalRequests = total.Requests,
            Unit = balance.Unit,
            Mode = "deepseek-platform",
            PlanName = "DeepSeek API（官网同步）",
            IsValid = balance.IsValid,
            DailyUsage = daily
        };
    }

    private static async Task<JsonDocument> SendPlatformJsonAsync(Uri endpoint, string token, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.Add("x-client-platform", "web");
        using var response = await Client.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new RequestFailedException((int)response.StatusCode, ExtractMessage(body));
        }
        return JsonDocument.Parse(body);
    }

    private static string? PlatformDate(JsonElement value, params string[] names)
    {
        var timestamp = GetNumber(value, names);
        return timestamp.HasValue
            ? DateTimeOffset.FromUnixTimeSeconds((long)timestamp.Value).ToLocalTime().ToString("yyyy-MM-dd")
            : null;
    }

    private sealed class PlatformAccumulator
    {
        public double InputTokens;
        public double OutputTokens;
        public double TotalTokens;
        public double Requests;
        public double CacheReadTokens;
        public double Cost;
    }


    private static bool TryCreateBaseUri(string raw, out Uri baseUri)
    {
        var value = raw.Trim();
        value = string.Concat(value.Where(character => !char.IsWhiteSpace(character) && !char.IsControl(character)));
        value = value
            .Replace("\uFEFF", "", StringComparison.Ordinal)
            .Replace("\u200B", "", StringComparison.Ordinal)
            .Replace('：', ':')
            .Replace('／', '/');

        if (value.Length >= 2 &&
            ((value.StartsWith('"') && value.EndsWith('"')) ||
             (value.StartsWith('\'') && value.EndsWith('\'')) ||
             (value.StartsWith('<') && value.EndsWith('>'))))
        {
            value = value[1..^1];
        }

        if (!string.IsNullOrWhiteSpace(value) && !value.Contains("://", StringComparison.Ordinal))
        {
            value = "https://" + value;
        }
        value = value.TrimEnd('/');

        if (!Uri.TryCreate(value, UriKind.Absolute, out var parsedUri) ||
            parsedUri.Scheme is not ("http" or "https") ||
            string.IsNullOrWhiteSpace(parsedUri.Host))
        {
            baseUri = null!;
            return false;
        }

        baseUri = parsedUri;
        if (baseUri.Host.Equals("platform.deepseek.com", StringComparison.OrdinalIgnoreCase))
        {
            baseUri = new Uri("https://api.deepseek.com");
        }

        return true;
    }

    private static string? GetWebDashboardMessage(Uri baseUri)
    {
        return baseUri.Host.ToLowerInvariant() switch
        {
            "platform.openai.com" =>
                "这是 OpenAI 网页地址，不是 API 地址。请填写 API 根地址；组织用量查询还需要 Admin API Key。",
            "console.anthropic.com" =>
                "这是 Anthropic 网页地址，不是 API 地址。请填写 API 根地址；组织用量查询需要 Admin API Key。",
            "aistudio.google.com" =>
                "这是 Google AI Studio 网页地址，不是 API 地址。普通 Gemini API Key 不能直接查询账户累计用量。",
            "console.groq.com" =>
                "这是 Groq 网页地址，不是 API 地址。请填写实际 API 根地址或中转站 Usage 接口。",
            _ => null
        };
    }

    private static List<Uri> BuildCompatibleUriCandidates(Uri baseUri, string usagePath)
    {
        var baseUris = new List<Uri> { baseUri };
        if (!string.IsNullOrWhiteSpace(baseUri.AbsolutePath.Trim('/')))
        {
            var root = BuildRootUri(baseUri);
            if (root is not null)
            {
                baseUris.Add(root);
            }
        }

        var paths = new[]
        {
            NormalizePath(usagePath),
            "/v1/usage",
            "/usage",
            "/api/usage",
            "/api/v1/usage",
            "/v1/user/usage",
            "/user/usage",
            "/v1/account/usage",
            "/account/usage",
            "/billing/usage",
            "/v1/dashboard/billing/usage",
            "/v1/organization/usage/completions",
            "/v1/balance",
            "/balance",
            "/api/balance",
            "/user/balance",
            "/api/user/balance"
        };
        var candidates = new List<Uri>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var candidateBaseUri in baseUris)
        {
            foreach (var path in paths)
            {
                var candidate = BuildCompatibleUri(candidateBaseUri, path);
                if (seen.Add(candidate.AbsoluteUri))
                {
                    candidates.Add(candidate);
                }
            }
        }

        return candidates;
    }

    private static Uri BuildCompatibleUri(Uri baseUri, string usagePath)
    {
        if (Uri.TryCreate(usagePath, UriKind.Absolute, out var absolute) &&
            absolute.Scheme is "http" or "https")
        {
            return absolute;
        }
        var path = AppendPath(baseUri.AbsolutePath, NormalizePath(usagePath));
        const int days = 90;
        var startDate = DateTime.Now.Date.AddDays(-days).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var endDate = DateTime.Now.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var timezone = TimeZoneInfo.TryConvertWindowsIdToIanaId(
            TimeZoneInfo.Local.Id,
            out var ianaTimeZone
        ) ? ianaTimeZone! : TimeZoneInfo.Local.Id;

        var builder = new UriBuilder(baseUri) { Path = path };
        if (path.Contains("usage", StringComparison.OrdinalIgnoreCase))
        {
            builder.Query = $"start_date={startDate}" +
                            $"&end_date={endDate}" +
                            $"&days={days}" +
                            $"&timezone={Uri.EscapeDataString(timezone)}";
        }
        else
        {
            builder.Query = "";
        }
        return builder.Uri;
    }

    private static string NormalizePath(string raw)
    {
        var path = string.IsNullOrWhiteSpace(raw) ? "/v1/usage" : raw.Trim();
        if (!path.StartsWith('/'))
        {
            path = "/" + path;
        }

        return path.TrimEnd('/');
    }

    private static string AppendPath(string basePath, string endpointPath)
    {
        var normalizedBase = string.IsNullOrWhiteSpace(basePath)
            ? ""
            : "/" + basePath.Trim('/');
        var normalizedEndpoint = "/" + endpointPath.Trim('/');

        if (string.IsNullOrWhiteSpace(normalizedBase))
        {
            return normalizedEndpoint;
        }
        if (normalizedEndpoint.Equals(normalizedBase, StringComparison.OrdinalIgnoreCase) ||
            normalizedEndpoint.StartsWith(normalizedBase + "/", StringComparison.OrdinalIgnoreCase))
        {
            return normalizedEndpoint;
        }

        return normalizedBase + normalizedEndpoint;
    }

    private static Uri? BuildRootUri(Uri baseUri)
    {
        var builder = new UriBuilder(baseUri)
        {
            Path = "",
            Query = "",
            Fragment = ""
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
        if (!LooksLikeUsage(data))
        {
            throw new RequestFailedException(null, "无法识别接口返回格式。");
        }

        var quota = GetObject(data, "quota", "limits", "credit");
        var usage = GetObject(data, "usage", "usage_summary", "usageSummary");
        var today = usage is { } usageObject
            ? GetObject(usageObject, "today", "daily", "current_day")
            : null;
        today ??= GetObject(data, "today", "today_usage", "todayUsage");
        var total = usage is { } totalObject
            ? GetObject(totalObject, "total", "all_time", "allTime", "cumulative")
            : null;
        total ??= GetObject(data, "total", "total_usage", "totalUsage", "cumulative_usage", "cumulativeUsage");

        var balance = GetNumber(
                          data,
                          "remaining",
                          "balance",
                          "remaining_balance",
                          "credit_balance",
                          "credits",
                          "total_balance",
                          "available_balance",
                          "available_credit",
                          "available_credits"
                      ) ??
                      (quota is { } quotaObject
                          ? GetNumber(quotaObject, "remaining", "balance", "total_balance", "available_balance")
                          : null);
        var todayTokens = today is { } todayObject
            ? GetNumber(todayObject, "total_tokens", "totalTokens", "tokens", "token_count", "total_token_count", "tokens_used")
            : null;
        var totalTokens = total is { } totalObjectValue
            ? GetNumber(totalObjectValue, "total_tokens", "totalTokens", "tokens", "token_count", "total_token_count", "tokens_used")
            : null;
        var todayAmount = today is { } todayAmountObject
            ? GetNumber(todayAmountObject, "actual_cost", "actualCost", "cost", "total_cost", "amount", "spent", "usage_amount") ?? todayTokens
            : null;
        var totalAmount = total is { } totalAmountObject
            ? GetNumber(totalAmountObject, "actual_cost", "actualCost", "cost", "total_cost", "amount", "spent", "usage_amount") ?? totalTokens
            : null;
        var dailyRows = ParseDailyUsage(data);
        var derivedToday = AggregateDaily(dailyRows.Where(row => row.Date == DateTime.Now.ToString("yyyy-MM-dd")));
        var derivedTotal = AggregateDaily(dailyRows);

        return new UsageSnapshot
        {
            Balance = balance,
            TodayAmount = todayAmount ?? derivedToday.Cost,
            TotalAmount = totalAmount ?? derivedTotal.Cost,
            TodayTokens = todayTokens ?? derivedToday.TotalTokens,
            TotalTokens = totalTokens ?? derivedTotal.TotalTokens,
            TodayRequests = today is { } todayRequests
                ? GetNumber(todayRequests, "requests", "request_count", "requests_count", "num_model_requests", "api_calls", "calls")
                : derivedToday.Requests,
            TotalRequests = total is { } totalRequests
                ? GetNumber(totalRequests, "requests", "request_count", "requests_count", "num_model_requests", "api_calls", "calls")
                : derivedTotal.Requests,
            Unit = GetString(data, "unit", "currency", "currency_code") ?? "",
            Mode = GetString(data, "mode", "provider", "provider_name") ?? "",
            PlanName = GetString(data, "plan_name", "planName", "plan", "label") ?? "兼容接口",
            IsValid = GetBool(data, "is_valid", "isValid", "valid", "available", "is_available"),
            DailyUsage = dailyRows
        };
    }

    private static DailyUsageRow AggregateDaily(IEnumerable<DailyUsageRow> rows)
    {
        var list = rows.ToList();
        return new DailyUsageRow
        {
            Requests = list.Any(row => row.Requests.HasValue) ? list.Sum(row => row.Requests ?? 0) : null,
            InputTokens = list.Any(row => row.InputTokens.HasValue) ? list.Sum(row => row.InputTokens ?? 0) : null,
            OutputTokens = list.Any(row => row.OutputTokens.HasValue) ? list.Sum(row => row.OutputTokens ?? 0) : null,
            TotalTokens = list.Any(row => row.TotalTokens.HasValue) ? list.Sum(row => row.TotalTokens ?? 0) : null,
            Cost = list.Any(row => row.Cost.HasValue) ? list.Sum(row => row.Cost ?? 0) : null
        };
    }

    private static List<DailyUsageRow> ParseDailyUsage(JsonElement data)
    {
        var rows = new List<DailyUsageRow>();
        if (!TryGet(data, out var daily, "daily_usage", "dailyUsage", "records", "daily", "items") ||
            daily.ValueKind != JsonValueKind.Array)
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
                Date = GetDateString(item, "date", "day", "period", "start_date", "startDate", "start_time", "startTime", "timestamp") ?? "",
                Requests = GetNumber(item, "requests", "request_count", "requests_count", "num_model_requests", "api_calls", "calls"),
                InputTokens = GetNumber(item, "input_tokens", "inputTokens", "prompt_tokens", "prompt_token_count", "input_token_count"),
                OutputTokens = GetNumber(item, "output_tokens", "outputTokens", "completion_tokens", "generated_tokens", "output_token_count"),
                TotalTokens = GetNumber(item, "total_tokens", "totalTokens", "tokens", "token_count", "total_token_count", "tokens_used"),
                Cost = GetNumber(item, "actual_cost", "actualCost", "cost", "amount", "spent")
            });
        }

        return rows.OrderByDescending(row => row.Date).Take(7).ToList();
    }

    private static bool LooksLikeUsage(JsonElement value)
    {
        return value.ValueKind == JsonValueKind.Object &&
               (TryGet(
                   value,
                   out _,
                   "balance",
                   "remaining",
                   "remaining_balance",
                   "credit_balance",
                   "credits",
                   "total_balance",
                   "available_balance",
                   "available_credit",
                   "quota",
                   "usage",
                   "daily_usage",
                   "dailyUsage",
                   "records",
                   "today_usage",
                   "total_usage"
               ));
    }

    private static JsonElement? GetObject(JsonElement value, params string[] names)
    {
        return TryGet(value, out var result, names) && result.ValueKind == JsonValueKind.Object
            ? result
            : null;
    }

    private static JsonElement? GetObject(JsonElement? value, params string[] names) =>
        value.HasValue ? GetObject(value.Value, names) : null;

    private static JsonElement? GetArray(JsonElement value, params string[] names)
    {
        return TryGet(value, out var result, names) && result.ValueKind == JsonValueKind.Array
            ? result
            : null;
    }

    private static JsonElement? GetArray(JsonElement? value, params string[] names) =>
        value.HasValue ? GetArray(value.Value, names) : null;

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

    private static string? GetDateString(JsonElement value, params string[] names)
    {
        if (!TryGet(value, out var result, names)) return null;
        if (result.ValueKind == JsonValueKind.String) return result.GetString();
        if (GetNumber(value, names) is { } timestamp)
        {
            return DateTimeOffset.FromUnixTimeSeconds((long)timestamp).ToLocalTime().ToString("yyyy-MM-dd");
        }
        return null;
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

    private sealed class RequestFailedException : InvalidOperationException
    {
        public RequestFailedException(int? statusCode, string message, Exception? innerException = null)
            : base(message, innerException)
        {
            StatusCode = statusCode;
        }

        public int? StatusCode { get; }

        public bool IsUnauthorized => StatusCode is 401 or 403;
    }

    private static bool TryGet(JsonElement value, out JsonElement result, params string[] names)
    {
        foreach (var name in names)
        {
            if (value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out result))
            {
                return true;
            }

            if (value.ValueKind == JsonValueKind.Object)
            {
                var normalizedName = NormalizeFieldName(name);
                foreach (var property in value.EnumerateObject())
                {
                    if (NormalizeFieldName(property.Name).Equals(normalizedName, StringComparison.Ordinal))
                    {
                        result = property.Value;
                        return true;
                    }
                }
            }
        }

        result = default;
        return false;
    }

    private static string NormalizeFieldName(string value) =>
        string.Concat(value.Where(char.IsLetterOrDigit)).ToLowerInvariant();

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
