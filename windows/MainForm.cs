using System.Drawing;
using System.Windows.Forms;
using System.Text.Json;
using Microsoft.Web.WebView2.WinForms;

namespace QuotaMeterWindows;

internal sealed class MainForm : Form
{
    private readonly AppSettings _settings;
    private readonly UsageClient _client = new();
    private readonly BalanceUsageTracker _balanceUsageTracker = new();
    private readonly TextBox _baseUrlField = new();
    private readonly TextBox _apiKeyField = new();
    private readonly TextBox _platformTokenField = new();
    private readonly ComboBox _providerField = new();
    private readonly TextBox _usagePathField = new();
    private readonly NumericUpDown _intervalField = new();
    private readonly Label _balanceValue = MetricValue();
    private readonly Label _todayValue = MetricValue();
    private readonly Label _totalValue = MetricValue();
    private readonly Label _requestsValue = MetricValue();
    private readonly Label _statusLabel = new();
    private readonly ListView _dailyList = new();
    private readonly System.Windows.Forms.Timer _timer = new();
    private bool _allowClose;
    private bool _isRefreshing;

    public MainForm(AppSettings settings)
    {
        _settings = settings;
        Text = "QuotaMeter";
        Icon = IconLoader.Load();
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(640, 620);
        ClientSize = new Size(760, 700);
        Font = new Font("Segoe UI", 10);
        BackColor = Color.FromArgb(39, 36, 34);
        ForeColor = Color.WhiteSmoke;

        BuildInterface();
        LoadSettingsIntoFields();

        _timer.Tick += async (_, _) => await RefreshDataAsync();
        _timer.Interval = Math.Max(10, _settings.RefreshIntervalSeconds) * 1000;
        _timer.Start();
        Shown += async (_, _) => await RefreshDataAsync();
    }

    public async Task RefreshDataAsync()
    {
        if (_isRefreshing)
        {
            return;
        }

        ApplyFields();
        if (string.IsNullOrWhiteSpace(_settings.ApiKey))
        {
            SetStatus("请先输入 API Key。", Color.Khaki);
            return;
        }

        if (string.IsNullOrWhiteSpace(_settings.BaseUrl))
        {
            SetStatus("请先输入 Base URL。", Color.Khaki);
            return;
        }

        _isRefreshing = true;
        SetStatus("正在刷新...", Color.LightGray);
        try
        {
            var snapshot = await _client.FetchAsync(_settings, CancellationToken.None);
            snapshot = _balanceUsageTracker.Observe(snapshot, _settings);
            UpdateSnapshot(snapshot);
            SetStatus($"更新于 {DateTime.Now:HH:mm:ss}", Color.LightGreen);
        }
        catch (Exception error)
        {
            SetStatus(error.Message, Color.Salmon);
        }
        finally
        {
            _isRefreshing = false;
        }
    }

    public void AllowClose()
    {
        _allowClose = true;
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!_allowClose)
        {
            e.Cancel = true;
            Hide();
            return;
        }

