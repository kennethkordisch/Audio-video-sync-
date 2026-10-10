#!/usr/bin/env python3
"""Checks a generated test-pattern file and prototypes the detectors used in the app.

1. Decodes video luminance per frame (ffmpeg signalstats) and finds flash onsets.
2. Decodes audio to float PCM and runs the same biquad band-pass + envelope onset
   detector that AVSyncMeter/Analysis/BeepDetector.swift implements.
3. Reports flash-vs-beep alignment inside the file (should be ~0 ms, +-1 frame).
4. Simulates what the phone sees: a camera at CAM_FPS sampling the flash, audio delayed
   by a known offset with added noise, and checks the recovered offset.

Usage: tools/validate_pattern.py path/to/avsync_1080p60.mp4
Needs: ffmpeg/ffprobe on PATH, numpy.
"""
import math, re, subprocess, sys, tempfile, os
import numpy as np

TONE_HZ = 1000.0
PERIOD = 2.0

def decode_audio(path, sr=48000):
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar", str(sr),
         "-f", "f32le", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64), sr

def decode_luma(path):
    """Returns (pts_seconds[], mean_luma[]) using ffmpeg's signalstats filter."""
    out = subprocess.run(
        ["ffmpeg", "-v", "info", "-i", path, "-an",
         "-vf", "scale=240:-2,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-",
         "-f", "null", "-"], check=True, capture_output=True, text=True).stdout
    pts, y = [], []
    for line in out.splitlines():
        m = re.search(r"pts_time:([0-9.]+)", line)
        if m: pts.append(float(m.group(1))); continue
        m = re.search(r"YAVG=([0-9.]+)", line)
        if m: y.append(float(m.group(1)))
    n = min(len(pts), len(y))
    return np.array(pts[:n]), np.array(y[:n])

# --- Detector prototypes (mirrors Swift) -------------------------------------------

def biquad_bandpass(f0, q, sr):
    """RBJ constant-skirt band-pass biquad. Returns (b0,b1,b2,a1,a2) normalised."""
    w0 = 2 * math.pi * f0 / sr
    alpha = math.sin(w0) / (2 * q)
    b0 = math.sin(w0) / 2; b1 = 0.0; b2 = -math.sin(w0) / 2
    a0 = 1 + alpha; a1 = -2 * math.cos(w0); a2 = 1 - alpha
    return b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0

def beep_onsets(x, sr, q=8.0, attack_ratio=6.0, min_level=0.002, refractory_s=0.3,
                floor_tc_s=0.5, env_release_s=0.02):
    """Band-pass at TONE_HZ, peak-follower envelope, adaptive noise floor, threshold crossing.
    Returns onset times in seconds (sample-accurate at the trigger crossing)."""
    b0, b1, b2, a1, a2 = biquad_bandpass(TONE_HZ, q, sr)
    x1 = x2 = y1 = y2 = 0.0
    env = 0.0
    release = math.exp(-1.0 / (env_release_s * sr))
    floor = 0.0
    floor_a = 1.0 - math.exp(-1.0 / (floor_tc_s * sr))
    last_onset = -1e9
    onsets = []
    for n in range(len(x)):
        xn = x[n]
        yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, xn; y2, y1 = y1, yn
        a = abs(yn)
        env = a if a > env else env * release
        t = n / sr
        if t - last_onset > refractory_s:
            thr = max(min_level, floor * attack_ratio)
            if env > thr and n > sr * 0.2:
                onsets.append(t); last_onset = t
            else:
                floor += floor_a * (env - floor)
    return np.array(onsets)

def flash_onsets(t, luma, min_contrast=20.0):
    """Half-maximum crossing with linear interpolation between frames. Baseline = running min."""
    onsets = []
    base = float(np.percentile(luma, 10))
    i = 1
    while i < len(luma):
        if luma[i] - base > min_contrast and luma[i-1] - base <= min_contrast:
            j = i
            while j < len(luma) and luma[j] - base > min_contrast: j += 1
            peak = luma[i:j].max()
            half = base + 0.5 * (peak - base)
            k = i
            while k < j and luma[k] < half: k += 1
            if k == 0 or luma[k] == luma[k-1]:
                onsets.append(t[k])
            else:
                frac = (half - luma[k-1]) / (luma[k] - luma[k-1])
                onsets.append(t[k-1] + frac * (t[k] - t[k-1]))
            i = j
        else:
            i += 1
    return np.array(onsets)

def pair(flashes, beeps, window=0.5):
    out = []
    for f in flashes:
        d = beeps - f
        d = d[np.abs(d) < window]
        if len(d): out.append(d[np.argmin(np.abs(d))])
    return np.array(out)

def main():
    path = sys.argv[1]
    x, sr = decode_audio(path)
    t, luma = decode_luma(path)
    fl = flash_onsets(t, luma)
    bp = beep_onsets(x, sr)
    print(f"frames={len(t)}  flashes={len(fl)}  beeps={len(bp)}")
    print("first flashes (s):", np.round(fl[:5], 4))
    print("first beeps   (s):", np.round(bp[:5], 4))
    d = pair(fl, bp) * 1000
    print(f"in-file beep-flash offset: median {np.median(d):+.2f} ms, min {d.min():+.2f}, max {d.max():+.2f}  (n={len(d)})")
    print("  (flash onset is the half-max crossing between the last black and first white frame,"
          " i.e. ~half a frame before the first white frame's PTS: expect about -8 ms at 60 fps)")

    # --- Simulate a phone: camera at cam_fps, audio delayed by true_offset with noise ---
    rng = np.random.default_rng(1)
    for cam_fps in (60, 120, 240):
        for true_offset_ms in (-40.0, 0.0, 35.0, 120.0):
            # Camera model: display is a zero-order hold (frame k shown for [t_k, t_k+1/60)),
            # camera frame exposed over [ts, ts+T] with PTS = ts (exposure start), luma = box
            # integral of the displayed luminance over the exposure. The app then shifts each
            # frame time by +T/2 (exposure midpoint), which is what we test here.
            cam_dt = 1.0 / cam_fps
            T = cam_dt
            ts = np.arange(0.5, t[-1] - cam_dt, cam_dt)
            # 64 sub-samples across the exposure, zero-order hold on the display grid
            sub = ts[:, None] + (np.arange(64)[None, :] + 0.5) / 64 * T
            idx = np.clip(np.searchsorted(t, sub, side="right") - 1, 0, len(t) - 1)
            cam = luma[idx].mean(axis=1) + rng.normal(0, 1.0, len(ts))
            t_cam = ts + T / 2
            fcam = flash_onsets(t_cam, cam)
            # Audio: delay and add noise at -30 dBFS, a bit of 1 kHz-ish room noise
            delay = int(round(true_offset_ms / 1000 * sr))
            xa = np.roll(x, delay) if delay >= 0 else np.roll(x, delay)
            xa = xa * 0.3 + rng.normal(0, 0.01, len(xa))
            bcam = beep_onsets(xa, sr)
            dd = pair(fcam, bcam) * 1000
            # The camera sees the display step at the frame's PTS, so no in-file bias to remove.
            err = np.median(dd) - true_offset_ms
            print(f"sim cam {cam_fps:3d} fps, true {true_offset_ms:+6.1f} ms -> measured {np.median(dd):+7.2f} ms "
                  f"(err {err:+5.2f}, spread MAD {np.median(np.abs(dd-np.median(dd))):.2f} ms, n={len(dd)})")

if __name__ == "__main__":
    main()
