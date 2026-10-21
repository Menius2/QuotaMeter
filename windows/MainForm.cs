using System.Drawing.Drawing2D;

namespace QuotaMeterWindows;

internal sealed class MainForm : Form
{
    private AppSettings _settings;
    private readonly UsageClient _client = new();
    private readonly BalanceUsageTracker _tracker = new();
    private readonly DashboardPanel _dashboard = new() { Dock = DockStyle.Fill };
    private readonly Panel _header = new() { Dock = DockStyle.Top, Height = 60, Padding = new Padding(18, 10, 18, 0) };
    private readonly System.Windows.Forms.Timer _timer = new();
    private readonly ToolTip _tips = new();
    private CancellationTokenSource? _refresh;
    private SettingsForm? _settingsForm;
    private UsageSnapshot? _snapshot;
    private DateTime? _lastUpdated;
    private string _message = "";
    private bool _error;
    private bool _allowClose;
    private int _generation;
    private readonly bool _preview;
    private Bitmap? _backdrop;
    private bool _loaded;
    public event EventHandler? QuitRequested;

    public MainForm(AppSettings settings, bool preview = false)
    {
        SuspendLayout();
        _settings = settings.Copy();
        _preview = preview;
        Text = "QuotaMeter";
        Icon = IconLoader.Load();
        AutoScaleDimensions = new SizeF(96, 96);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Microsoft YaHei UI", 9);
        BackColor = Color.FromArgb(28, 28, 28);
        ForeColor = DashboardPanel.Ink;
        ShowInTaskbar = false;
        FormBorderStyle = FormBorderStyle.None;
        MinimizeBox = false;
        MaximizeBox = false;
        MinimumSize = new Size(360, 300);
        ClientSize = new Size(440, 610);
        StartPosition = FormStartPosition.Manual;
        Controls.Add(_dashboard);
        _dashboard.PaintBackdrop = PaintBackdrop;
        _header.BackColor = Color.Transparent;
        var actions = new FlowLayoutPanel { Dock = DockStyle.Right, Width = 132, FlowDirection = FlowDirection.LeftToRight, WrapContents = false };
        var refresh = HeaderButton("↻", "刷新");
        refresh.Click += async (_, _) => await RefreshDataAsync();
        var settingsButton = HeaderButton("⚙", "设置");
        settingsButton.Click += (_, _) => OpenSettings();
        var quit = HeaderButton("⏻", "退出");
        quit.Click += (_, _) => QuitRequested?.Invoke(this, EventArgs.Empty);
        actions.Controls.AddRange([refresh, settingsButton, quit]);
        var title = new HeaderTitleLabel { Text = "API 额度", Dock = DockStyle.Fill, AutoSize = false,
            TextAlign = ContentAlignment.MiddleLeft, Font = new Font(Font.FontFamily, 19, FontStyle.Bold) };
        _header.Controls.Add(title);
        _header.Controls.Add(actions);
        Controls.Add(_header);
        _timer.Tick += async (_, _) => await RefreshDataAsync();
        SetInterval();
        Shown += async (_, _) =>
        {
            if (_preview) return;
            _timer.Start();
            await RefreshDataAsync();
        };
        Deactivate += (_, _) =>
        {
            if (_preview || _allowClose || IsDisposed || !IsHandleCreated || _settingsForm is { Visible: true }) return;
            BeginInvoke(() => { if (!IsDisposed && !ContainsFocus && _settingsForm is not { Visible: true }) Hide(); });
        };
        AutoScaleDimensions = new SizeF(96, 96);
        ResumeLayout(true);
        Render();
    }

    private Button HeaderButton(string text, string description)
    {
        var button = new HeaderActionButton(description) { Width = 38, Height = 38, Margin = new Padding(0, 0, 6, 0),
            FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(23, 38, 56), ForeColor = Color.White,
            Font = new Font("Segoe UI Symbol", 17), AccessibleName = description, Cursor = Cursors.Hand };
        button.FlatAppearance.BorderSize = 1;
        button.FlatAppearance.BorderColor = Color.FromArgb(101, 130, 160);
        button.FlatAppearance.MouseOverBackColor = Color.FromArgb(38, 69, 99);
        button.FlatAppearance.MouseDownBackColor = Color.FromArgb(12, 23, 37);
        _tips.SetToolTip(button, description);
        return button;
    }

    public void ShowAtTray()
    {
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        var margin = (int)(12 * DeviceDpi / 96f);
        Height = Math.Min(Height, area.Height - margin * 2);
        Width = Math.Min(Width, area.Width - margin * 2);
        Location = new Point(area.Right - Width - margin, area.Bottom - Height - margin);
        Show();
        Activate();
    }

    public void OpenSettings()
    {
        if (_settingsForm is { IsDisposed: false }) { _settingsForm.Show(); _settingsForm.Activate(); return; }
        _settingsForm = new SettingsForm(_settings, CommitSettings);
        _settingsForm.Show(this);
    }

    private void CommitSettings(AppSettings next)
    {
        // Only committed settings are used by the timer. Ignore stale responses from the old account.
        _generation++;
        _refresh?.Cancel();
        _refresh = null;
        _settings = next.Copy();
        _snapshot = null;
        _lastUpdated = null;
        SetInterval();
        _timer.Start();
        _ = RefreshDataAsync();
    }

