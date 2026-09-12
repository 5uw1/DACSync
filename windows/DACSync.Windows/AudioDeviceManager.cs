using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace DACSync.Windows;

public record AudioDevice(string Id, string Name);

/// <summary>
/// Thin wrapper over NAudio's WASAPI device enumeration plus the
/// undocumented default-device-switching COM interface (PolicyConfig.cs).
/// Analogous to CoreAudioController.swift on the macOS side, but Windows'
/// architecture is different enough that this deliberately does much
/// less: WASAPI exclusive mode lets an app negotiate bit-perfect output
/// directly (Tidal/Qobuz/Spotify all do this natively as of 2026), so
/// there's no macOS-style "watch a source app's logs and force the shared
/// device's format" problem to solve here. This only handles device
/// selection and exclusive-mode conflict awareness.
/// </summary>
public sealed class AudioDeviceManager : IDisposable
{
    private readonly MMDeviceEnumerator _enumerator = new();

    public IReadOnlyList<AudioDevice> GetOutputDevices()
    {
        var collection = _enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active);
        var devices = new List<AudioDevice>();
        foreach (var device in collection)
        {
            devices.Add(new AudioDevice(device.ID, device.FriendlyName));
            device.Dispose();
        }
        return devices;
    }

    public AudioDevice? GetDefaultOutputDevice()
    {
        try
        {
            using var device = _enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            return new AudioDevice(device.ID, device.FriendlyName);
        }
        catch (Exception)
        {
            // No default device configured (e.g. all outputs disabled).
            return null;
        }
    }

    /// <summary>
    /// Makes <paramref name="device"/> the system default output — same
    /// effect as picking it from the Sound Control Panel or the taskbar
    /// speaker icon's device list.
    /// </summary>
    public void SetDefaultOutputDevice(AudioDevice device)
    {
        PolicyConfig.SetDefaultEndpoint(device.Id);
    }

    /// <summary>
    /// Whether some other process currently holds <paramref name="device"/>
    /// in WASAPI exclusive mode — the Windows equivalent of macOS Hog Mode
    /// being held by someone else. Probes by briefly trying to open the
    /// device exclusively ourselves; if that fails, something else already
    /// has it. Immediately releases our own probe either way, so this
    /// never itself holds the device.
    /// </summary>
    public bool IsHeldExclusivelyByAnotherProcess(AudioDevice device)
    {
        using var mmDevice = new MMDeviceEnumerator().GetDevice(device.Id);
        try
        {
            using var probe = new WasapiOut(mmDevice, AudioClientShareMode.Exclusive, useEventSync: true, latency: 100);
            probe.Init(new SilenceProvider(mmDevice.AudioClient.MixFormat));
            return false;
        }
        catch (Exception)
        {
            // Could also mean the device doesn't support exclusive mode at
            // this format at all, not just "someone else has it" — but in
            // practice AUDCLNT_E_DEVICE_IN_USE is by far the common case,
            // and either way the honest answer is "we can't get exclusive
            // access right now," which is what callers actually care about.
            return true;
        }
    }

    public void Dispose() => _enumerator.Dispose();
}
