using System.Drawing;
using System.Windows.Forms;

namespace QuotaMeterWindows;

internal sealed class QuotaApplicationContext : ApplicationContext
{
    private readonly MainForm _mainForm;
    private readonly NotifyIcon _trayIcon;

    public QuotaApplicationContext()
    {
        _mainForm = new MainForm(SettingsStore.Load());
        _trayIcon = new NotifyIcon
        {
            Text = "QuotaMeter",
            Icon = IconLoader.Load(),
            Visible = true,
            ContextMenuStrip = BuildMenu()
        };
        _trayIcon.DoubleClick += (_, _) => ShowMainWindow();
        ShowMainWindow();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _mainForm.Dispose();
        }

        base.Dispose(disposing);
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开", null, (_, _) => ShowMainWindow());
        menu.Items.Add("刷新", null, async (_, _) => await _mainForm.RefreshDataAsync());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => ExitApplication());
        return menu;
    }

    private void ShowMainWindow()
    {
        if (_mainForm.WindowState == FormWindowState.Minimized)
        {
            _mainForm.WindowState = FormWindowState.Normal;
        }

        _mainForm.Show();
        _mainForm.Activate();
        _mainForm.BringToFront();
    }

    private void ExitApplication()
    {
        _mainForm.AllowClose();
        _trayIcon.Visible = false;
        _mainForm.Close();
        ExitThread();
    }
}
