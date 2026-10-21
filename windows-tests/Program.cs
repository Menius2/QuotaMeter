using System.Drawing.Imaging;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using QuotaMeterWindows;

internal static class Program
{
    private static int _checks;
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            TestParsing();
            TestHttpAsync().GetAwaiter().GetResult();
            Console.WriteLine($"PASS: {_checks} data and request checks");
            if (args.Length == 2 && args[0].StartsWith("--render")) Render(args[1], args[0] == "--render-96");
            return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e); return 1; }
    }
    private static void Check(bool result, string name)
    {
        if (!result) throw new Exception("FAIL: " + name);
        _checks++;
        Console.WriteLine("PASS: " + name);
    }
    internal static UsageSnapshot Sample()
    {
        using var json = JsonDocument.Parse("""
        {"balance":18.6497,"unit":"USD","planName":"钱包余额","mode":"unrestricted","isValid":true,
         "usage":{"today":{"totalTokens":34538244,"requests":316,"actualCost":111.3503},
         "total":{"inputTokens":4491950,"outputTokens":370518,"cacheCreationTokens":0,"cacheReadTokens":29675776,"totalTokens":34538244,"requests":316,"actualCost":111.3503}},
         "dailyUsage":[{"date":"2026-10-21","inputTokens":4491950,"outputTokens":370518,"totalTokens":34538244,"requests":316,"actualCost":111.3503}]}
        """);
        return UsageClient.ParseCompatible(json.RootElement);
    }
    private static void TestParsing()
    {
        var s = Sample();
        Check(s.Balance == 18.6497, "balance retains decimals");
        Check(UsageDisplay.Money(s.Balance, s.Unit) == "$18.6497", "USD balance formatting");
        Check(UsageDisplay.Money(.005, "CNY") == "¥0.005", "small CNY amounts are visible");
        Check(UsageDisplay.Money(null, "USD") == "—", "unknown balance is not zero");
        Check(s.TotalRequests == 316 && s.TotalInputTokens == 4491950 && s.CacheReadTokens == 29675776, "aggregate details and cached tokens");
        Check(UsageDisplay.SummaryValue(s, true) == "34,538,244", "token counts do not use currency format");
        using var days = JsonDocument.Parse(JsonSerializer.Serialize(new { records = Enumerable.Range(1, 10).Select(i => new { date = $"2026-10-{i:00}", total_tokens = 100, requests = 1, cost = .25 }) }));
        var history = UsageClient.ParseCompatible(days.RootElement);
        Check(history.TotalTokens == 1000 && history.TotalRequests == 10 && history.TotalAmount == 2.5 && history.DailyUsage.Count == 10, "totals aggregate all days before display truncation");
        using var limits = JsonDocument.Parse("""
        {"data":{"balance":"10.25","unit":"credits","quota":{"limit":100,"used":89.75,"remaining":10.25},"rate_limits":[{"window":"5h","limit":100,"used":70,"reset_at":"later"}]}}
        """);
        var limited = UsageClient.ParseCompatible(limits.RootElement);
        Check(limited.Quota?.Limit == 100 && limited.RateLimits.Single().Used == 70 && limited.RateLimits[0].ResetAt == "later", "quota and time-window limits survive parsing");
        using var router = JsonDocument.Parse("""{"data":{"limit":20,"limit_remaining":12.5,"usage":7.5,"usage_daily":0.125,"limit_reset":"daily","label":"My key"}}""");
        var openRouter = UsageClient.ParseOpenRouter(router.RootElement);
        Check(openRouter.TodayAmount == .125 && openRouter.RateLimits.Single().Window == "daily" && openRouter.DailyUsage.Single().Cost == .125, "OpenRouter usage and reset period");
        Check(DashboardLoginForm.UnwrapToken("plain-token") == "plain-token", "plain login token");
        Check(DashboardLoginForm.UnwrapToken("{\"value\":\"wrapped-token\"}") == "wrapped-token", "wrapped login token");
        Check(DashboardLoginForm.UnwrapToken("{\"value\":42}") == null, "reject non-string login token");
        Check(UsageDisplay.SummaryTitle(s with { Mode = "compatible-local" }, true) == "今日消耗（本机）", "local observations labeled explicitly");
        Check(UsageClient.TryCreateBaseUri("platform.deepseek.com", out var uri) && uri.Host == "api.deepseek.com", "DeepSeek dashboard URL normalized");
    }
    private static async Task TestHttpAsync()
    {
        var tcp = new TcpListener(IPAddress.Loopback, 0);
        tcp.Start();
        var port = ((IPEndPoint)tcp.LocalEndpoint).Port;
        tcp.Stop();
        using var listener = new HttpListener();
        var prefix = $"http://127.0.0.1:{port}/";
        listener.Prefixes.Add(prefix);
        listener.Start();
        var response = Task.Run(async () =>
        {
            var context = await listener.GetContextAsync();
            var observed = context.Request.RawUrl;
            var bearer = context.Request.Headers["Authorization"];
            var payload = Encoding.UTF8.GetBytes("{\"balance\":18.6497,\"unit\":\"USD\"}");
            context.Response.ContentType = "application/json";
            await context.Response.OutputStream.WriteAsync(payload);
            context.Response.Close();
            return (observed, bearer);
        });
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var result = await new UsageClient().FetchAsync(new AppSettings { BaseUrl = prefix, ApiKey = "fixture-key", PlatformToken = "fixture-usage-token", UsagePath = prefix + "custom/usage?account=example" }, timeout.Token);
        var request = await response;
        Check(result.Balance == 18.6497 && request.observed == "/custom/usage?account=example", "absolute Usage URL and query preserved end-to-end");
        Check(request.bearer == "Bearer fixture-usage-token", "compatible endpoint uses supplied Usage token");
        var denied = Task.Run(async () =>
        {
            var context = await listener.GetContextAsync();
            context.Response.StatusCode = 401;
            var payload = Encoding.UTF8.GetBytes("{\"message\":\"invalid key\"}");
            await context.Response.OutputStream.WriteAsync(payload);
            context.Response.Close();
        });
        var unauthorized = false;
        try { await new UsageClient().FetchAsync(new AppSettings { BaseUrl = prefix, ApiKey = "fixture-key" }, timeout.Token); }
        catch (UsageClient.RequestFailedException ex) { unauthorized = ex.IsUnauthorized; }
        await denied;
        Check(unauthorized, "unauthorized credentials stop endpoint probing");
    }
    private static void Render(string output, bool dpi96)
    {
        Directory.CreateDirectory(output);
        Application.SetHighDpiMode(dpi96 ? HighDpiMode.DpiUnaware : HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using var main = new MainForm(new AppSettings(), preview: true) { Opacity = 0 };
        main.Preview(Sample());
        main.Show();
        Console.WriteLine($"Native form DPI: {main.DeviceDpi}");
        Pump();
        Capture(main, Path.Combine(output, "dashboard-window.png"));
        var panel = main.Controls.OfType<DashboardPanel>().Single();
        panel.AutoScrollPosition = new Point(0, panel.AutoScrollMinSize.Height);
        Pump();
        Capture(main, Path.Combine(output, "dashboard-scrolled.png"));
        panel.AutoScrollPosition = Point.Empty;
        main.ClientSize = new Size(main.ClientSize.Width, (int)(1050 * main.DeviceDpi / 96f));
        Pump();
        main.ClientSize = new Size(main.ClientSize.Width, panel.AutoScrollMinSize.Height + main.Controls.OfType<Panel>().Single(p => p is not DashboardPanel).Height);
        Pump();
        Capture(main, Path.Combine(output, "dashboard-full.png"));
        main.Preview(Sample() with { RateLimits = [new RateLimitRow("5h", 40000000, 34538244, null)] });
        Pump();
        Capture(main, Path.Combine(output, "dashboard-limits.png"));
        main.AllowClose(); main.Close();
        using var settings = new SettingsForm(new AppSettings { BaseUrl = "https://your-api.example.com" }, _ => { }) { Opacity = 0 };
        settings.Show();
        Pump();
        Capture(settings, Path.Combine(output, "settings-window.png"));
        Check(ContainsText(settings, "保存并刷新"), "settings save action remains available");
        settings.ClientSize = new Size(settings.ClientSize.Width, 330);
        Pump();
        var scroll = settings.Controls.OfType<Panel>().Single();
        Check(scroll.VerticalScroll.Visible, "small settings windows scroll instead of clipping");
        scroll.AutoScrollPosition = new Point(0, 5000);
        Pump();
        Capture(settings, Path.Combine(output, "settings-small-scrolled.png"));
        settings.Close();
        Console.WriteLine($"PASS: {_checks} checks; rendered previews in {output}");
    }
    private static bool ContainsText(Control c, string value) => c.Text == value || c.Controls.Cast<Control>().Any(child => ContainsText(child, value));
    private static void Pump() { for (var i = 0; i < 5; i++) { Application.DoEvents(); Thread.Sleep(40); } }
    private static void Capture(Form form, string path)
    {
        using var bitmap = new Bitmap(form.Width, form.Height);
        form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
        bitmap.Save(path, ImageFormat.Png);
    }
}
