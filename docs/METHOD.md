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

## Drift

In drift mode the run lasts a set number of minutes and `DriftAnalyzer` fits
`offset(t) = a + b t` with the Theil-Sen estimator (median of all pairwise slopes, intercept
= median of `y - b x`), which ignores occasional false pairs. Reported:

* slope `b` in ms/min, in frames/hour at the project rate, and as a clock ratio in ppm
  (`b / 60 000 * 1e6`);
* total drift over the run and the residual spread (MAD) around the line;
* an interpretation: |ppm| < 25 is "locked"; about 1000 ppm is the 1000/1001 pull-down
  mismatch (23.976 vs 24, 29.97 vs 30, 48 vs 48.048 kHz) = 60 ms/min = 1.44 frames/min at
  24 fps; about 40 000 ppm is 24 vs 25; about 85 000 ppm is 44.1 vs 48 kHz.

Frame slips: the offsets are detrended with the fitted slope, then scanned for a step of more
than half a frame that holds for the next two events. Each step is reported with its time
into the run and its size in ms and frames. A single-frame drop or repeat shows up as a
+-1 frame step; a 2-pop cut in the wrong place shows up as a constant offset instead.

Needs at least 6 events spanning 20 s; a 5 min run resolves about 0.2 ms/min (3 ppm), which is
far below any real clock error.

## Channel identification

The phone has one usable microphone for this purpose, so left and right are told apart by
frequency, not direction: channel-ID patterns put even events on the left at f and odd events
on the right at 1.6 f. The beep detector runs one band-pass per tone (Q = 10, about 20 dB of
separation at this ratio) and decides the band 4 ms after the threshold crossing by comparing
envelopes. 1.6 was chosen so neither tone is a harmonic of the other; speaker distortion of a
1 kHz tone lands at 2 and 3 kHz, not at 1.6 kHz. Offsets are then summarised per band.
Whether "left" actually comes out of the left speaker is still a human check: the live card
names the channel of each beep as it happens.

## Speaker levels

* Weighting filters are IEC 61672 A and C realised as cascades of bilinear-transformed
  first-order sections (poles at 20.6 Hz x2, 107.7 Hz, 737.9 Hz, 12.2 kHz x2 for A; 20.6 Hz x2
  and 12.2 kHz x2 for C), normalised to 0 dB at 1 kHz. Bilinear warping makes the 12.2 kHz
  pole slightly off at 48 kHz, which is irrelevant for pink-noise level work.
* Levels are exponential mean-square with 125 ms (Fast) or 1 s (Slow) time constants; Leq is
  the plain mean square since reset.
* dB SPL = dBFS + calibration offset. The default offset of 120 dB is a placeholder; set it
  against a real meter. iPhone microphones are flat enough from 100 Hz to 8 kHz that A/C
  weighted pink-noise levels come out within about 1 dB of a Class 2 meter once the offset is
  set, and channel-to-channel differences are good to a few tenths of a dB because the same
  microphone, position and offset apply to every channel.
* Sequence gating: a burst starts when the C-weighted Fast level exceeds target − 20 dB for
  0.2 s and ends when it falls 3 dB below that for 0.3 s. The Leq of the burst skips its first
  0.5 s. Bursts are assigned to channels in the file's order, so the phone must be started
  before the first burst and must not miss one; the table shows which channel it expects next.
* Pink noise in the files is Kellet's refined filter on white noise, independently seeded per
  channel, scaled to the requested RMS after a 2 s measurement; LFE is low-passed at 120 Hz
  (2nd-order Butterworth) and re-normalised so its in-band RMS equals the other channels.
  The shell script measures ffmpeg's `anoisesrc` pink RMS and compensates the same way.

## Calibration

The phone's camera and microphone timestamps come from one clock, but the pipelines in front
of them (sensor readout, ISP, audio DSP) add latencies that iOS aligns only approximately.
The residual is a constant for a given device and capture format. Calibrate mode measures a
reference chain assumed to be in sync, subtracts sound travel, and stores the remainder as
`cameraTimestampOffsetMs` (added to every frame time). Sign: a chain that truly is in sync but
reads +b at the screen means the camera timestamps are b too early; adding b to them makes
future readings zero. Calibrate once per phone, and again if iOS changes the capture format
(check "Format" on the Live card).

## Two-pop mode

Same detectors, no auto-stop: each flash/beep pair is listed as it happens. Pairing window is
+-0.6 s, so pops at least 1.2 s apart are unambiguous. A real 2-pop (one frame of white and
one frame of 1 kHz tone) is well inside what the detectors need: at 24 fps the flash lasts
42 ms and the tone 42 ms.

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

* 1920 x 1080 at 23.976, 24, 25, 29.97, 30, 50, 59.94 or 60 fps; 60 s bundled, any length
  from the script; H.264 (crf 16) + AAC 192 kb/s in MP4, optionally DNxHR LB + 24-bit PCM in
  OP1a MXF (`-m`) for Avid, and ProRes 422 Proxy (or LT/422/HQ via `-P`; 10-bit 4:2:2, Rec.709) + 24-bit PCM in
  QuickTime .mov (`-p`) for Resolve and QuickTime Player.
* Black background; dim grey caption with the frame rate and event number so a person can
  tell it is playing.
* Events on a whole-frame grid: first event at frame round(1 s x fps), then every
  round(2 s x fps) frames (48 at 24 and 23.976, 50 at 25, 60 at 29.97 and 30, ...). The frame
  goes white for 2 frames at or below 30 fps and 3 frames above; a 1 kHz sine burst of 50 ms at
  -3 dBFS with 0.5 ms fades starts at exactly the first white frame's timestamp.
* `tools/validate_pattern.py` decodes the file and confirms flash/beep alignment inside it
  (expect about +6.7 ms by its convention, because its flash onset is taken half a frame
  before the first white frame), then simulates a camera at 60/120/240 fps with a known
  audio offset and checks the detectors recover it.
