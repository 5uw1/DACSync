# PureRate

A menu-bar service that keeps your Mac's audio output device's sample rate
(and eventually bit depth) matched to whatever is actually playing, so macOS
never has to resample before handing audio to your DAC/amp.

Phase 1 targets Apple Music (which surfaces Lossless / Hi-Res Lossless
tracks at varying rates). Windows and a browser extension for YouTube are
planned for later phases — see [Roadmap](#roadmap).

## How it works

There is no public API for "what format is Apple Music currently decoding."
The approach here — the same one used by the prior art
[LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher) (GPL-3.0;
no code from that project is reused here, only the general technique) — is:

1. **Detect**: shell out to `/usr/bin/log stream`, filtered to Music.app's
   processes, and pattern-match log lines for sample rate / bit depth text
   (`PlaybackFormatMonitor.swift`, `FormatLineParser`).
2. **Switch**: when a new format is detected, use CoreAudio's HAL APIs to
   set the target output device's nominal sample rate to match — picking an
   exact match if the DAC supports it, otherwise the closest rate in the
   same 44.1kHz/48kHz family (`CoreAudioController.swift`).
3. **Hold the device** (optional): "hog mode" takes exclusive access to the
   output device so the shared system mixer can't reopen it at a mismatched
   rate mid-track.
4. **Match bit depth** (optional, needs exclusive access): sets each output
   stream's *physical* format (`kAudioStreamPropertyPhysicalFormat`) — the
   actual hardware wire format, separate from the device-wide nominal
   sample rate — to the source's bit depth where the DAC offers more than
   one (`CoreAudioController.matchBitDepth`).
5. **Sync on launch / periodically**: `log stream` only sees *new* log
   lines, so a track already playing before PureRate (re)launched is
   otherwise invisible until the next track change. `MusicScriptBridge`
   asks Music directly via AppleScript (`sample rate of current track` —
   an officially exposed property, confirmed accurate) right at launch and
   every 20s afterward, closing that gap for sample rate (it doesn't expose
   bit depth, so that still comes from the log-based detection above).

The menu bar shows the current format as text (e.g. `96K/24`,
`AppState.menuBarTitle`) instead of a static icon.

### Exclusive access / bit depth — verified against a real DAC

Confirmed end-to-end against a **FiiO K13 R2R** USB DAC: Hog Mode engages
correctly (read back with the app's own PID as owner), and bit-depth
switching applies for real — a 24-bit source round to the DAC's nearest
available depth (16/32, no exact 24-bit option on this unit) at the
matching sample rate, verified by reading the stream's physical format
straight back from CoreAudio after each switch. `setHogMode` still reads
the property back rather than trusting the write's status, and surfaces
`ControllerError.hogModeNotSupported` / `exclusiveAccessActuallyHeld` in the
UI for hardware that can't hold it at all — built-in Mac audio, notably,
never supports Hog Mode — so bit depth switching won't keep retrying there.

### Device re-enumeration (and why it especially bites Hog Mode)

Changing a stream's *physical* format can make CoreAudio re-enumerate the
device under a **new AudioDeviceID**, unlike a plain nominal-rate change.
On the DAC above, *engaging or releasing Hog Mode itself* was also observed
doing this — almost certainly the USB interface briefly resetting for an
internal relay/clock reconfiguration. Since quitting PureRate releases Hog
Mode, relaunching right away can race that reset and catch the device
mid-disappearance.

Two things handle this:
- `AppState` watches `kAudioHardwarePropertyDevices` and re-resolves
  `targetDeviceID` by name when the cached ID goes stale
  (`CoreAudioController.deviceExists`, `AppState.handleDeviceListChanged`).
- The target device is now persisted **by name**, not just ID
  (`targetDeviceName` in `UserDefaults`), with a short retry on launch if
  the name isn't found immediately. This matters because the system's own
  "default output device" pointer isn't reliable to fall back on either —
  on a multi-device Mac, another audio device flickering in as default
  (observed here) would otherwise hijack the target away from the DAC the
  user actually chose.

### Log line patterns — verified against real output

`FormatLineParser`'s regexes were captured live from Music.app on macOS 26.6
(see the commit history) while switching between an AAC track, a
44.1kHz/16-bit Lossless track, and a 96kHz/24-bit Hi-Res Lossless one — not
guessed. Confirmed end-to-end: the app switched a real output device from
44.1kHz to 48kHz automatically the instant a matching track started.

The three matched lines (`fpfs_ReportAudioPlaybackThroughFigLog`'s
`[BitDepth]`/`[SampleRate]` tags, `ACAppleLosslessDecoder`'s "Input format"
line, and the `ampplay` `mediaFormatinfo` line) only ever fire while Music is
actually decoding ALAC — the AAC track produced none of them — so a match is
inherently a lossless-playback signal.

Apple doesn't document these strings, though, so a future macOS/Music
update can change them. If `PureRate` stops detecting changes:

1. Run the app, open the menu, enable **Show raw log matches**.
2. Play a Lossless/Hi-Res track in Apple Music and watch for lines there.
3. If nothing shows up, recapture manually:
   ```bash
   log stream --style compact --level debug --predicate \
     'process == "Music" AND (eventMessage CONTAINS "BitDepth" OR eventMessage CONTAINS "ACAppleLosslessDecoder" OR eventMessage CONTAINS "PBAudioFormat" OR eventMessage CONTAINS "mediaFormatinfo")'
   ```
   while switching tracks, and adjust the regexes in
   `Sources/PureRate/PlaybackFormatMonitor.swift` to match what you see.

### Requirements

- macOS 13+
- The logged-in user must be an **admin** account — reading the unified log
  live (`log stream`) requires it, same as LosslessSwitcher.
- Not sandboxed (needs to shell out to `log` and call CoreAudio HAL device
  APIs directly).

## Building & running

For development (rebuild-and-relaunch loop):

```bash
swift build
swift run
```

The app lives in the menu bar (waveform icon) — no Dock icon, no windows.
Open the menu to pick the target output device, toggle auto-switch and
exclusive access, and watch the detected format.

Note: `swift run` does **not** support the Launch at Login toggle —
`SMAppService.mainApp` (`LaunchAtLogin.swift`) only works when PureRate is
actually running as a bundled `.app`. Use the packaged build below to test
that.

### Packaged `.app` (for real use / Login Item)

```bash
scripts/build-app.sh
open build/PureRate.app
```

This builds a release binary and hand-assembles `build/PureRate.app`
(`Contents/MacOS`, `Contents/Info.plist`, ad-hoc code signature) — there's
no Xcode project here to Archive, since this is a plain SwiftPM package.
To actually run at login, move `PureRate.app` somewhere stable (e.g.
`/Applications`) first, then toggle **Launch at login** from the menu; it
shows up under System Settings → General → Login Items afterward.

If you have an Apple Developer ID, sign with that instead of ad hoc
(edit the `codesign` line in `scripts/build-app.sh`) — a Login Item
registered under a real signing identity survives rebuilds more reliably
than one registered under an ad-hoc signature, which changes on every
build.

## Roadmap

- [x] macOS: detect Apple Music format via log scraping, auto-switch output
      device sample rate via CoreAudio (this repo, phase 1)
- [x] macOS: proper `.app` packaging (`scripts/build-app.sh`) and a
      Launch at Login toggle (`SMAppService.mainApp`)
- [x] macOS: bit-depth-aware exclusive-mode stream format selection
      (`CoreAudioController.matchBitDepth`) — verified end-to-end against
      a real external DAC (FiiO K13 R2R), see above
- [ ] macOS: custom app icon, Developer ID signing & notarization
- [ ] Windows: WASAPI exclusive-mode equivalent (C++ or C#), format
      detection strategy TBD per source app (no Apple Music on Windows —
      likely Tidal/Qobuz-specific approaches)
- [ ] Browser extension (Chrome/Firefox) for YouTube: bridges to the native
      app via Native Messaging; scope limited by the fact that YouTube
      transcodes audio (Opus/AAC, fixed rates) so there's no "source format"
      to match the way there is with Apple Music Lossless

## License

MIT — see [LICENSE](LICENSE). This is an independent implementation; it does
not incorporate code from LosslessSwitcher (GPL-3.0), only the publicly
documented technique.
