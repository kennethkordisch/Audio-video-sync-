# Measurement method

## Signal chain

```
test pattern (flash + beep at the same timestamp)
   -> player -> display  ~~light~~>  iPhone camera (<= 240 fps)  -> luminance per frame -> FlashDetector
   -> player -> speakers ~~sound~~>  iPhone microphone (48 kHz)  -> band-pass + envelope -> BeepDetector
                                                                                  \-> SyncAnalyzer (pairing, median)
```

Camera frames and audio buffers are both delivered by one `AVCaptureSession`, timestamped on
its synchronisation clock. No cross-clock conversion is needed.

## Flash timing

* Each frame is reduced to the mean luminance of the screen region (initially the central
  half of the frame; after the first flash, the rectangle that lit up).
* The detector tracks a dark baseline (falls instantly, rises with a 4 s time constant),
  triggers when luminance exceeds baseline + threshold, follows the peak, and when the flash
  ends computes the time at which luminance crossed **half way between baseline and peak**,
  linearly interpolated between the two straddling frames.
* Frame time = presentation timestamp + exposure/2 (optional) + user offset.
* Because the camera samples independently of the display refresh, the interpolated crossing
  converges on the display's actual switching instant. In simulation (`tools/validate_pattern.py`)
  the error is < 0.3 ms at 60, 120 and 240 fps.

## Beep timing

* Mono audio -> 2nd-order RBJ band-pass at 1 kHz, Q = 8 (about 125 Hz wide).
* Peak-follower envelope (20 ms release), adaptive noise floor (0.5 s time constant, frozen
  during events).
* Onset = first sample where envelope > max(0.002, 6 x noise floor); 300 ms refractory.
* Threshold crossing fires within about 1 ms of the true onset for a hard-onset burst, a
  constant bias that is identical for every event and far below the display's own quantisation.
* Because it is an onset detector, the direct sound wins over reflections (which arrive later
  and never earlier).

## Pairing and statistics

Flash and beep onsets are paired greedily by nearest time within +-0.6 s (events are 2 s
apart, so this is unambiguous). Unpaired events are discarded after 1.2 s. The reported
offset is the **median** of beep - flash over all pairs; spread is the median absolute
deviation (MAD). Median/MAD make a single false trigger harmless.

## Distance and sound travel

```
offset_at_phone  = median(beep - flash)
travel           = distance / c,     c = 331.3 + 0.606 * T(°C)  m/s   (343 m/s at 20 °C, 2.9 ms/m)
offset_at_screen = offset_at_phone - travel
```

Which one to act on:

* Calibrating a home theatre or a conference room: set the AVR / TV lip-sync delay so that
  **offset_at_phone** is near zero at the main seat. Sound travel is part of the experience.
* Checking equipment (does this projector / TV / soundbar add delay?): use **offset_at_screen**.
* Cinemas: SMPTE practice is to time sound to about two-thirds of the way back in the room,
  so measure from that row and zero offset_at_phone there.

Distance sources, in priority order: manual > LiDAR > camera estimate.

The camera estimate uses the pinhole model `distance = f_px * D / d_px` where `f_px` is the
focal length in pixels from the per-frame camera intrinsic matrix, `D` the screen diagonal
and `d_px` the lit rectangle's diagonal in pixels (measured on a 48 x 27 cell grid with
fractional edge cells). Expect about +-5%, i.e. +-0.7 ms at 5 m.

## Error budget (typical, 60 Hz display)

| Source | Size | Notes |
|---|---|---|
| Display refresh quantisation | 0 to 16.7 ms | The flash frame appears at the next refresh. A systematic property of the chain, not noise. |
| Display scan-out (top vs bottom of panel) | up to ~8 ms | Depends on where the camera's region of interest sits. Keep the whole screen in view. |
| Camera frame interpolation | < 0.5 ms at 240 fps, < 2 ms at 60 fps | Half-max interpolation. |
| Camera timestamp reference (exposure start vs midpoint) | <= 2 ms at 240 fps | Toggle in Settings. |
| Beep onset detection | ~1 ms constant | Equal for all events. |
| AAC encoding of the test file | +-2 ms | Encoder pre-echo smears the onset slightly. A PCM .mov variant is generated too. |
| Camera-microphone alignment inside iOS | a few ms | Shared capture clock; this is what keeps Camera-app recordings in sync. |
| Distance (LiDAR) | +-2 cm (0.06 ms) | |
| Distance (camera estimate) | +-5% | 0.7 ms at 5 m. |
| Microphone position vs ear | 0.3 m = 1 ms | Hold the phone near head height. |

Bottom line: the method resolves changes of 1 to 2 ms between runs, and the absolute number
is good to roughly +-5 ms, dominated by the display's own refresh behaviour.

## Limitations

* The camera and ARKit cannot run at the same time, so LiDAR ranging happens first, then the
  capture session starts. If the phone moves between the two steps, the distance is stale.
* PWM-dimmed LED backlights and DLP colour wheels modulate the luminance signal. The detector
  is a step detector on the mean of many pixels, so normal PWM averages out, but very dim
  projector images may need a lower contrast threshold (Settings).
* Bluetooth or wireless speakers add delay that varies from session to session; measure the
  chain in the state you will use it.
* Playing the pattern from the phone over AirPlay measures Apple TV + display, not the source
  you normally use, and starting the capture session may interrupt AirPlay playback.
* Interlaced or frame-rate-converted chains (motion smoothing!) add latency and can change
  the flash's apparent timing; turn motion interpolation off or measure with it on knowingly.

## Test pattern

Generated by `tools/make_test_pattern.sh`:

* 1920 x 1080, 60 fps, 120 s, H.264 (crf 16) + AAC 192 kb/s in MP4, plus a PCM .mov variant.
* Black background; dim grey caption with the event number so a person can tell it is playing.
* Every 2.0 s from t = 1.0 s: full-frame white for 3 frames (50 ms) and a 1 kHz sine burst of
  50 ms at -3 dBFS with 0.5 ms fades. The first white frame and the first tone sample share
  the same timestamp.
* `tools/validate_pattern.py` decodes the file and confirms flash/beep alignment inside it
  (expect about +6.7 ms by its convention, because its flash onset is taken half a frame
  before the first white frame), then simulates a camera at 60/120/240 fps with a known
  audio offset and checks the detectors recover it.