        _timer.Stop();
        base.OnFormClosing(e);
    }

    private void BuildInterface()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 4,
            Padding = new Padding(18),
            BackColor = BackColor
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        Controls.Add(root);

        var header = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            ColumnCount = 2,
            AutoSize = true
        };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var title = new Label
        {
            Text = "API 额度",
            Font = new Font(Font, FontStyle.Bold),
            AutoSize = true,
            ForeColor = Color.White
        };
        var refreshButton = MakeButton("刷新");
        refreshButton.Click += async (_, _) => await RefreshDataAsync();
        header.Controls.Add(title, 0, 0);
        header.Controls.Add(refreshButton, 1, 0);
        root.Controls.Add(header, 0, 0);

        root.Controls.Add(BuildSettingsPanel(), 0, 1);
        root.Controls.Add(BuildMetricsPanel(), 0, 2);
        root.Controls.Add(BuildDailyPanel(), 0, 3);
    }

    private Control BuildSettingsPanel()
    {
        var group = new GroupBox
        {
            Text = "连接设置",
            Dock = DockStyle.Top,
            AutoSize = true,
            ForeColor = Color.WhiteSmoke,
            Padding = new Padding(12)
        };
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            RowCount = 7,
            AutoSize = true
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 120));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        group.Controls.Add(layout);

        AddRow(layout, 0, "Base URL", _baseUrlField);
        _baseUrlField.Dock = DockStyle.Fill;
        _baseUrlField.PlaceholderText = "https://your-api.example.com";

        _providerField.DropDownStyle = ComboBoxStyle.DropDownList;
        _providerField.Items.AddRange(["自动", "兼容接口", "OpenRouter", "DeepSeek"]);
        _providerField.SelectedIndexChanged += (_, _) => UpdateProviderFieldState();
        AddRow(layout, 1, "接口类型", _providerField);

        _usagePathField.Dock = DockStyle.Fill;
        _usagePathField.PlaceholderText = "/v1/usage";
        AddRow(layout, 2, "Usage Path", _usagePathField);

        var keyPanel = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, AutoSize = true };
        keyPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        keyPanel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        _apiKeyField.Dock = DockStyle.Fill;
        _apiKeyField.UseSystemPasswordChar = true;
        var showKey = new CheckBox { Text = "显示", AutoSize = true, ForeColor = Color.WhiteSmoke };
        showKey.CheckedChanged += (_, _) => _apiKeyField.UseSystemPasswordChar = !showKey.Checked;
        keyPanel.Controls.Add(_apiKeyField, 0, 0);
        keyPanel.Controls.Add(showKey, 1, 0);
        AddRow(layout, 3, "API Key", keyPanel);

        _platformTokenField.Dock = DockStyle.Fill;
        _platformTokenField.UseSystemPasswordChar = true;
        _platformTokenField.PlaceholderText = "供应商 Usage / 官网访问令牌（可选）";
        AddRow(layout, 4, "Usage 访问令牌", _platformTokenField);

        _intervalField.Minimum = 10;
        _intervalField.Maximum = 3600;
        _intervalField.Value = 30;
        _intervalField.Width = 100;
        AddRow(layout, 5, "刷新间隔", _intervalField);

        var actions = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
        var saveButton = MakeButton("保存并刷新");
        saveButton.Click += async (_, _) =>
        {
            ApplyFields();
            SettingsStore.Save(_settings);
            _timer.Interval = Math.Max(10, _settings.RefreshIntervalSeconds) * 1000;
            await RefreshDataAsync();
        };
        var clearButton = MakeButton("清除密钥");
        clearButton.Click += (_, _) =>
        {
            _apiKeyField.Clear();
            _platformTokenField.Clear();
            _settings.ApiKey = "";
            _settings.PlatformToken = "";
            SettingsStore.Save(_settings);
            SetStatus("已清除本机密钥。", Color.LightGreen);
        };
        actions.Controls.Add(saveButton);
        actions.Controls.Add(clearButton);
        var loginButton = MakeButton("网页登录并自动获取令牌");
        loginButton.Click += async (_, _) => await OpenDashboardLoginAsync();
        actions.Controls.Add(loginButton);
        AddRow(layout, 6, "", actions);
        return group;
    }

    private async Task OpenDashboardLoginAsync()
    {
        var host = _baseUrlField.Text.Trim();
        var url = host.Contains("deepseek", StringComparison.OrdinalIgnoreCase)
            ? "https://platform.deepseek.com/usage"
            : (Uri.TryCreate(host, UriKind.Absolute, out var parsed) ? parsed.ToString() : "https://platform.openai.com");
        using var loginWindow = new Form
        {
            Text = "网页登录（登录完成后自动同步用量）",
            StartPosition = FormStartPosition.CenterParent,
            Width = 1100,
            Height = 760
        };
        var browser = new WebView2 { Dock = DockStyle.Fill };
        loginWindow.Controls.Add(browser);
        browser.NavigationCompleted += async (_, _) =>
        {
            try
            {
                var raw = await browser.CoreWebView2.ExecuteScriptAsync("(() => { const v = localStorage.getItem('userToken'); return v || ''; })()");
                var value = JsonSerializer.Deserialize<string>(raw) ?? "";
                if (string.IsNullOrWhiteSpace(value)) return;
                using var tokenDoc = JsonDocument.Parse(value);
                var token = tokenDoc.RootElement.ValueKind == JsonValueKind.Object && tokenDoc.RootElement.TryGetProperty("value", out var tokenValue)
                    ? tokenValue.GetString()
                    : value;
                if (string.IsNullOrWhiteSpace(token)) return;
                _platformTokenField.Text = token;
                _settings.PlatformToken = token;
                SettingsStore.Save(_settings);
                SetStatus("已获取官网登录令牌，正在刷新官网用量。", Color.LightGreen);
                await RefreshDataAsync();
            }
            catch (Exception error)
            {
                SetStatus($"网页登录令牌读取失败：{error.Message}", Color.Salmon);
            }
        };
        loginWindow.Shown += async (_, _) =>
        {
            await browser.EnsureCoreWebView2Async();
            browser.CoreWebView2.Navigate(url);
        };
        loginWindow.ShowDialog(this);
    }

    private Control BuildMetricsPanel()
    {
        var metrics = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            ColumnCount = 4,
            RowCount = 2,
            AutoSize = true,
            Padding = new Padding(0, 14, 0, 8)
        };
        for (var index = 0; index < 4; index++)
        {
            metrics.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 25));
        }

        AddMetric(metrics, 0, 0, "剩余", _balanceValue);
        AddMetric(metrics, 1, 0, "今日", _todayValue);
        AddMetric(metrics, 2, 0, "累计", _totalValue);
        AddMetric(metrics, 3, 0, "今日请求", _requestsValue);
        metrics.Controls.Add(_statusLabel, 0, 1);
        metrics.SetColumnSpan(_statusLabel, 4);
        _statusLabel.AutoSize = true;
        _statusLabel.Padding = new Padding(2, 8, 2, 4);
        _statusLabel.ForeColor = Color.LightGray;
        return metrics;
    }

    private Control BuildDailyPanel()
    {
        var group = new GroupBox
        {
            Text = "每日使用",
            Dock = DockStyle.Fill,
            ForeColor = Color.WhiteSmoke,
            Padding = new Padding(10)
        };
        _dailyList.Dock = DockStyle.Fill;
        _dailyList.View = View.Details;
        _dailyList.FullRowSelect = true;
        _dailyList.GridLines = true;
        _dailyList.BackColor = Color.FromArgb(49, 46, 44);
        _dailyList.ForeColor = Color.WhiteSmoke;
        _dailyList.Columns.Add("日期", 110);
        _dailyList.Columns.Add("请求", 80);
        _dailyList.Columns.Add("输入 Token", 130);
        _dailyList.Columns.Add("输出 Token", 130);
        _dailyList.Columns.Add("总 Token", 130);
        _dailyList.Columns.Add("费用", 100);
        group.Controls.Add(_dailyList);
        return group;
    }

    private void LoadSettingsIntoFields()
    {
        _baseUrlField.Text = _settings.BaseUrl;
        _apiKeyField.Text = _settings.ApiKey;
        _platformTokenField.Text = _settings.PlatformToken;
        _usagePathField.Text = _settings.UsagePath;
        _intervalField.Value = Math.Clamp(_settings.RefreshIntervalSeconds, 10, 3600);
        _providerField.SelectedIndex = _settings.ProviderPreset.Equals("compatible", StringComparison.OrdinalIgnoreCase)
            ? 1
            : _settings.ProviderPreset.Equals("openRouter", StringComparison.OrdinalIgnoreCase)
                ? 2
                : _settings.ProviderPreset.Equals("deepSeek", StringComparison.OrdinalIgnoreCase) ? 3 : 0;
        UpdateProviderFieldState();
    }

    private void ApplyFields()
    {
        _settings.BaseUrl = _baseUrlField.Text.Trim();
        _settings.ApiKey = _apiKeyField.Text.Trim();
        _settings.PlatformToken = _platformTokenField.Text.Trim();
        _settings.UsagePath = string.IsNullOrWhiteSpace(_usagePathField.Text)
            ? "/v1/usage"
            : NormalizePath(_usagePathField.Text);
        _settings.RefreshIntervalSeconds = (int)_intervalField.Value;
        _settings.ProviderPreset = _providerField.SelectedIndex switch
        {
            1 => "compatible",
            2 => "openRouter",
            3 => "deepSeek",
            _ => "auto"
        };
    }

    private void UpdateSnapshot(UsageSnapshot snapshot)
    {
        _balanceValue.Text = FormatAmount(snapshot.Balance, snapshot.Unit);
        _todayValue.Text = FormatAmount(snapshot.TodayTokens ?? snapshot.TodayAmount, snapshot.Unit);
        _totalValue.Text = FormatAmount(snapshot.TotalTokens ?? snapshot.TotalAmount, snapshot.Unit);
        _requestsValue.Text = snapshot.TodayRequests?.ToString("N0") ?? "-";
        _dailyList.Items.Clear();

        foreach (var row in snapshot.DailyUsage)
        {
            var item = new ListViewItem(row.Date);
            item.SubItems.Add(row.Requests?.ToString("N0") ?? "-");
            item.SubItems.Add(row.InputTokens?.ToString("N0") ?? "-");
            item.SubItems.Add(row.OutputTokens?.ToString("N0") ?? "-");
            item.SubItems.Add(row.TotalTokens?.ToString("N0") ?? "-");
            item.SubItems.Add(row.Cost?.ToString("0.####", System.Globalization.CultureInfo.InvariantCulture) ?? "-");
            _dailyList.Items.Add(item);
        }
    }

    private static string NormalizePath(string value)
    {
        var result = value.Trim();
        if (!result.StartsWith('/'))
        {
            result = "/" + result;
        }

        return result.TrimEnd('/');
    }

    private void UpdateProviderFieldState()
    {
        var isDeepSeek = _providerField.SelectedIndex == 3;
        _usagePathField.Enabled = !isDeepSeek;
        _usagePathField.PlaceholderText = isDeepSeek ? "/user/balance" : "/v1/usage";
    }

    private static string FormatAmount(double? value, string unit)
    {
        if (!value.HasValue)
        {
            return "-";
        }

        return unit.Equals("credits", StringComparison.OrdinalIgnoreCase)
            ? value.Value.ToString("0.####", System.Globalization.CultureInfo.InvariantCulture)
            : value.Value.ToString("N0");
    }

    private static void AddRow(TableLayoutPanel layout, int row, string label, Control control)
    {
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.Controls.Add(new Label
        {
            Text = label,
            AutoSize = true,
            ForeColor = Color.Gainsboro,
            Anchor = AnchorStyles.Left,
            Padding = new Padding(0, 6, 8, 6)
        }, 0, row);
        layout.Controls.Add(control, 1, row);
    }

    private static void AddMetric(TableLayoutPanel layout, int column, int row, string title, Label value)
    {
        var panel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(4) };
        panel.Controls.Add(new Label
        {
            Text = title,
            Dock = DockStyle.Top,
            AutoSize = true,
            ForeColor = Color.Silver
        });
        panel.Controls.Add(value);
        layout.Controls.Add(panel, column, row);
    }

    private static Label MetricValue()
    {
        return new Label
        {
            Text = "-",
            Dock = DockStyle.Top,
            AutoSize = true,
            Font = new Font("Segoe UI", 16, FontStyle.Bold),
            ForeColor = Color.White
        };
    }

    private static Button MakeButton(string text)
    {
        return new Button
        {
            Text = text,
            AutoSize = true,
            Padding = new Padding(8, 4, 8, 4),
            FlatStyle = FlatStyle.System
        };
    }

    private void SetStatus(string message, Color color)
    {
        _statusLabel.Text = message;
        _statusLabel.ForeColor = color;
    }
}
