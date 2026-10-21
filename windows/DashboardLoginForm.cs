using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace QuotaMeterWindows;

internal sealed class DashboardLoginForm : Form
{
    private readonly WebView2 _browser = new() { Dock = DockStyle.Fill };
    private readonly System.Windows.Forms.Timer _scan = new() { Interval = 750 };
    private readonly Uri _url;
    private readonly string[] _keys;
    private readonly Action<string> _onToken;
    private bool _scanning;
    private string _lastToken = "";
    private readonly Label _status = new() { Dock = DockStyle.Top, Height = 40, AutoSize = false, Text = "请在服务商官网完成登录。", TextAlign = ContentAlignment.MiddleLeft };

    public DashboardLoginForm(Uri url, bool deepSeek, Action<string> onToken)
    {
        _url = url; _onToken = onToken;
        _keys = deepSeek ? ["userToken"] : ["userToken", "access_token", "accessToken", "auth_token", "authToken", "token"];
        Text = "网页登录";
        StartPosition = FormStartPosition.CenterParent;
        Size = new Size(1000, 720);
        Controls.Add(_browser); Controls.Add(_status);
        Shown += async (_, _) => await InitializeAsync();
        _scan.Tick += async (_, _) => await ScanAsync();
    }
    private async Task InitializeAsync()
    {
        try
        {
            var profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "QuotaMeter", "WebView2");
            var env = await CoreWebView2Environment.CreateAsync(null, profile);
            if (IsDisposed) return;
            await _browser.EnsureCoreWebView2Async(env);
            if (IsDisposed) return;
            _browser.CoreWebView2.Navigate(_url.ToString());
            _scan.Start();
        }
        catch (Exception)
        {
            if (!IsDisposed) _status.Text = "无法打开内置浏览器。请安装或修复 Microsoft Edge WebView2 Runtime，或返回设置手动填写访问令牌。";
        }
    }
    internal static string? UnwrapToken(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        try
        {
            using var json = JsonDocument.Parse(raw);
            if (json.RootElement.ValueKind == JsonValueKind.Object && json.RootElement.TryGetProperty("value", out var value))
                return value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() : null;
            if (json.RootElement.ValueKind == JsonValueKind.String) return json.RootElement.GetString()?.Trim();
            return null;
        }
        catch (JsonException) { return raw.Trim(); }
    }
    private async Task ScanAsync()
    {
        if (_scanning || IsDisposed || _browser.CoreWebView2 == null) return;
        if (!Uri.TryCreate(_browser.Source?.ToString(), UriKind.Absolute, out var current) ||
            !current.GetLeftPart(UriPartial.Authority).Equals(_url.GetLeftPart(UriPartial.Authority), StringComparison.OrdinalIgnoreCase)) return;
        _scanning = true;
        try
        {
            var script = "(() => { for (const key of " + JsonSerializer.Serialize(_keys) + ") { const v = localStorage.getItem(key) || sessionStorage.getItem(key); if (v) return v; } return null; })()";
            var json = await _browser.CoreWebView2.ExecuteScriptAsync(script);
            if (IsDisposed) return;
            var token = UnwrapToken(JsonSerializer.Deserialize<string>(json));
            if (string.IsNullOrWhiteSpace(token) || token == _lastToken) return;
            _lastToken = token;
            _onToken(token);
            _status.Text = "已获取令牌。可以关闭此窗口，返回设置点击“保存并刷新”。";
        }
        catch (Exception) { /* Navigation may destroy the page while the script is running. */ }
        finally { _scanning = false; }
    }
    protected override void Dispose(bool disposing) { if (disposing) _scan.Dispose(); base.Dispose(disposing); }
}
