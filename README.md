# Interview Studio

Interview Studio is a macOS app in active development for assembling interview video clips into a new finished file from a manifest.

Right now it is focused on the assembly/export phase of that workflow: import a project folder that contains `final_manifest.json`, review the generated sequence and issues, tweak a few presentation details, then export a real `3840x2160` / `60 fps` / HLG master movie. If you want it, it can also produce a Plex-friendly companion `MP4` without changing the protected master export.

## Project Status

Phase 1 Assembly Studio is complete for its defined assembly-from-manifest scope. The broader product remains in active development because clip creation and manifest authoring are planned for a later phase. The current Phase 2 checklist is in [docs/PHASE_2_PLAN.md](docs/PHASE_2_PLAN.md).

Built primarily for my own workflow, but possibly useful if you also have a manifest-driven interview pipeline and want a Mac-native finishing tool instead of stitching everything together by hand.

The current app is still intentionally narrow: it finishes prepared interview projects rather than creating the source clips from raw interviews.

Right now this should be read as an in-progress app repo, not a finished product.

If this repo starts publishing GitHub Releases, those should become the easiest way to try it. Until then, the repo is source-first.

## What It Does

- Loads an interview project folder using `final_manifest.json`
- Persists app-specific edits in `yearly_interview_studio_project.json`
- Builds a deterministic render plan with cards, answer clips, overlays, and transitions
- Shows live previews plus dedicated Sequence and Issues windows
- Renders a real HDR `MOV` master using FFmpeg
- Optionally remuxes a Plex-friendly `MP4` companion with metadata and chapters

## What It Does Not Do Yet

Today, Interview Studio assumes the clips and manifest already exist.

It does not yet create source clips, ingest raw media into this project format, or author the manifest from scratch inside the app.

That broader workflow is intended for a later phase: tools to create clips, add clips, and build or extend the manifest inside the app instead of arriving with those pieces pre-generated.

Phase 1 is intentionally narrow; these are boundaries of the completed phase and the broader product:

- one person per project
- one locked export profile
- no timeline editor yet
- no clip trimming or player-style QA workflow yet

## Workflow Shape

The current app is meant to sit on top of an existing clip/manifest generation pipeline rather than replace it.

The rough shape is:

1. Generate a project folder that contains `final_manifest.json` and the referenced media.
2. Open that folder in Interview Studio.
3. Review question grouping, issue surfacing, previews, overlays, and output settings.
4. Export the HDR master movie.
5. Optionally keep the Plex companion output if you want a library-friendly copy.

A future phase is meant to absorb more of step 1 into the app itself.

The app keeps its own sidecar state in `yearly_interview_studio_project.json` so presentation edits and metadata do not have to mutate the source manifest.

## Current Strengths

- Deterministic Phase 1 export contract: `3840x2160`, `60 fps`, `HEVC Main10`, `BT.2020`, `bt2020nc`, `HLG`, `MOV`
- Conservative HDR handling that blocks export instead of silently falling back to SDR
- Sidecar-backed question text edits, ordering, Title Case preference, and Plex metadata
- Safer answer-to-answer audio transitions that prefer clean seams over stray speech leakage
- A real macOS app plus a CLI smoke-test path built from the same shared core

## Current Limits

- macOS only
- single-person projects only
- requires an already-prepared manifest-backed project folder
- export can be slow on CPU-heavy systems, especially for card generation and SDR-to-HLG conversion
- FFmpeg / FFprobe availability still matters
- the Plex metadata path is intentionally simple and can block export until required fields are filled in or disabled

For the fuller current-state view, see [docs/WHERE_WE_STAND.md](docs/WHERE_WE_STAND.md).

## Building And Running

Requirements:

- macOS 14 or newer
- Swift toolchain compatible with `swift-tools-version: 6.0`
- a compatible `ffmpeg`/`ffprobe` pair with `zscale`, `xfade`, `acrossfade`, `overlay`, and `libx265`; the app checks the bundled tools and other installed candidates until it finds a capable pair

Build the app bundle:

```bash
./script/build_and_run.sh build
```

That creates:

```text
dist/Yearly Interview Studio.app
```

Run the app:

```bash
./script/build_and_run.sh run
```

Useful script modes:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --debug
```

## CLI

There is also a small CLI entrypoint that renders from a project folder directly:

```bash
swift run YearlyInterviewStudioCLI /path/to/project-folder /path/to/output-root
```

The CLI expects the project folder to contain `final_manifest.json`. It prints phase progress as it renders, then emits the output paths for the finished movie, optional Plex companion, and diagnostics folder.

## Repo Layout

- `Sources/App` - macOS app target
- `Sources/Core` - manifest loading, render planning, media inspection, and rendering
- `Sources/CLI` - CLI smoke-test entrypoint
- `Tests/CoreTests` - focused tests for the shared core
- `script/build_and_run.sh` - packaged app build/run helper
- `docs/WHERE_WE_STAND.md` - plain-language current state
- `docs/PHASE_2_PLAN.md` - current Clip Factory plan and checklist
- `docs/DECISIONS.md` - decision log for durable project choices

## Notes On Packaging

The packaged `.app` is built from source-controlled version values in `script/build_and_run.sh`, and the build script copies in an app icon plus bundled `ffmpeg` / `ffprobe` when those tools are available on the host machine. At runtime, the renderer preflights each discovered FFmpeg installation instead of assuming the first one is capable; if none is suitable, the app explains what is missing and asks the user to install a compatible build.

This means the app is currently convenient for local use, but still early as a polished distribution story.

## AI Assistance

Like most of my recent projects, this one is built with heavy AI assistance using tools like Codex and Claude.

The workflow choices, guardrails, testing expectations, and project direction are still mine. The typing speed definitely is not.
