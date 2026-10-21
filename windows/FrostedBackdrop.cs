using System.ComponentModel;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace QuotaMeterWindows;

// Windows 10 accent blur ignores the HWND's rounded region. Render the background
// before showing the popup so both the glass and the content share the same clip.
internal static class FrostedBackdrop
{
    // A fixed neutral tone keeps white text legible even over a white desktop.
    // The same transform is used for every background; there is no theme switching.
    private const float Detail = .24f;
    private const float BaseShade = .06f;

    public static Bitmap? Capture(Rectangle bounds, float dpiScale)
    {
        if (SystemInformation.HighContrast || bounds.Width <= 0 || bounds.Height <= 0) return null;
        try
        {
            // Sample beyond the edges so the blur cannot smear edge text into a rim.
            var padding = Math.Max(48, (int)Math.Ceiling(48 * dpiScale));
            var captureBounds = Rectangle.Inflate(bounds, padding, padding);
            using var screen = new Bitmap(captureBounds.Width, captureBounds.Height, PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(screen))
            {
                graphics.Clear(Color.FromArgb(28, 28, 28));
                var visible = Rectangle.Intersect(captureBounds, SystemInformation.VirtualScreen);
                if (visible.IsEmpty) return null;
                graphics.CopyFromScreen(visible.Location, new Point(visible.X - captureBounds.X, visible.Y - captureBounds.Y), visible.Size);
            }

            // Downsample before three box passes (a Gaussian approximation).
            // The image stays in memory only while the popup is open.
            using var small = new Bitmap(Math.Max(1, screen.Width / 4), Math.Max(1, screen.Height / 4), PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(small))
            {
                graphics.InterpolationMode = InterpolationMode.HighQualityBilinear;
                graphics.DrawImage(screen, new Rectangle(Point.Empty, small.Size));
            }
            Blur(small, Math.Max(2, (int)Math.Round(4 * dpiScale)));

            var result = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
            try
            {
                using var graphics = Graphics.FromImage(result);
                using var edges = new ImageAttributes();
                edges.SetWrapMode(WrapMode.TileFlipXY);
                edges.SetColorMatrix(new ColorMatrix([
                    [.2126f * Detail, .2126f * Detail, .2126f * Detail, 0, 0],
                    [.7152f * Detail, .7152f * Detail, .7152f * Detail, 0, 0],
                    [.0722f * Detail, .0722f * Detail, .0722f * Detail, 0, 0],
                    [0, 0, 0, 1, 0],
                    [BaseShade, BaseShade, BaseShade, 0, 1]
                ]));
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.DrawImage(small, new Rectangle(-padding, -padding, captureBounds.Width, captureBounds.Height), 0, 0, small.Width, small.Height, GraphicsUnit.Pixel, edges);
                return result;
            }
            catch { result.Dispose(); throw; }
        }
        catch (Win32Exception) { return null; }
        catch (ExternalException) { return null; }
        catch (ArgumentException) { return null; }
    }

    private static void Blur(Bitmap bitmap, int radius)
    {
        var bits = bitmap.LockBits(new Rectangle(Point.Empty, bitmap.Size), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        try
        {
            var pixels = new byte[bits.Stride * bits.Height];
            var scratch = new byte[pixels.Length];
            Marshal.Copy(bits.Scan0, pixels, 0, pixels.Length);
            for (var pass = 0; pass < 3; pass++)
            {
                BoxPass(pixels, scratch, bits.Width, bits.Height, bits.Stride, radius, horizontal: true);
                BoxPass(scratch, pixels, bits.Width, bits.Height, bits.Stride, radius, horizontal: false);
            }
            Marshal.Copy(pixels, 0, bits.Scan0, pixels.Length);
        }
        finally { bitmap.UnlockBits(bits); }
    }

    private static void BoxPass(byte[] source, byte[] target, int width, int height, int stride, int radius, bool horizontal)
    {
        var lines = horizontal ? height : width;
        var length = horizontal ? width : height;
        var step = horizontal ? 4 : stride;
        var lineStep = horizontal ? stride : 4;
        var divisor = radius * 2 + 1;
        for (var line = 0; line < lines; line++)
        {
            for (var channel = 0; channel < 4; channel++)
            {
                var start = line * lineStep + channel;
                var sum = 0;
                for (var offset = -radius; offset <= radius; offset++)
                    sum += source[start + Math.Clamp(offset, 0, length - 1) * step];
                for (var position = 0; position < length; position++)
                {
                    target[start + position * step] = (byte)(sum / divisor);
                    sum += source[start + Math.Min(position + radius + 1, length - 1) * step]
                        - source[start + Math.Max(position - radius, 0) * step];
                }
            }
        }
    }
}
