# Interview Studio

Current version/build:
- `0.1.2 (3)` in the current app bundle script and packaged app.

Overall status:
- Phase 1 Assembly Studio is complete for its defined assembly-from-manifest scope as a working internal macOS app plus a shared core library and CLI.
- The app can import a manifest-backed project folder, build a deterministic render plan, surface issues/confidence, and export a real final movie.
- The current phase is assembly-from-manifest only; creating source clips or building the manifest inside the app is future work.

What works now:
- Typed parsing of `final_manifest.json`, including flexible numeric/string decoding and path resolution for `output_file` plus `output_path` fallback.
- Usable-row filtering for `export_status` and `status`, single-person validation, question grouping, question ordering, and age ordering.
- Sidecar project persistence in `yearly_interview_studio_project.json` for titles, question order, edited display text, render settings, title-case preference, and Plex companion metadata.
- Serializable render plans with opening cards, question cards, answer clips, closing cards, explicit boundary transitions, issue objects, confidence labels, and summary counts.
- FFmpeg preflight, source inspection, HDR safety checks, native card/overlay image generation, staged rendering, final HDR movie export, and Plex-friendly MP4 companion packaging.
- Persistent age overlays, optional persistent question overlays, answer-to-answer soft crossfades with handle-aware fallback planning, and gentle loudness matching controls.
- Main-window live previews for opening cards, question cards, and a real-frame answer overlay sample using the current project data, now loaded progressively with placeholders/stale-frame reuse instead of blocking the whole rebuild.
- Dedicated Sequence and Issues windows reachable from both the main UI and the Window menu, with issue cards now surfacing question text, age context, and stable question keys.
- Safer transition audio planning that prefers quiet seams or conservative fallback instead of leaking stray handle speech.
- Verified smoke export and prior owner testing against actual project media using the locked Phase 1 contract: `3840x2160`, `60 fps`, `HEVC`, `yuv420p10le`, `BT.2020`, `bt2020nc`, `HLG`.
- Build script that stages a testable macOS `.app` under `dist/Yearly Interview Studio.app`, bundles `ffmpeg`/`ffprobe` when found on the host, and now includes a real app icon.
- Runtime FFmpeg discovery checks each executable candidate for the required Phase 1 filters/codecs and presents an actionable warning if no installed pair is capable.

What is partial:
- The app UI now has a better review loop, but it is still a compact Phase 1 interface rather than a polished studio-grade workflow.
- The renderer is correct but slow on card generation because SDR-to-HLG 4K conversion is expensive in software.
- Plex metadata defaults are intentionally focused and simple rather than a full metadata editor.
- The bundled app still uses source-controlled version values hardcoded in the build script instead of a more mature version/build file workflow.
- The repo currently represents the back half of the intended workflow: assembly and export after clips and manifest data already exist.

What is not implemented yet:
- In-app creation of source clips.
- In-app tools to add clips to a project over time.
- In-app manifest authoring or manifest extension workflows.
- Timeline UI.
- Phase 2 scrubbing/trimming or clip-factory tooling.
- Per-clip exclusion controls.
- A player-style QA workflow with transport controls or clip scrubbing inside the app.

Known limitations and trust warnings:
- Phase 1 supports one person per project only.
- Phase 1 requires a prepared project folder with `final_manifest.json` and referenced media already in place.
- HDR export depends on an FFmpeg/FFprobe pair with the required filters/codecs available; the app now searches multiple installed candidates instead of trusting the first pair it finds.
- Existing projects now default to Plex companion export on, which means export will block until the required Plex fields are filled or the feature is turned off for that project.
- The current UI is intentionally conservative after a more ambitious SwiftUI screen triggered compiler instability during this pass.
- Renderer smoke tests are opt-in in XCTest because they depend on local FFmpeg and graphical template rendering support. Actual project media has also been used for prior testing and has worked so far; rerunning the birthday projects after toolchain changes remains the owner check.

Setup/runtime requirements:
- macOS 14 or newer.
- FFmpeg and FFprobe available either from the bundled app resources or from a compatible local installation. The renderer searches the bundle, explicit environment overrides, common Homebrew/MacPorts locations, and PATH candidates.
- For local Codex verification, diagnostics/output should point to writable paths; successful runs now clean temp intermediates by default and only preserve diagnostics on failure or explicit opt-in.

Important operational risks:
- Large 4K60 HLG exports can take meaningful time on CPU-heavy systems.
- If HDR-safe normalization cannot be proven for inputs, export is blocked rather than silently falling back to SDR.
- The new Plex companion path depends on remux-compatible final audio/video streams and standard MP4 tag behavior; smoke verification covers the current implementation, but broader real-library validation is still prudent.

Recommended next priorities:
- Start designing the next phase that creates/adds clips and grows the manifest inside the app instead of assuming a fully prepared input folder; see [PHASE_2_PLAN.md](PHASE_2_PLAN.md).
- Improve render throughput, especially for synthetic card segments and SDR-to-HLG normalization.
- Expand the in-app Assembly Studio workflow with player-style QA, progress details, and deeper boundary review.
- Move version/build values into dedicated source-controlled version files.
- Add a broader metadata regression suite that checks more Plex-facing tags and chapter names across multiple sample exports.

Most recent durable known-good anchor:
- 2026-05-07 verification pass with passing `rtk swift test --scratch-path /private/tmp/interview-studio-swiftpm`, passing opt-in renderer smoke test with Plex companion assertions, and a successful packaged app build at `dist/Yearly Interview Studio.app` reporting version `0.1.2 (3)`.
