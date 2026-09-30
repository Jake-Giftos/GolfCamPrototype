# GolfCamPrototype

Phase 1–2 technical prototype. It answers one question:

> Can an ordinary iPhone on a tripod measure golf-ball speed and launch angle accurately enough to be useful outdoors?

It is a one-screen SwiftUI app. It captures 240 fps, finds the ball, arms itself, detects the strike, tracks the ball
through the first ~100 ms, and reports **ball speed** and **vertical launch**. Start direction is shown too, but it
is labelled **experimental**. There's no backend and no network use. Spin and carry are not measured, and carry
shows `--- yd` on purpose.

---

## 1. Getting it on your iPhone from Windows, for $0

You can't build iOS apps on Windows. This project works around that as follows:

1. **GitHub Actions** builds it on a free cloud Mac and produces an unsigned `GolfCamPrototype.ipa`.
2. **Sideloadly** (free, Windows) signs that .ipa with your normal Apple ID and installs it over USB.

### One-time setup

1. Create a free GitHub account and a new repository. Public repos get unlimited free Mac build minutes. Private repos
   get about 200 Mac minutes a month, which is roughly 40 builds.
2. Push this folder to it:
   ```bash
   git remote add origin https://github.com/<you>/GolfCamPrototype.git
   ```
   ```bash
   git push -u origin main
   ```
3. On Windows, install **iTunes** and **iCloud** from apple.com. Use the direct-download versions, not the Microsoft
   Store ones, because Sideloadly needs their drivers. Then install **Sideloadly** from sideloadly.io.
4. On the iPhone, go to Settings › Privacy & Security › **Developer Mode** and turn it on. The phone restarts.

### Each build

1. On GitHub, open **Actions › Build unsigned IPA**. A run starts on every push to `main`, or you can run it by hand
   with "Run workflow". Download the `GolfCamPrototype-ipa` artifact and unzip it to get the `.ipa`.
2. Plug in the iPhone, open Sideloadly, drag the `.ipa` in, enter your Apple ID and click Start.
3. On the first install only, go to Settings › General › VPN & Device Management, tap your Apple ID and tap **Trust**.

**Free Apple ID limits:** the app expires after **7 days**. When it does, re-run step 2. Your shot data stays as long
as you don't delete the app. You can have at most 3 sideloaded apps at once.

If a build fails, the run uploads `build.log`. Paste the error lines to Claude to get a fix.

---

## 2. Camera setup (important)

Put the camera **face-on**, square to the target line, not down the line:

```
                target  →→→→→→→→→→→→→→→→→→
        golfer    ●  ball
                  ↑
                  |  5–7 ft
                  |
               [phone on tripod, landscape, lens at ~ball height to knee height]
```

Why face-on? A single camera measures motion across the image well and motion toward or away from it badly. Speed
and vertical launch are mostly across the image in this view, so the weak axis only affects start direction.
Down-the-line puts the ball speed on the weak axis.

- Hold the phone in landscape with the **Dynamic Island on the LEFT**.
- In ⚙︎ Settings, set which side of the screen the target is on, and your handedness.
- Place the ball in the dashed box, or tap the ball on screen to move the box there.
- The ball should sit in the third of the frame **away from the target**, so it crosses the rest of the frame.
- Aim for a ball radius of about 12–22 px (shown in Debug). The app warns you if it's too small or too large.
- Keep the phone level. The roll warning appears above 3°. Some tilt is handled because gravity comes from the
  motion sensor.
- Use sunlight. The default shutter is 1/4000 s. If the ISO maxes out (the Debug panel shows this), use 1/2000.

---

## 3. How it works (and assumptions)

