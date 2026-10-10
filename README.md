# DanceFrame Desktop

A local macOS desktop editor for reframing landscape dance videos into vertical MP4s, using manual tracking points and optional trimming.

## Open the app

Double-click **DanceFrame.app** in this project folder. There is no browser, localhost server, terminal command, account, or upload step. The app bundles Electron, FFmpeg, ffprobe, and their required libraries. Python, Node, Homebrew, and Xcode are not required to run the built app.

This build targets Apple Silicon Macs. It is a locally built, ad-hoc-signed app, not an Apple-notarized public release.

## Use it

1. **Open video** (⌘O): choose your original landscape video. The app reads it directly without creating another large copy.
2. Scrub through the video and click on yourself to create tracking points. Drag the crop to adjust it. **← / →** step a nominal frame; **Shift** steps ten. **K** inserts a point at the current crop position. **Space** plays/pauses.
3. Choose smooth ease-in/ease-out or constant-speed motion. Review the entire cut and add more points around changes in direction.
4. Trim using start/end times, or scrub to a frame and choose **Set start here / Set end here**. Tracking stays aligned to the original source timestamps.
5. **Export vertical MP4** (⌘E): choose a destination in the native Save dialog. Output is 1080×1920 or 720×1280, with audio when the source contains it. **Show exported video in Finder** locates the finished file.
6. **Save tracking project** (⌘S) saves a portable JSON containing tracking and trim settings. Open the original video before loading that project (⇧⌘O). Existing web-editor project JSONs remain compatible. Automatic drafts are stored locally in the desktop app; browser drafts are separate.

Cancelling a render preserves any existing destination file. The app prevents exporting over the currently open source path. It prompts before closing during an export.

## Development in VS Code

```sh
npm ci
npm run build
npm test
npm start
```

`npm run build` packages the app into `dist/DanceFrame-darwin-arm64/DanceFrame.app`. Building requires Node, network access for Electron if not cached, and macOS command-line tools. The packaging script copies the tested `/opt/homebrew/bin/ffmpeg` and `ffprobe` installations, recursively bundles non-system libraries, relocates their references, and signs those binaries locally. Override the source binaries with `DANCEFRAME_FFMPEG` and `DANCEFRAME_FFPROBE` if needed. Build once before `npm start` or tests to populate `build-resources/binaries`.

- `desktop/main.cjs`: native window, menus, file dialogs, restricted local media protocol, export lifecycle.
- `desktop/preload.cjs`: narrow isolated IPC interface.
- `desktop/video.cjs`: video inspection, validation, motion expressions, cancellable rendering.
- `static/`: editor interface rendered inside the app.
- `desktop/test/`: invalid-input, crop-motion, trimming, audio, dimensions, and cancellation tests.

The renderer has no Node access. Only bundled UI files and explicitly selected media are served through the internal `danceframe:` protocol; there is no listening network port. Remote navigation and new windows are blocked. Main-process file access uses native selection dialogs.

The prior Python web version is preserved under `web/` for reference. The desktop app does not depend on it. `Start.command` now launches the desktop app.

## Limits

The fixed-size crop tracks horizontally and clamps to source edges. It cannot guarantee visibility unless you place enough points and review the preview. Frame stepping uses average FPS, so it is approximate for variable-frame-rate sources; export motion uses source timestamps. H.264 MP4 is the most reliable preview format. HDR tone mapping, anamorphic footage, and vertical motion/zoom are not implemented. Output crop dimensions are rounded to even pixels before scaling to exact 9:16.

The bundled encoder is the Homebrew GPL FFmpeg build with its linked dependencies. This package is built for personal use on this Mac. Review all dependency licenses and source-distribution requirements before public distribution.

Electron architecture references: [custom protocols](https://www.electronjs.org/docs/latest/api/protocol), [context isolation](https://www.electronjs.org/docs/latest/tutorial/context-isolation).
