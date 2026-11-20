# FVP desktop integration

Source: https://pub.dev/packages/fvp/versions/0.39.0 (BSD-3-Clause).
MDK SDK: https://github.com/wang-bin/mdk-sdk/releases/tag/v0.39.0.
Upstream Dart and Windows/macOS plugin sources are retained under `fvp/`.

Local changes:

- Adapt the disposal lifecycle from [FVP PR #416](https://github.com/wang-bin/fvp/pull/416): confirm native pause, allow 100ms for pending audio completions, then confirm native stop before releasing textures. Query native state directly, coalesce concurrent disposal, and preserve resources on callback timeout instead of continuing teardown. Keep the existing awaitable `dispose()` API and platform audio backends; the PR's audio-only controller API is not included. The native disposal integration test covers play/pause/seek, end-of-stream, concurrent and repeated disposal.

- Register native plugins only on Windows and macOS. Register the Dart backend explicitly after selecting the shared FFmpeg runtime.
- Use the local `video_player` Dart API package, without endorsed platform backends.
- Pin MDK downloads and SHA-256 checksums. macOS uses CocoaPods with a prepared framework; Windows uses the upstream CMake downloader.
- Exclude MDK's FFmpeg runtime from both desktop bundles. The app passes the absolute FFmpegKit library paths to MDK before opening media and checks their ABI versions.
- `registerWith` returns a Future; await backend initialization and native disposal so library selection precedes player creation and files are released before cleanup.
- The application initializes playback and encoding together, then restores FFmpegKit ownership of the process-wide FFmpeg log callback. macOS uses the exported callback; Windows uses disable/enable redirection, whose 8.1.2 implementation joins the old consumer thread before returning.

Upgrade together with `runtime.dart`. Run the native media pipeline and preview tests, then `tool/check_media_packaging.py` against each release artifact. Do not restore upstream mobile registrations or MDK's default FFmpeg bundle when updating.