| Stage | Method |
|---|---|
| Capture | AVFoundation, highest-fps 4:2:0 format ≤1080p (1920×1080 @ 240 on 17 Pro Max), stabilisation off, manual shutter, ISO scaled to keep brightness. Focus and white balance lock when armed. |
| Ball detection | Luma histogram in the box → threshold halfway between background median and highlights → blob labelling → circularity/size filter → **sub-pixel equator chord** for radius. Must be stable for 10 detections (~0.3 s) to arm. |
| Trigger | Every frame while armed: mean abs difference of the ball's inner disc vs. reference. The noise floor is learned in the first 24 frames. Crossing 3× noise fires the trigger. |
| Buffer | 80-frame ring of luma copies (32 pre + 48 post ≈ 0.33 s, ~166 MB). No video is written. |
| Tracking | Three-frame differencing → ball-sized moving blobs → RANSAC for a straight path that **passes through the address point at impact** and heads toward the target → least-squares refit. |
| Timing | Real `CMSampleBuffer` presentation timestamps. It never assumes 1/240 s. |
| Scale | Camera intrinsics come from the ISP each frame. Distance to ball = fx · 21.335 mm / radius_px. |
| Speed & launch | Each tracked pixel is intersected with the vertical flight plane through the ball (normal = camera's horizontal viewing direction). A 3D velocity is fitted. Launch is measured against **true vertical from the gravity sensor**. |
| Start direction | Depth per frame from the moving ball's apparent size. It's noisy and hidden when confidence is LOW. **Experimental.** |

Known error sources, in order of expected size:

1. **Radius error → equal % speed error.** A 0.3 px error on a 15 px radius is 2 %, or about 3 mph at 150. This is
   the main calibration target.
2. The camera isn't square to the target line. The error is small, about 1.5 % at 10°.
3. Lens distortion is ignored. It's small near the centre, so keep the flight path in the middle band of the frame.
4. Start direction is out of plane, which lowers the reported speed by a factor of cos(angle): about 0.4 % at 5°.

**Confidence** (HIGH/MEDIUM/LOW) only describes track quality: how many frames were tracked and the pixel residual.
It says nothing about calibration accuracy. The validation step below measures that.

---

## 4. Debug outputs

In Files › On My iPhone › GolfCam:

- `shots.csv`: one row per shot, with **empty `ref_*` columns** for the reference launch monitor's numbers.
- `Shots/shot-NNNN.json`: everything, including intrinsics, exposure, gravity, all candidates, inliers, the fit,
  notes and timings.
- `Shots/shot-NNNN-frames/*.png`: full-resolution frames. These are saved only if "Save raw frames" is on.

**REVIEW** on the result panel lets you scrub through the frames with overlays. Yellow is the address ball, red is a
rejected candidate, green is the tracked ball, and blue is the fitted path. Use it on every bad shot.

---

## 5. Validation protocol

1. Set up next to a trusted monitor (TrackMan, GCQuad, GC3, Rapsodo or Toptracer bay).
2. Hit 50 or more shots across a few clubs. After each one, write the reference speed, launch and start direction
   into the `ref_*` columns of `shots.csv`. You can do this on the phone in Numbers, or later on the PC.
3. Run:
   ```bash
   python tools/benchmark_stats.py shots.csv
   ```
   This prints MAE, RMSE, bias and error standard deviation, overall and per club, plus the speed-vs-error slope.
4. Consistent bias with low spread means the approach works and a calibration factor fixes the rest. Large spread
   means look at the review frames and JSON before changing anything.

Targets: ball speed within ±2–3 mph, launch within ±1–2°.

---

## Project layout

```
project.yml                   XcodeGen spec (the .xcodeproj is generated, not committed)
.github/workflows/            Cloud Mac build → unsigned .ipa
GolfCamPrototype/
  App/                        App entry + wiring
  Camera/                     AVFoundation capture, preview, CoreMotion gravity
  Vision/                     Luma frames/ring buffer, blob labelling, ball detector, post-impact tracker
  Math/                       Least squares, camera geometry, launch metrics
  Engine/                     Shot state machine, logging, review data
  UI/                         SwiftUI screens
tools/benchmark_stats.py      Accuracy stats from shots.csv
```

If you ever get a Mac: `brew install xcodegen && xcodegen generate`, then open `GolfCamPrototype.xcodeproj`.
