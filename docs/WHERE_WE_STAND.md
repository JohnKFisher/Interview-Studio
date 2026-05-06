# Interview Studio

Current version/build:
- `0.1.1 (2)` in the current app bundle script.

Overall status:
- Phase 1 Assembly Studio is now implemented as a working internal macOS app plus a shared core library and CLI.
- The app can import a manifest-backed project folder, build a deterministic render plan, surface issues/confidence, and export a real final movie.

What works now:
- Typed parsing of `final_manifest.json`, including flexible numeric/string decoding and path resolution for `output_file` plus `output_path` fallback.
- Usable-row filtering for `export_status` and `status`, single-person validation, question grouping, question ordering, and age ordering.
- Sidecar project persistence in `yearly_interview_studio_project.json` for titles, question order, edited display text, and render settings.
- Serializable render plans with opening cards, question cards, answer clips, closing cards, explicit boundary transitions, issue objects, confidence labels, and summary counts.
- FFmpeg preflight, source inspection, HDR safety checks, native card/overlay image generation, staged rendering, and final movie export.
- Persistent age overlays, optional persistent question overlays, answer-to-answer soft crossfades with handle-aware fallback planning, and gentle loudness matching controls.
- Main-window live previews for opening cards, question cards, and a real-frame answer overlay sample using the current project data.
- Dedicated Sequence and Issues windows reachable from both the main UI and the Window menu.
- Safer transition audio planning that prefers quiet seams or conservative fallback instead of leaking stray handle speech.
- Verified smoke export to a real playable file using the locked Phase 1 contract: `3840x2160`, `60 fps`, `HEVC`, `yuv420p10le`, `BT.2020`, `bt2020nc`, `HLG`.
- Build script that stages a testable macOS `.app` under `dist/Yearly Interview Studio.app` and bundles `ffmpeg`/`ffprobe` when found on the host.

What is partial:
- The app UI now has a better review loop, but it is still a compact Phase 1 interface rather than a polished studio-grade workflow.
- The renderer is correct but slow on card generation because SDR-to-HLG 4K conversion is expensive in software.
- The bundled app currently uses source-controlled version values hardcoded in the build script instead of a more mature version/build file workflow.

What is not implemented yet:
- Timeline UI.
- Phase 2 scrubbing/trimming or clip-factory tooling.
- Per-clip exclusion controls.
- A player-style QA workflow with transport controls or clip scrubbing inside the app.

Known limitations and trust warnings:
- Phase 1 supports one person per project only.
- HDR export depends on an FFmpeg build with the required filters/codecs available.
- The current UI is intentionally conservative after a more ambitious SwiftUI screen triggered compiler instability during this pass.
- Renderer smoke tests are opt-in in XCTest because they depend on local FFmpeg and graphical template rendering support.

Setup/runtime requirements:
- macOS 14 or newer.
- FFmpeg and FFprobe available either from the bundled app resources or from a compatible local installation.
- For local Codex verification, diagnostics/output should point to writable paths; the shipped app defaults to user-standard locations.

Important operational risks:
- Large 4K60 HLG exports can take meaningful time on CPU-heavy systems.
- If HDR-safe normalization cannot be proven for inputs, export is blocked rather than silently falling back to SDR.

Recommended next priorities:
- Improve render throughput, especially for synthetic card segments and SDR-to-HLG normalization.
- Expand the in-app Assembly Studio workflow with player-style QA, progress details, and deeper boundary review.
- Move version/build values into dedicated source-controlled version files.
- Add an opt-in automated renderer smoke test path for environments where FFmpeg and graphics support are known-good.

Most recent durable known-good anchor:
- 2026-05-03 local verification pass with successful CLI smoke export to `/private/tmp/yis-smoke-output-tty9/yis-smoke-project-tty9.mov` and matching ffprobe confirmation for the locked Phase 1 HDR profile.
