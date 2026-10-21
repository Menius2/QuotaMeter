using System.Drawing.Drawing2D;

namespace QuotaMeterWindows;

// Draw in logical pixels so cards, text and spacing stay together at every DPI.
internal sealed class DashboardPanel : Panel
{
    private UsageSnapshot? _snapshot;
    private string _message = "先在设置里保存 API Key";
    private bool _error;
    private bool _refreshing;
    private DateTime? _lastUpdated;
    private int _interval = 30;
    internal static readonly Color Ink = Color.White;
    internal static readonly Color Muted = Color.White;
    private readonly FontFamily _family = new("Microsoft YaHei UI");
    internal Func<Graphics, Point, bool>? PaintBackdrop { get; set; }
    private Point _paintedScrollPosition;

    public DashboardPanel()
    {
        DoubleBuffered = true;
        AutoScroll = true;
        BackColor = Color.FromArgb(24, 24, 24);
        AccessibleRole = AccessibleRole.Pane;
        AccessibleName = "API 额度与用量";
    }

    public void UpdateData(UsageSnapshot? snapshot, string message, bool error, bool refreshing, DateTime? updated, int interval)
    {
        _snapshot = snapshot;
        _message = message;
        _error = error;
        _refreshing = refreshing;
        _lastUpdated = updated;
        _interval = interval;
        AccessibleDescription = snapshot is null ? message : $"余额 {UsageDisplay.Money(snapshot.Balance, snapshot.Unit)}，" +
            $"{UsageDisplay.SummaryTitle(snapshot, true)} {UsageDisplay.SummaryValue(snapshot, true)}，" +
            $"累计请求 {UsageDisplay.Count(snapshot.TotalRequests)}。{message}";
        Invalidate();
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        if (PaintBackdrop?.Invoke(e.Graphics, Location) == true) return;
        using var brush = new LinearGradientBrush(ClientRectangle, Color.FromArgb(40, 40, 40), BackColor, 65f);
        e.Graphics.FillRectangle(brush, ClientRectangle);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        // Native scrolling copies old pixels, including the backdrop. Repaint it
        // in full once the scroll changes so the glass stays fixed to the window.
        if (_paintedScrollPosition != AutoScrollPosition)
        {
            _paintedScrollPosition = AutoScrollPosition;
            Invalidate();
        }
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        var scale = DeviceDpi / 96f;
        g.TranslateTransform(0, AutoScrollPosition.Y);
        g.ScaleTransform(scale, scale);
        var width = ClientSize.Width / scale;
        var x = 18f;
        var w = width - 36f;
        var y = 8f;
        Text(g, _snapshot?.PlanName is { Length: > 0 } name ? name : "API 余额与用量", x, y, w, 22, 11, Muted);
        y += 32;
        var message = _refreshing ? "正在刷新…" : _message;
        if (!string.IsNullOrWhiteSpace(message))
        {
            using var font = MakeFont(10);
            var h = Math.Max(42, g.MeasureString(message, font, (int)(w - 24)).Height + 20);
            Card(g, x, y, w, h, _error ? Color.FromArgb(90, 91, 56, 31) : Color.FromArgb(45, 222, 220, 216));
            Text(g, message, x + 12, y + 9, w - 24, h - 15, 10, Ink, wrap: true);
            y += h + 14;
        }
        if (_snapshot is { } s)
        {
            Card(g, x, y, w, 114);
            Text(g, s.Unit.Equals("credits", StringComparison.OrdinalIgnoreCase) ? "剩余额度" : "钱包余额", x + 14, y + 12, w - 28, 24, 11, Muted, bold: true);
            Text(g, UsageDisplay.Money(s.Balance, s.Unit), x + 14, y + 37, w - 28, 43, 30, Ink, bold: true);
            var valid = s.IsValid switch { true => "有效", false => "已停用", _ => "状态未知" };
            var meta = string.Join("  ·  ", new[] { valid, s.Mode, s.Unit }.Where(t => t.Length > 0));
            Text(g, meta, x + 14, y + 85, w - 28, 21, 10, Muted);
            y += 128;
            var cw = (w - 12) / 2;
            Metric(g, x, y, cw, UsageDisplay.SummaryTitle(s, true), UsageDisplay.SummaryValue(s, true));
            Metric(g, x + cw + 12, y, cw, UsageDisplay.SummaryTitle(s, false), UsageDisplay.SummaryValue(s, false));
            y += 80;
            Metric(g, x, y, cw, "今日请求", UsageDisplay.Count(s.TodayRequests));
            Metric(g, x + cw + 12, y, cw, "累计请求", UsageDisplay.Count(s.TotalRequests));
            y += 88;
            if (s.IsLocal || s.PeriodNote.Length > 0)
            {
                var note = s.IsLocal ? "本机记录：仅统计首次成功刷新后观测到的余额消耗。" : s.PeriodNote;
                Text(g, note, x, y, w, 36, 9, Muted, wrap: true);
                y += 42;
            }
            if (s.RateLimits.Count > 0)
            {
                Heading(g, "限额", x, ref y, w);
                foreach (var limit in s.RateLimits.Where(r => !string.IsNullOrWhiteSpace(r.Window)))
                {
                    Card(g, x, y, w, 65);
                    Text(g, UsageDisplay.WindowName(limit.Window), x + 12, y + 9, w * .35f, 22, 10, Ink);
                    var amount = s.HasTokens ? UsageDisplay.Count(limit.Used) + " / " + UsageDisplay.Count(limit.Limit)
                        : UsageDisplay.Money(limit.Used, s.Unit) + " / " + UsageDisplay.Money(limit.Limit, s.Unit);
                    Text(g, amount, x + w * .35f, y + 9, w * .65f - 12, 22, 10, Muted, right: true);
                    var ratio = limit.Limit is > 0 && limit.Used is { } used ? Math.Clamp(used / limit.Limit.Value, 0, 1) : 0;
                    using var track = new SolidBrush(Color.FromArgb(75, 255, 255, 255));
                    using var fill = new SolidBrush(ratio >= .9 ? Color.Salmon : ratio >= .7 ? Color.FromArgb(232, 177, 91) : Color.FromArgb(131, 194, 154));
                    g.FillRectangle(track, x + 12, y + 43, w - 24, 5);
                    g.FillRectangle(fill, x + 12, y + 43, (float)((w - 24) * ratio), 5);
                    y += 75;
                }
                y += 4;
            }
            Heading(g, "每日使用", x, ref y, w);
            if (s.DailyUsage.Count == 0)
            {
                Text(g, "暂无每日记录", x + 2, y, w, 25, 10, Muted);
                y += 34;
            }
            foreach (var row in s.DailyUsage.OrderByDescending(r => r.Date).Take(7))
            {
                Text(g, row.Date, x + 2, y, w / 2, 24, 11, Ink, bold: true);
                var amount = s.HasTokens ? UsageDisplay.Count(row.TotalTokens) : UsageDisplay.Money(row.Cost, s.Unit);
                Text(g, amount, x + w / 2, y, w / 2 - 2, 24, 11, Ink, bold: true, right: true);
                if (s.HasTokens)
                    Text(g, $"输入 {UsageDisplay.Count(row.InputTokens)} · 输出 {UsageDisplay.Count(row.OutputTokens)}", x + 2, y + 25, w, 20, 9, Muted);
                var detail = $"{UsageDisplay.Count(row.Requests)} 次请求";
                if (row.Cost.HasValue) detail += " · " + UsageDisplay.Money(row.Cost, s.Unit);
                Text(g, detail, x + 2, y + (s.HasTokens ? 46 : 25), w - 4, 20, 9, Muted, right: true);
                y += s.HasTokens ? 78 : 57;
            }
            y += 5;
            Heading(g, "累计明细", x, ref y, w);
            var details = s.HasTokens
                ? new List<(string, string)> { ("输入 token", UsageDisplay.Count(s.TotalInputTokens)), ("输出 token", UsageDisplay.Count(s.TotalOutputTokens)),
                    ("缓存创建", UsageDisplay.Count(s.CacheCreationTokens)), ("缓存读取", UsageDisplay.Count(s.CacheReadTokens)), ("总 token", UsageDisplay.Count(s.TotalTokens)) }
                : new List<(string, string)> { ("限额", UsageDisplay.Money(s.Quota?.Limit, s.Unit)), ("已用", UsageDisplay.Money(s.Quota?.Used ?? s.TotalAmount, s.Unit)),
                    ("剩余", UsageDisplay.Money(s.Quota?.Remaining ?? s.Balance, s.Unit)), ("今日使用", UsageDisplay.Money(s.TodayAmount, s.Unit)), ("累计使用", UsageDisplay.Money(s.TotalAmount, s.Unit)) };
            Card(g, x, y, w, details.Count * 27 + 20);
            var dy = y + 10;
            foreach (var (label, value) in details)
            {
                Text(g, label, x + 12, dy, w * .4f, 24, 10, Muted);
                Text(g, value, x + w * .4f, dy, w * .6f - 12, 24, 10, Ink, bold: true, right: true);
                dy += 27;
            }
            y += details.Count * 27 + 36;
        }
        else
        {
            Card(g, x, y, w, 114);
            Text(g, "连接你的 API 服务", x + 16, y + 18, w - 32, 30, 15, Ink, bold: true);
            Text(g, "点击右上角设置，填写服务商地址和密钥。\n保存后，这里会显示余额和使用记录。", x + 16, y + 55, w - 32, 49, 10, Muted, wrap: true);
            y += 140;
        }
        using var pen = new Pen(Color.FromArgb(55, 255, 255, 255));
        g.DrawLine(pen, x, y, x + w, y);
        y += 10;
        Text(g, _lastUpdated is { } time ? $"更新于 {time:HH:mm:ss}" : "等待刷新", x, y, w * .55f, 24, 9, Muted);
        Text(g, $"每 {_interval} 秒刷新", x + w * .55f, y, w * .45f, 24, 9, Muted, right: true);
        var contentHeight = (int)Math.Ceiling((y + 42) * scale);
        if (AutoScrollMinSize.Height != contentHeight) AutoScrollMinSize = new Size(0, contentHeight);
    }

