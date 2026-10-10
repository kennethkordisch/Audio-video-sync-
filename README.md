# AVSyncMeter

A native iOS app (SwiftUI, iOS 17+) that measures how far out of sync a display and its
sound system are, from the audience position, using only the iPhone's camera and microphone.

It plays or exports a **test pattern** (full-screen white flash + 1 kHz beep every 2 s),
watches the screen at up to 240 fps, listens for the beep, and reports:

* **Offset at the phone**: beep time minus flash time, as experienced in that seat.
* **Offset at the screen**: the same, with the sound's travel time over the measured
  distance removed. This is what the TV / projector / AVR chain itself is doing.

Positive numbers mean audio **lags** the picture, negative means audio **leads**.
Results are compared against EBU R37 (-40 / +60 ms) and ITU-R BT.1359 thresholds.

## Do I need a test file?

Yes. Sync can only be measured against content where a visual event and an audio event are
*known* to be simultaneous. Ordinary video has no such reference. The pattern is bundled in
the app (`AVSyncMeter/Resources/avsync_1080p60.mp4`, 1.7 MB) and can be regenerated with
`tools/make_test_pattern.sh` (needs ffmpeg).

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

## Using it

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
  Analysis/   FlashDetector, BeepDetector, SyncAnalyzer, AnalysisPipeline, standards, stats
  Capture/    AVCaptureSession engine, luminance sampler, audio conversion
  Distance/   LiDAR ranger, screen-size (pinhole) ranger, speed of sound
  Measure/    measurement state machine + UI + camera preview
  Pattern/    test-pattern constants, player / AirPlay / export view
  Settings/   user settings + view
  Resources/  avsync_1080p60.mp4 (bundled test pattern)
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
