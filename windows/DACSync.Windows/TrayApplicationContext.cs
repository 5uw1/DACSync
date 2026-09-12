namespace DACSync.Windows;

/// <summary>
/// System tray equivalent of MenuBarView.swift — no main window, just a
/// tray icon with a right-click context menu. Windows tray icons can't
/// show live text the way a macOS menu bar item can (DACSync's Mac app
/// shows "96K" directly in the menu bar); status here goes in the icon's
/// tooltip instead, which is the idiomatic Windows equivalent.
/// </summary>
public sealed class TrayApplicationContext : ApplicationContext
{
    private readonly NotifyIcon _trayIcon;
    private readonly AudioDeviceManager _audio = new();
    private readonly ToolStripMenuItem _devicesHeader;

    public TrayApplicationContext()
    {
        var menu = new ContextMenuStrip();

        _devicesHeader = new ToolStripMenuItem("Output device") { Enabled = false };
        menu.Items.Add(_devicesHeader);
        menu.Items.Add(new ToolStripSeparator());
        // Device entries are inserted here on each refresh, before the
        // separator + Refresh/Exit items below.
        menu.Items.Add(new ToolStripSeparator());

        var refreshItem = new ToolStripMenuItem("Refresh devices", null, (_, _) => RefreshDevices());
        menu.Items.Add(refreshItem);

        var exitItem = new ToolStripMenuItem("Quit DACSync", null, (_, _) => Application.Exit());
        menu.Items.Add(exitItem);

        _trayIcon = new NotifyIcon
        {
            Icon = SystemIcons.Application, // TODO: replace with a real DACSync icon once one exists for Windows
            Text = "DACSync",
            ContextMenuStrip = menu,
            Visible = true,
        };

        menu.Opening += (_, _) => RefreshDevices();

        RefreshDevices();
    }

    private void RefreshDevices()
    {
        var menu = _trayIcon.ContextMenuStrip!;
        // Device items sit between the two separators added in the
        // constructor (index 2 = header, 3 = separator, so device items
        // start at index... simplest to just remove everything that isn't
        // one of the fixed items and rebuild).
        var fixedItems = new HashSet<ToolStripItem> { _devicesHeader };
        for (var i = menu.Items.Count - 1; i >= 0; i--)
        {
            if (menu.Items[i].Tag as string == "device")
            {
                menu.Items.RemoveAt(i);
            }
        }

        AudioDevice? current;
        List<AudioDevice> devices;
        try
        {
            devices = _audio.GetOutputDevices().ToList();
            current = _audio.GetDefaultOutputDevice();
        }
        catch (Exception ex)
        {
            _trayIcon.Text = $"DACSync — error listing devices: {ex.Message}";
            return;
        }

        var insertAt = menu.Items.IndexOf(_devicesHeader) + 2; // after header + its separator
        foreach (var device in devices)
        {
            var isCurrent = current is not null && device.Id == current.Id;
            var item = new ToolStripMenuItem(device.Name)
            {
                Checked = isCurrent,
                Tag = "device",
            };
            item.Click += (_, _) => SelectDevice(device);
            menu.Items.Insert(insertAt++, item);
        }

        _trayIcon.Text = current is null
            ? "DACSync — no default output device"
            : $"DACSync — {Truncate(current.Name, 50)}";
    }

    private void SelectDevice(AudioDevice device)
    {
        try
        {
            _audio.SetDefaultOutputDevice(device);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                $"Couldn't set \"{device.Name}\" as the default output device:\n{ex.Message}",
                "DACSync",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
        RefreshDevices();
    }

    // NotifyIcon.Text is capped at 63 characters by the Shell.
    private static string Truncate(string value, int maxLength) =>
        value.Length <= maxLength ? value : value[..maxLength];

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _audio.Dispose();
        }
        base.Dispose(disposing);
    }
}
