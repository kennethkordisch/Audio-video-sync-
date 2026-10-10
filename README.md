# AVSyncMeter

A native iOS app (SwiftUI, iOS 17+) that measures how far out of sync a display and its
sound system are, from the audience position, using only the iPhone's camera and microphone.

Built for checking Avid Media Composer playback chains (desktop and hardware I/O), but it
works on any TV, monitor or projector.

It plays or exports a **test pattern** (full-screen white flash + 1 kHz beep every 2 s, at
23.976 / 24 / 25 / 29.97 / 30 / 50 / 59.94 / 60 fps), watches the screen at up to 240 fps,
listens for the beep, and reports:

* **Offset at the phone**: beep time minus flash time, as experienced in that seat.
* **Offset at the screen**: the same, with the sound's travel time over the measured
  distance removed. This is what the TV / projector / AVR chain itself is doing.

* **Drift** (optional timed run): a robust straight-line fit of offset versus time, in
  ms/min, frames/hour and ppm, matched against the usual culprits (0.1% pull-down mismatch,
  24/25, 44.1/48 kHz), plus detection of sudden half-frame-or-larger steps (frame slips).

Everything is shown in milliseconds and in **frames at the project frame rate** you pick in
Settings, and every run can be exported as CSV.

Positive numbers mean audio **lags** the picture, negative means audio **leads**.
Results are compared against EBU R37 (-40 / +60 ms) and ITU-R BT.1359 thresholds.

## Do I need a test file?

Yes. Sync can only be measured against content where a visual event and an audio event are
*known* to be simultaneous. Ordinary video has no such reference. One 60 s pattern per frame
rate is bundled in the app (`AVSyncMeter/Resources/avsync_1080p*.mp4`, about 0.6 MB each).
Events sit on exact frame boundaries at each rate, so 23.976 and 29.97 files carry no
sub-frame bias of their own.

Regenerate or make longer / Avid-native versions with `tools/make_test_pattern.sh` (needs ffmpeg):

```
tools/make_test_pattern.sh                       # all 8 rates, 60 s, H.264/AAC MP4
tools/make_test_pattern.sh -d 1800 -m 23.976     # 30 min 23.976 file + DNxHR LB / 24-bit PCM MXF for Avid
tools/make_test_pattern.sh -d 600 -p 24          # 10 min 24 fps file + ProRes 422 Proxy / 24-bit PCM .mov for Resolve / QuickTime
tools/make_test_pattern.sh -p -P lt 24           # same, ProRes 422 LT (also: 422, hq)
tools/make_test_pattern.sh -m -p all             # every rate, all three formats
tools/make_test_pattern.sh -o ~/Desktop 25       # 25 fps only, to another folder
```

| Format | Flag | For | Notes |
|---|---|---|---|
| H.264 + AAC, MP4 | always | app bundle, AirPlay, quick checks | small; AAC adds about +-2 ms of onset smear |
| DNxHR LB + 24-bit PCM, OP1a MXF | `-m` | Avid Media Composer link/import | no transcode, no codec delay, ~5 MB/s |
| ProRes 422 Proxy + 24-bit PCM, QuickTime .mov | `-p` (`-P lt/422/hq` for other flavours) | DaVinci Resolve, QuickTime Player, Premiere, Avid via link | 10-bit, Rec.709 tagged, Proxy ~6 MB/s, LT ~13 MB/s |

Use the PCM variants for the real test and keep the MP4 for quick checks. Use a long file
for drift runs: the phone's looping player adds a jump at every loop boundary.

Why a flash + beep and not something fancier: a full-frame white step gives the camera the
largest possible luminance change (so it works on dim projectors and small screens in the
frame), and a hard-onset 1 kHz burst gives the microphone a sharp edge that survives TV
speakers, soundbars, AAC and Bluetooth, while onset detection ignores room echoes.

## How distance is detected

1. **LiDAR** (iPhone Pro / iPad Pro): ARKit scene depth at the image centre, median of ~25
   frames. Works to about 5 m.
2. **Camera estimate** (any iPhone): when the screen flashes white, the app finds the lit
   rectangle, and with the camera's focal length (delivered per frame by AVFoundation) and
   the screen diagonal you enter in Settings computes `distance = f_px * diagonal / diagonal_px`.
   Works at any distance as long as the whole screen is in view.
