using System.Drawing.Drawing2D;

namespace QuotaMeterWindows;

internal sealed class HeaderActionButton(string action) : Button
{
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var scale = Math.Min(Width, Height) / 38f;
        g.TranslateTransform(Width / 2f, Height / 2f);
        g.ScaleTransform(scale, scale);
        using var pen = new Pen(ForeColor, 2.3f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        switch (action)
        {
            case "刷新":
                g.DrawArc(pen, -9, -9, 18, 18, -55, 305);
                g.DrawLines(pen, [new PointF(2, -11), new PointF(7, -8), new PointF(3, -4)]);
                break;
            case "设置":
                g.DrawEllipse(pen, -7, -7, 14, 14);
                g.DrawEllipse(pen, -2.5f, -2.5f, 5, 5);
                for (var i = 0; i < 8; i++)
                {
                    var a = i * Math.PI / 4;
                    g.DrawLine(pen, (float)Math.Cos(a) * 7, (float)Math.Sin(a) * 7, (float)Math.Cos(a) * 10, (float)Math.Sin(a) * 10);
                }
                break;
            case "退出":
                g.DrawArc(pen, -9, -9, 18, 18, -50, 280);
                g.DrawLine(pen, 0, -11, 0, -1);
                break;
        }
    }
}
