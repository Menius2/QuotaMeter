using System.Windows.Forms;

namespace QuotaMeterWindows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new QuotaApplicationContext());
    }
}