    private void Heading(Graphics g, string title, float x, ref float y, float width)
    {
        Text(g, title, x, y, width, 25, 11, Muted, bold: true);
        y += 32;
    }
    private void Metric(Graphics g, float x, float y, float w, string title, string value)
    {
        Card(g, x, y, w, 68);
        Text(g, title, x + 12, y + 10, w - 24, 22, 10, Muted, bold: true);
        Text(g, value, x + 12, y + 31, w - 24, 30, 21, Ink, bold: true);
    }
    private static void Card(Graphics g, float x, float y, float w, float h, Color? color = null)
    {
        using var path = new GraphicsPath();
        const float d = 18;
        path.AddArc(x, y, d, d, 180, 90); path.AddArc(x + w - d, y, d, d, 270, 90);
        path.AddArc(x + w - d, y + h - d, d, d, 0, 90); path.AddArc(x, y + h - d, d, d, 90, 90);
        path.CloseFigure();
        using var shadow = (GraphicsPath)path.Clone();
        using var offset = new Matrix();
        offset.Translate(0, 3);
        shadow.Transform(offset);
        using var shade = new SolidBrush(Color.FromArgb(28, 0, 0, 0));
        g.FillPath(shade, shadow);
        using var brush = new SolidBrush(color ?? Color.FromArgb(24, 255, 255, 255));
        g.FillPath(brush, path);
        using var rim = new Pen(Color.FromArgb(28, 255, 255, 255), 1);
        g.DrawPath(rim, path);
    }
    private Font MakeFont(float size, bool bold = false) => new(_family, size * 96f / 72f, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);
    private new void Text(Graphics g, string text, float x, float y, float w, float h, float size, Color color, bool bold = false, bool right = false, bool wrap = false)
    {
        using var format = new StringFormat { Alignment = right ? StringAlignment.Far : StringAlignment.Near,
            LineAlignment = StringAlignment.Near, Trimming = StringTrimming.EllipsisCharacter,
            FormatFlags = wrap ? 0 : StringFormatFlags.NoWrap };
        if (!wrap)
        {
            using var measureFont = MakeFont(size, bold);
            var measured = g.MeasureString(text, measureFont).Width;
            if (measured > w) size = Math.Max(8, size * w / measured);
        }
        using var font = MakeFont(size, bold);
        using var brush = new SolidBrush(color);
        g.DrawString(text, font, brush, new RectangleF(x, y, w, h), format);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _family.Dispose();
        base.Dispose(disposing);
    }
}
