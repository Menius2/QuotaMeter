using System.Drawing;
using System.Drawing.Drawing2D;

namespace QuotaMeterWindows;

internal static class IconLoader
{
    public static Icon Load()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "app-icon.png");
        if (!File.Exists(path))
        {
            return SystemIcons.Application;
        }

        try
        {
            using var bitmap = new Bitmap(path);
            using var resized = new Bitmap(64, 64);
            using (var graphics = Graphics.FromImage(resized))
            {
                graphics.SmoothingMode = SmoothingMode.HighQuality;
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.DrawImage(bitmap, new Rectangle(0, 0, 64, 64));
            }

            return Icon.FromHandle(resized.GetHicon());
        }
        catch
        {
            return SystemIcons.Application;
        }
    }
}