3. **Manual** entry in Settings overrides both.

Sound travels about 2.9 ms per metre (temperature adjustable in Settings).

## Using it with Media Composer

1. In Settings, pick the project frame rate. Export the matching MP4 from the Test Pattern
   tab (or render the MXF as above), link/import it into a bin, drop it in a sequence and
   play out through the monitor and speakers under test.
2. Measure from the editor's seat. Compare: desktop playback vs. hardware I/O (AJA,
   Blackmagic, Avid DNxIO/DNxIQ), HDMI vs. SDI monitor, with and without any output delay
   setting (e.g. Video Display Settings > Desktop Play Delay), to see what each stage adds.
3. For drift, switch on Drift mode in Settings (1 to 60 min), use a long pattern file, and
   read the slope. 60 ms/min means a 1000/1001 clock mismatch somewhere (23.976 project with
   24 fps media or a 48.048 kHz audio clock, for instance).

## Using it with Resolve or QuickTime Player

Render the ProRes Proxy .mov (`-p`, or `-P lt` for LT), drop it on a timeline at the matching project rate (or open
it directly in QuickTime Player) and play out to the monitor under test. Measure the same
way. In Resolve this is a direct check of the Video I/O "audio offset" setting under
Preferences > Video and Audio I/O.

## Using it in general

1. Put the pattern on the screen under test. Prefer playing it from the *real* source
   (export via AirDrop / Files to a USB stick, media player, PC, Apple TV) so the whole
   chain is measured. For a quick check, the Test Pattern tab can AirPlay it to an Apple TV.
2. In Measure, aim the back camera at the screen with the entire screen in view and some
   dark border around it, and tap **Start**. Hold still through the "settling" phase while the
   exposure is locked.
3. After 20 events (about 40 s, adjustable) it stops and shows the result, spread (MAD) and
   the individual recent offsets.

## Building

Requires Xcode 16 or newer and a physical iPhone (the simulator has no camera).

1. Open `AVSyncMeter.xcodeproj`.
2. Select the AVSyncMeter target, set your Team under Signing & Capabilities, and change the
   bundle identifier if you like.
3. Run on the device.

The project uses Xcode 16's folder-synchronised groups, so every file under `AVSyncMeter/`
is part of the target automatically. If the project file ever fails to open, recreate it:
File > New > Project > iOS App (SwiftUI, Swift), name it `AVSyncMeter`, delete the generated
Swift files and `Assets.xcassets`, drag this repository's `AVSyncMeter` folder into the
project, and add the two privacy strings (`NSCameraUsageDescription`,
`NSMicrophoneUsageDescription`) in the target's Info tab.

## Repository layout

```
AVSyncMeter/                      app sources (Swift)
  Analysis/   FlashDetector, BeepDetector, SyncAnalyzer, DriftAnalyzer, AnalysisPipeline, standards, stats
  Capture/    AVCaptureSession engine, luminance sampler, audio conversion
  Distance/   LiDAR ranger, screen-size (pinhole) ranger, speed of sound
  Measure/    measurement state machine + UI + camera preview + CSV export
  Pattern/    test-pattern constants, player / AirPlay / export view
  Settings/   user settings + view
  Resources/  avsync_1080p{2398,24,25,2997,30,50,5994,60}.mp4 (bundled test patterns, 60 s each)
AVSyncMeter.xcodeproj/
tools/make_test_pattern.sh        regenerates the test pattern with ffmpeg
tools/validate_pattern.py         checks the pattern's internal timing and simulates the detectors
docs/METHOD.md                    measurement method, error budget, limitations
```

## Accuracy

See `docs/METHOD.md`. In simulation the detectors recover a known offset to within 0.3 ms
with a spread of about 0.05 ms. In practice the floor is set by the display: a 60 Hz panel
updates every 16.7 ms and scans top to bottom over that interval, so expect the result to be
stable to a few ms and to depend slightly on where on the screen you look. Camera and
microphone timestamps come from the same AVCaptureSession clock and are aligned by iOS to
within a few ms (this is what keeps the Camera app's recordings in sync); there is an
"extra camera offset" setting to calibrate that out if you have a reference.
