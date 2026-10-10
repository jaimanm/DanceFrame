# DanceFrame (Native macOS)

A native, high-performance macOS desktop application built with **SwiftUI**, **AppKit**, and **AVFoundation** for intelligent vertical video framing (9:16) and motion tracking.

## Features

- **Native 60fps Playback Engine**: Real-time hardware-accelerated video decoding using Apple's `AVPlayer` and `AVPlayerItemVideoOutput`.
- **Interactive "YOUR CUT" Framing**:
  - Direct canvas visualizer of the 9:16 vertical crop.
  - Drag the crop window directly on the video to position your subject.
- **Precision Motion Timeline**:
  - Live timeline scrubbing without stutter or snap-back.
  - Green keyframe markers indicate tracking points.
  - Click on the timeline to place or update tracking points.
  - Drag keyframes directly along the timeline.
  - Red shaded trim region visualization.
- **Motion Interpolation**:
  - **Smooth (Cubic Ease-In-Out)**: Natural camera panning between dancer positions.
  - **Linear**: Constant-velocity tracking.
- **Side-by-Side Live Portrait Preview**:
  - Instantaneous 9:16 portrait viewport showing the exact cropped composition at all times.
- **Non-Destructive Trimming**:
  - Set custom start/end points using time inputs or "Set start here" / "Set end here" quick buttons.
- **Project Persistence**:
  - Save (`Cmd+S`) and open (`Cmd+O`) projects as `.danceframe.json`. Full backward compatibility with web/Electron versions.
- **High-Quality Export**:
  - Vertical video export in **1080x1920 (FHD)** or **720x1280 (HD)**.
  - Leverages embedded FFmpeg with audio passthrough/AAC encoding.
  - Real-time progress percentage bar and cancellation support.
  - One-click "Show in Finder" upon export completion.

## Keyboard Shortcuts

- <kbd>Space</kbd> or <kbd>K</kbd>: Play / Pause toggle
- <kbd>←</kbd> / <kbd>→</kbd>: Step backward / forward 1 frame (~0.033s)
- <kbd>Shift</kbd> + <kbd>←</kbd> / <kbd>→</kbd>: Step backward / forward 1 second
- <kbd>Cmd</kbd> + <kbd>O</kbd>: Open video or project file
- <kbd>Cmd</kbd> + <kbd>S</kbd>: Save project (`.danceframe.json`)
- <kbd>Cmd</kbd> + <kbd>Z</kbd>: Undo last tracking point addition

## Building and Packaging

### Requirements
- macOS 13.0 (Ventura) or later
- Apple Command Line Tools (`xcode-select --install`) or Xcode

### Build & Run
To build and run directly via Swift Package Manager:
```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift run
```

### Package into Standalone `DanceFrame.app`
To generate a standalone `.app` bundle:
```bash
./package_app.sh
```
This produces `DanceFrame.app`, which can be launched via:
```bash
open DanceFrame.app
```
