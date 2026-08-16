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
            return await FetchDeepSeekAsync(baseUri, settings.ApiKey, cancellationToken);
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
                return await FetchSnapshotAsync(endpoint, settings.ApiKey, isOpenRouter, cancellationToken);
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

            return new UsageSnapshot
            {
                Balance = balance,
                Unit = currency.ToUpperInvariant(),
                Mode = "deepseek",
                PlanName = "DeepSeek API",
                IsValid = available ?? true
            };
        }
        catch (JsonException ex)
        {
            throw new RequestFailedException(null, "无法识别 DeepSeek 返回格式。", ex);
        }
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

        var quota = GetObject(data, "quota");
        var usage = GetObject(data, "usage");
        var today = usage is { } usageObject ? GetObject(usageObject, "today") : null;
        var total = usage is { } totalObject ? GetObject(totalObject, "total") : null;

        var balance = GetNumber(
                          data,
                          "remaining",
                          "balance",
                          "remaining_balance",
                          "credit_balance",
                          "credits",
                          "total_balance"
                      ) ??
                      (quota is { } quotaObject
                          ? GetNumber(quotaObject, "remaining", "balance", "total_balance")
                          : null);
        var todayTokens = today is { } todayObject
            ? GetNumber(todayObject, "total_tokens", "totalTokens", "tokens")
            : null;
        var totalTokens = total is { } totalObjectValue
            ? GetNumber(totalObjectValue, "total_tokens", "totalTokens", "tokens")
            : null;
        var todayAmount = today is { } todayAmountObject
            ? GetNumber(todayAmountObject, "actual_cost", "actualCost", "cost", "total_cost") ?? todayTokens
            : null;
        var totalAmount = total is { } totalAmountObject
            ? GetNumber(totalAmountObject, "actual_cost", "actualCost", "cost", "total_cost") ?? totalTokens
            : null;

        return new UsageSnapshot
        {
            Balance = balance,
            TodayAmount = todayAmount,
            TotalAmount = totalAmount,
            TodayTokens = todayTokens,
            TotalTokens = totalTokens,
            TodayRequests = today is { } todayRequests
                ? GetNumber(todayRequests, "requests", "request_count", "num_model_requests")
                : null,
            TotalRequests = total is { } totalRequests
                ? GetNumber(totalRequests, "requests", "request_count", "num_model_requests")
                : null,
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
        if (!TryGet(data, out var daily, "daily_usage", "dailyUsage", "records") ||
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
                Date = GetString(item, "date", "day", "period") ?? "",
                Requests = GetNumber(item, "requests", "request_count", "num_model_requests"),
                InputTokens = GetNumber(item, "input_tokens", "inputTokens", "prompt_tokens"),
                OutputTokens = GetNumber(item, "output_tokens", "outputTokens", "completion_tokens"),
                TotalTokens = GetNumber(item, "total_tokens", "totalTokens", "tokens"),
                Cost = GetNumber(item, "actual_cost", "actualCost", "cost")
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
                   "quota",
                   "usage",
                   "daily_usage",
                   "dailyUsage",
                   "records"
               ));
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
