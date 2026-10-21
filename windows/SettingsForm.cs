namespace QuotaMeterWindows;

internal sealed class SettingsForm : Form
{
    private AppSettings _saved;
    private readonly Action<AppSettings> _onSaved;
    private readonly TextBox _baseUrl = new();
    private readonly TextBox _apiKey = new();
    private readonly TextBox _token = new();
    private readonly TextBox _path = new();
    private readonly ComboBox _provider = new();
    private readonly NumericUpDown _interval = new();
    private readonly Label _status = new();
    private readonly TableLayoutPanel _content;
    private DashboardLoginForm? _login;

    public SettingsForm(AppSettings settings, Action<AppSettings> onSaved)
    {
        SuspendLayout();
        _saved = settings.Copy();
        _onSaved = onSaved;
        Text = "API 设置";
        Icon = IconLoader.Load();
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Microsoft YaHei UI", 9);
        BackColor = Color.FromArgb(45, 42, 39);
        ForeColor = DashboardPanel.Ink;
        ClientSize = new Size(460, 625);
        MinimumSize = new Size(380, 340);
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
        _content = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Dock = DockStyle.Top, Padding = new Padding(20, 16, 20, 20), Margin = Padding.Empty };
        _content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        scroll.Controls.Add(_content);
        Controls.Add(scroll);
        Add(new Label { Text = "API 设置", AutoSize = true, Font = new Font(Font.FontFamily, 19, FontStyle.Bold), Margin = new Padding(0, 0, 0, 10) });
        Add(Note("密钥由 Windows 加密保存，仅当前用户可以读取。"));
        LabelRow("Base URL");
        _baseUrl.Text = settings.BaseUrl;
        _baseUrl.PlaceholderText = "https://your-api.example.com";
        var urlRow = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2, Margin = Padding.Empty };
        urlRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        urlRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        StyleInput(_baseUrl);
        urlRow.Controls.Add(_baseUrl);
        var pasteUrl = Button("粘贴");
        pasteUrl.Click += (_, _) => Paste(_baseUrl);
        urlRow.Controls.Add(pasteUrl);
        Add(urlRow);
        LabelRow("接口类型");
        _provider.DropDownStyle = ComboBoxStyle.DropDownList;
        _provider.Items.AddRange(["自动", "兼容接口", "OpenRouter", "DeepSeek"]);
        _provider.SelectedIndex = settings.ProviderPreset.ToLowerInvariant() switch { "compatible" => 1, "openrouter" => 2, "deepseek" => 3, _ => 0 };
        StyleInput(_provider);
        _provider.SelectedIndexChanged += (_, _) => UpdateProvider();
        Add(_provider);
        LabelRow("Usage Path / 完整用量地址");
        _path.Text = settings.UsagePath;
        _path.PlaceholderText = "/v1/usage 或 https://…";
        StyleInput(_path);
        Add(_path);
        var keyTitle = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 10, 0, 2) };
        keyTitle.Controls.Add(new Label { Text = "API Key", AutoSize = true, Margin = new Padding(0, 5, 15, 0) });
        var show = new CheckBox { Text = "显示", AutoSize = true, Margin = new Padding(0, 4, 10, 0) };
        show.CheckedChanged += (_, _) => _apiKey.UseSystemPasswordChar = !show.Checked;
        keyTitle.Controls.Add(show);
        var paste = Button("粘贴");
        paste.Click += (_, _) => Paste(_apiKey);
        keyTitle.Controls.Add(paste);
        Add(keyTitle);
        StyleInput(_apiKey);
        _apiKey.UseSystemPasswordChar = true;
        _apiKey.PlaceholderText = string.IsNullOrEmpty(settings.ApiKey) ? "输入 API Key" : "已保存密钥；留空表示保留，输入新值可替换";
        Add(_apiKey);
        LabelRow("Usage / 官网访问令牌（可选）");
        StyleInput(_token);
        _token.UseSystemPasswordChar = true;
        _token.Text = settings.PlatformToken;
        _token.PlaceholderText = "部分服务商的历史用量需要单独登录";
        Add(_token);
        var login = Button("网页登录并自动获取令牌");
        login.Margin = new Padding(0, 8, 0, 0);
        login.Click += (_, _) => OpenLogin();
        Add(login);
        var intervalRow = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 14, 0, 8) };
        intervalRow.Controls.Add(new Label { Text = "刷新间隔（秒）", AutoSize = true, Margin = new Padding(0, 5, 12, 0) });
        _interval.Minimum = 10;
        _interval.Maximum = 3600;
        _interval.Increment = 5;
        _interval.Value = Math.Clamp(settings.RefreshIntervalSeconds, 10, 3600);
        _interval.Width = 85;
        _interval.BackColor = Color.FromArgb(62, 59, 56);
        _interval.ForeColor = ForeColor;
        intervalRow.Controls.Add(_interval);
        Add(intervalRow);
        var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, WrapContents = true, Margin = new Padding(0, 6, 0, 6) };
        var save = Button("保存并刷新");
        save.Click += (_, _) => Save();
        var clear = Button("清除密钥");
        clear.Click += (_, _) => ClearSecrets();
        actions.Controls.AddRange([save, clear]);
        Add(actions);
        _status.AutoSize = true;
        _status.Dock = DockStyle.Top;
        _status.Margin = new Padding(0, 4, 0, 0);
        _status.Text = string.IsNullOrEmpty(settings.ApiKey) ? "请先输入 API Key" : "密钥已加载";
        _status.ForeColor = DashboardPanel.Muted;
        Add(_status);
        _content.SizeChanged += (_, _) => _status.MaximumSize = new Size(Math.Max(150, _content.ClientSize.Width - _content.Padding.Horizontal), 0);
        UpdateProvider();
        AutoScaleDimensions = new SizeF(96, 96);
        ResumeLayout(true);
        Shown += (_, _) =>
        {
            var area = Screen.FromControl(this).WorkingArea;
            if (Height > area.Height - 30) Height = area.Height - 30;
            if (Bottom > area.Bottom) Top = Math.Max(area.Top, area.Bottom - Height);
        };
    }

    private void Add(Control control)
    {
        var row = _content.RowCount++;
        _content.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        _content.Controls.Add(control, 0, row);
    }
    private void LabelRow(string text) => Add(new Label { Text = text, AutoSize = true, Margin = new Padding(0, 12, 0, 4), ForeColor = DashboardPanel.Muted });
    private static Label Note(string text) => new() { Text = text, AutoSize = true, ForeColor = DashboardPanel.Muted, Margin = Padding.Empty };
    private void StyleInput(Control control)
    {
        control.Dock = DockStyle.Top;
        control.BackColor = Color.FromArgb(62, 59, 56);
        control.ForeColor = ForeColor;
        control.Margin = new Padding(0, 2, 4, 2);
        if (control is TextBox box) box.BorderStyle = BorderStyle.FixedSingle;
    }
    private static Button Button(string label)
    {
        var button = new Button { Text = label, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(8, 4, 8, 4), Margin = new Padding(0, 0, 8, 0), FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(73, 67, 60), ForeColor = DashboardPanel.Ink };
        button.FlatAppearance.BorderColor = Color.FromArgb(104, 97, 88);
        return button;
    }
    private void UpdateProvider()
    {
        _path.Enabled = _provider.SelectedIndex is not (2 or 3);
        _path.PlaceholderText = _provider.SelectedIndex == 3 ? "/user/balance" : "/v1/usage 或 https://…";
    }
    private void Paste(TextBox field)
    {
        try { if (Clipboard.ContainsText()) { field.Text = Clipboard.GetText().Trim(); Status("已从剪贴板粘贴"); } else Status("剪贴板里没有文字", true); }
        catch (Exception) { Status("暂时无法读取剪贴板，请使用 Ctrl+V。", true); }
    }
    private AppSettings Draft() => new()
    {
        BaseUrl = _baseUrl.Text.Trim(), ApiKey = string.IsNullOrWhiteSpace(_apiKey.Text) ? _saved.ApiKey : _apiKey.Text.Trim(),
        PlatformToken = _token.Text.Trim(), UsagePath = string.IsNullOrWhiteSpace(_path.Text) ? "/v1/usage" : _path.Text.Trim(),
        ProviderPreset = _provider.SelectedIndex switch { 1 => "compatible", 2 => "openRouter", 3 => "deepSeek", _ => "auto" },
        RefreshIntervalSeconds = (int)_interval.Value
    };
    private void Save()
    {
        var draft = Draft();
        if (!UsageClient.TryCreateBaseUri(draft.BaseUrl, out var uri)) { Status("请填写有效的服务商 API 地址。", true); return; }
        if (string.IsNullOrWhiteSpace(draft.ApiKey)) { Status("请先输入 API Key。", true); return; }
        draft.BaseUrl = uri.ToString().TrimEnd('/');
        try
        {
            SettingsStore.Save(draft);
            _saved = draft.Copy();
            _apiKey.Clear();
            _apiKey.PlaceholderText = "已保存密钥；留空表示保留";
            _onSaved(draft);
            Status("设置已保存，正在刷新主面板。请在主面板查看查询结果。");
        }
        catch (Exception error) { Status("无法保存设置：" + error.Message, true); }
    }
    private void ClearSecrets()
    {
        var cleared = _saved.Copy();
        cleared.ApiKey = "";
        cleared.PlatformToken = "";
        try
        {
            SettingsStore.Save(cleared);
            _saved = cleared;
            _apiKey.Clear(); _token.Clear();
            _apiKey.PlaceholderText = "输入 API Key";
            _onSaved(cleared);
            Status("已清除本机密钥和主面板数据。");
        }
        catch (Exception error) { Status("无法清除密钥：" + error.Message, true); }
    }
    private void OpenLogin()
    {
        if (!UsageClient.TryCreateBaseUri(_baseUrl.Text, out var api)) { Status("请先填写服务商地址。", true); return; }
        var deepSeek = api.Host.Equals("api.deepseek.com", StringComparison.OrdinalIgnoreCase);
        var url = deepSeek ? new Uri("https://platform.deepseek.com/usage") : api;
        if (_login is { IsDisposed: false }) { _login.Activate(); return; }
        _login = new DashboardLoginForm(url, deepSeek, token =>
        {
            _token.Text = token;
            Status("已获取访问令牌。点击“保存并刷新”同步用量。");
        });
        _login.Show(this);
    }
    private void Status(string message, bool error = false) { _status.Text = message; _status.ForeColor = error ? Color.Salmon : DashboardPanel.Muted; }
    protected override void Dispose(bool disposing) { if (disposing) _login?.Dispose(); base.Dispose(disposing); }
}
