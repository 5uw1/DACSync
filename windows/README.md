# DACSync for Windows

A system tray utility for picking your audio output device and seeing
whether something else currently has it locked in WASAPI exclusive mode.

## Why this is smaller in scope than the macOS app

DACSync on macOS exists because Apple Music has **no bit-perfect output
capability at all** — the OS forces every app through a shared mixer at a
fixed sample rate, so the only way to get bit-perfect playback is an
external tool that watches what's playing and changes the device's format
to match.

Windows doesn't have the same gap. Tidal and Qobuz have shipped native
WASAPI Exclusive Mode for years, and as of March 2026 Spotify has it too —
all three negotiate bit-perfect output with the DAC themselves, no
external switcher needed. Building a literal port of the macOS app (watch
a streaming app's logs, auto-switch a shared device's format) would be
solving a problem that mostly doesn't exist here anymore.

So this is a **device convenience utility** instead: pick which output
device is the system default, and see whether it's currently unavailable
because another app is holding it exclusively — useful regardless of
which app is playing, without trying to detect or match formats.

## ⚠️ Status: built on macOS, not yet run on Windows

Everything here compiles cleanly (`dotnet build` / `dotnet publish -r
win-x64 --self-contained` both succeed, verified on macOS via
`EnableWindowsTargeting`) but **has never actually been launched on a
Windows machine**, because this was written entirely from a Mac. Two
pieces specifically need real-hardware verification before trusting this:

1. **`PolicyConfig.cs`** — the interface used to set the system default
   audio device. Windows has no *public* API for this at all; every
   third-party device switcher (SoundSwitch, NirCmd, EarTrumpet and
   friends) relies on the same reverse-engineered, undocumented COM
   interface. The method order in the interface declaration defines its
   COM vtable layout — if it's subtly wrong, calls will throw or silently
   no-op rather than crash. If `SetDefaultOutputDevice` doesn't work, this
   file is almost certainly why; re-derive the vtable order against a
   current known-good reference before assuming anything else is broken.
2. **`AudioDeviceManager.IsHeldExclusivelyByAnotherProcess`** — probes for
   an exclusive-mode conflict by briefly trying to open the device
   exclusively itself. The failure mode when *something else* holds it
   exclusively vs. when the device just doesn't support that format at
   all hasn't been distinguished or tested.

Also missing: an app icon (`.ico` — macOS has no built-in PNG→ICO packer,
and none has been generated on Windows yet either; the tray icon
currently falls back to a generic system icon).

## Building & running

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download) on
Windows (or `EnableWindowsTargeting` lets `dotnet build` at least
type-check from macOS/Linux, without producing something runnable there).

```powershell
cd windows/DACSync.Windows
dotnet run
```

For a distributable, self-contained build (no .NET runtime needed on the
target machine, matching how the macOS build is a standalone `.app`):

```powershell
dotnet publish -r win-x64 --self-contained -c Release -o publish
```

## Architecture

- **`AudioDeviceManager.cs`** — wraps NAudio's WASAPI device enumeration
  (`MMDeviceEnumerator`) for listing/reading devices, plus
  `PolicyConfig.SetDefaultEndpoint` for switching. Roughly analogous to
  `CoreAudioController.swift`, but far smaller since there's no format
  auto-matching to do.
- **`PolicyConfig.cs`** — the undocumented `IPolicyConfig` COM interop
  (see the warning above).
- **`TrayApplicationContext.cs`** — the tray icon + right-click device
  menu, roughly analogous to `MenuBarView.swift`. Windows tray icons can't
  show live text the way the macOS menu bar item shows e.g. `96K`, so
  status goes in the icon's tooltip instead.

CI (`.github/workflows/windows-build.yml`) builds and publishes on every
push touching `windows/`, uploading the result as a workflow artifact —
not yet attached to GitHub Releases like the macOS build is, since this
hasn't been confirmed working on real hardware yet.

## Roadmap

- [ ] Actually run this on a Windows machine and fix whatever the COM
      interop gets wrong
- [ ] Real app icon (`.ico`)
- [ ] Once verified: wire into the release workflow so tagged releases
      ship a Windows build alongside the macOS one
- [ ] Code signing (Authenticode) — unsigned `.exe`s trigger a Windows
      SmartScreen warning on first run, the rough equivalent of macOS's
      Gatekeeper "unidentified developer" prompt