    public async Task RefreshDataAsync()
    {
        if (_preview || _refresh != null) return;
        if (string.IsNullOrWhiteSpace(_settings.ApiKey) || string.IsNullOrWhiteSpace(_settings.BaseUrl))
        {
            _message = "先在设置里填写服务商地址和 API Key";
            _error = false;
            _snapshot = null;
            _lastUpdated = null;
            _timer.Stop();
            Render();
            return;
        }
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        _refresh = cancellation;
        var generation = _generation;
        var settings = _settings.Copy();
        Render();
        try
        {
            var snapshot = await _client.FetchAsync(settings, cancellation.Token);
            if (generation != _generation || IsDisposed) return;
            _snapshot = snapshot.Mode == "deepseek" && string.IsNullOrWhiteSpace(settings.PlatformToken)
                ? snapshot : _tracker.Observe(snapshot, settings);
            _lastUpdated = DateTime.Now;
            _error = false;
            _message = snapshot.Mode == "deepseek" ? "已读取余额。历史用量需要在设置里网页登录或填写 Usage 访问令牌。" : "";
        }
        catch (OperationCanceledException)
        {
            if (generation != _generation || IsDisposed) return;
            _message = "刷新已超时，请检查网络或在设置中填写准确的 Usage 地址。";
            _error = true;
        }
        catch (Exception error)
        {
            if (generation != _generation || IsDisposed) return;
            _message = error.Message;
            _error = true;
            if (error is UsageClient.RequestFailedException { IsUnauthorized: true }) _timer.Stop();
        }
        finally
        {
            if (ReferenceEquals(_refresh, cancellation)) _refresh = null;
            if (!IsDisposed && generation == _generation) Render();
        }
    }

    private void SetInterval() => _timer.Interval = Math.Clamp(_settings.RefreshIntervalSeconds, 10, 3600) * 1000;
    private void Render() => _dashboard.UpdateData(_snapshot, _message, _error, _refresh != null, _lastUpdated, _settings.RefreshIntervalSeconds);
    internal void Preview(UsageSnapshot snapshot) { _snapshot = snapshot; _lastUpdated = DateTime.Now; _message = "预览示例数据"; Render(); }
    public void AllowClose() { _allowClose = true; _generation++; _refresh?.Cancel(); }

    private void UpdateRoundedCorners()
    {
        if (!IsHandleCreated || Width <= 0 || Height <= 0) return;
        var diameter = Math.Min(48f * DeviceDpi / 96f, Math.Min(Width, Height));
        using var outline = new GraphicsPath();
        outline.AddArc(0, 0, diameter, diameter, 180, 90);
        outline.AddArc(Width - diameter, 0, diameter, diameter, 270, 90);
        outline.AddArc(Width - diameter, Height - diameter, diameter, diameter, 0, 90);
        outline.AddArc(0, Height - diameter, diameter, diameter, 90, 90);
        outline.CloseFigure();
        var previous = Region;
        Region = new Region(outline);
        previous?.Dispose();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        UpdateRoundedCorners();
    }

    private void CaptureBackdrop()
    {
        var next = Opacity > 0 ? FrostedBackdrop.Capture(Bounds, DeviceDpi / 96f) : null;
        var previous = _backdrop;
        _backdrop = next;
        previous?.Dispose();
        Invalidate(true);
    }

    private bool PaintBackdrop(Graphics graphics, Point offset)
    {
        if (_backdrop is null) return false;
        graphics.DrawImage(_backdrop, new Rectangle(-offset.X, -offset.Y, ClientSize.Width, ClientSize.Height));
        return true;
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        if (!PaintBackdrop(e.Graphics, Point.Empty)) base.OnPaintBackground(e);
    }

    protected override void OnLoad(EventArgs e)
    {
        base.OnLoad(e);
        _loaded = true;
        CaptureBackdrop();
    }

    protected override void SetVisibleCore(bool value)
    {
        if (value && !Visible && _loaded) CaptureBackdrop();
        base.SetVisibleCore(value);
        if (!value) { _backdrop?.Dispose(); _backdrop = null; }
    }

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        UpdateRoundedCorners();
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        UpdateRoundedCorners();
    }

    protected override CreateParams CreateParams
    {
        get { var parameters = base.CreateParams; parameters.ClassStyle |= 0x20000; return parameters; }
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape) { Hide(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!_allowClose && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
        _timer.Stop();
        _refresh?.Cancel();
        base.OnFormClosing(e);
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { _generation++; _refresh?.Cancel(); _timer.Dispose(); _tips.Dispose(); _settingsForm?.Dispose(); _backdrop?.Dispose(); _backdrop = null; }
        base.Dispose(disposing);
    }

    private sealed class HeaderTitleLabel : Label
    {
        protected override void OnPaint(PaintEventArgs e)
        {
            // Grayscale antialiasing avoids ClearType color fringes over live glass.
            e.Graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            using var brush = new SolidBrush(Color.White);
            using var format = new StringFormat { LineAlignment = StringAlignment.Center, FormatFlags = StringFormatFlags.NoWrap };
            e.Graphics.DrawString(Text, Font, brush, ClientRectangle, format);
        }
    }
}
