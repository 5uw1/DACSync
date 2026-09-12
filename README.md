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

```bash
swift build
swift run
```

The app lives in the menu bar (waveform icon) — no Dock icon, no windows.
Open the menu to pick the target output device, toggle auto-switch and
exclusive access, and watch the detected format.

For a distributable `.app` (code signing, custom icon, Login Item), open
`Package.swift` in Xcode and use Product → Archive, or wrap the built
executable in an `.app` bundle with your own `Info.plist`.

## Roadmap

- [x] macOS: detect Apple Music format via log scraping, auto-switch output
      device sample rate via CoreAudio (this repo, phase 1)
- [ ] macOS: bit-depth-aware exclusive-mode stream format selection where
      the DAC exposes more than one physical format
- [ ] macOS: Login Item / launch-at-login, proper `.app` packaging & signing
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
