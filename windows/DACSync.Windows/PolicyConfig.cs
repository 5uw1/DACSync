using System.Runtime.InteropServices;

namespace DACSync.Windows;

/// <summary>
/// Windows has no *public* API to set the system's default audio output
/// device — the equivalent of setting kAudioHardwarePropertyDefaultOutputDevice
/// on macOS. Every third-party device switcher (SoundSwitch, NirCmd, EarTrumpet
/// and friends) relies on this same undocumented COM interface, reverse
/// engineered from audiopolicy.dll years ago and stable across Windows 7
/// through 11 in practice.
///
/// UNVERIFIED: written on macOS with no Windows machine to test against.
/// The interface's method *order* below defines its COM vtable layout —
/// if it's wrong, calls either throw or silently do nothing (not crash,
/// since this is a classic dual-interface COM object). If SetDefaultEndpoint
/// doesn't work when actually run, this file — not the caller — is almost
/// certainly why. Re-derive the vtable order against a known-current
/// reference implementation before assuming anything else is broken.
/// </summary>
internal static class PolicyConfig
{
    private const string ClsidPolicyConfigClient = "870af99c-171d-4f9e-af0d-e63df40c2bc9";

    [ComImport]
    [Guid(ClsidPolicyConfigClient)]
    private class CPolicyConfigClient
    {
    }

    private enum ERole
    {
        eConsole = 0,
        eMultimedia = 1,
        eCommunications = 2,
    }

    [Guid("F8679F50-850A-41CF-9C72-430F290290C8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPolicyConfig
    {
        int GetMixFormat(string endpointId, out IntPtr format);
        int GetDeviceFormat(string endpointId, bool defaultFormat, out IntPtr format);
        int ResetDeviceFormat(string endpointId);
        int SetDeviceFormat(string endpointId, IntPtr endpointFormat, IntPtr mixFormat);
        int GetProcessingPeriod(string endpointId, bool defaultPeriod, out long defaultPeriodOut, out long minimumPeriodOut);
        int SetProcessingPeriod(string endpointId, long period);
        int GetShareMode(string endpointId, out IntPtr shareMode);
        int SetShareMode(string endpointId, IntPtr shareMode);
        int GetPropertyValue(string endpointId, bool fFxStore, ref PropertyKey key, out PropVariant value);
        int SetPropertyValue(string endpointId, bool fFxStore, ref PropertyKey key, ref PropVariant value);
        int SetDefaultEndpoint(string endpointId, ERole role);
        int SetEndpointVisibility(string endpointId, bool visible);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey
    {
        public Guid fmtid;
        public int pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropVariant
    {
        public ushort vt;
        public ushort wReserved1;
        public ushort wReserved2;
        public ushort wReserved3;
        public IntPtr data;
        public IntPtr data2;
    }

    /// <summary>
    /// Makes <paramref name="endpointId"/> (an MMDevice's ID string) the
    /// system default output device for all three roles NAudio/most apps
    /// care about (console/system sounds, multimedia playback,
    /// communications) — mirrors picking it from the Sound Control Panel
    /// or right-click "Set as default device."
    /// </summary>
    public static void SetDefaultEndpoint(string endpointId)
    {
        var policyConfig = (IPolicyConfig)new CPolicyConfigClient();
        try
        {
            Marshal.ThrowExceptionForHR(policyConfig.SetDefaultEndpoint(endpointId, ERole.eConsole));
            Marshal.ThrowExceptionForHR(policyConfig.SetDefaultEndpoint(endpointId, ERole.eMultimedia));
            Marshal.ThrowExceptionForHR(policyConfig.SetDefaultEndpoint(endpointId, ERole.eCommunications));
        }
        finally
        {
            Marshal.ReleaseComObject(policyConfig);
        }
    }
}
