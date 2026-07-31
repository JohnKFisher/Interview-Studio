# Phase 2 Plan — Clip Factory

Status: proposed next phase; not started.

Phase 1 is the Assembly Studio: it takes prepared clips and a prepared `final_manifest.json` and creates the finished movie. Phase 2 is the missing front half of that workflow: a Clip Factory that turns long interview source media into the clips and manifest that Phase 1 already understands.

The original detailed plan is preserved in [Historical/yearly_interview_studio_codex_plan.md](Historical/yearly_interview_studio_codex_plan.md). This file is the current working checklist and should be updated as decisions are made.

## Phase 2 outcome

Given long yearly interview source media, the app should let the user identify answer ranges, attach the required person/question/age metadata, export individual answer clips, and create or update a valid `final_manifest.json`. Opening the resulting project folder in Phase 1 should work without manual repair.

## Core checklist

### 1. Define the Clip Factory workflow

- [ ] Decide how users add one or more long source videos to a project.
- [ ] Decide whether Phase 2 supports one person only at first or introduces multi-person projects.
- [ ] Define the source-media browser and the answer-selection workflow.
- [ ] Define how questions are selected, added, renamed, and ordered.
- [ ] Define how age/year and person metadata are assigned to each clip.
- [ ] Define how projects save unfinished clip selections without changing the source media.

### 2. Build source-media review

- [ ] Import and inspect long source videos with useful metadata and validation errors.
- [ ] Add reliable playback controls: play/pause, seek, time display, and scrubbing.
- [ ] Support precise in/out selection for an answer, including enough context to choose clean boundaries.
- [ ] Provide a preview of the selected range before export.
- [ ] Decide whether handles are user-adjustable, automatically suggested, or both.

### 3. Create answer clips

- [ ] Export one or more selected answer ranges as individual clips.
- [ ] Use stable, human-readable names and a predictable project-folder layout.
- [ ] Preserve the metadata needed by Phase 1: identity, question grouping, age sorting, output path, answer timing, handle data, video/color signature, and validation status.
- [ ] Handle cancellation, retry, duplicate output names, missing source media, and partial exports safely.
- [ ] Keep source media untouched and make the generated clips replaceable.

### 4. Create and maintain the manifest

- [ ] Generate a new `final_manifest.json` for a Clip Factory project.
- [ ] Support adding or revising clips without losing existing valid rows.
- [ ] Validate generated rows before marking them usable by Phase 1.
- [ ] Resolve generated paths using the same rules as the current Phase 1 importer.
- [ ] Keep Filmora-specific fields as optional provenance/debug data rather than making them required for newly created clips.

### 5. Connect the handoff to Phase 1

- [ ] Open a generated project folder directly in the existing Assembly Studio.
- [ ] Show clear errors when generated clips or manifest fields are not ready for assembly.
- [ ] Run a real-media round trip: source video → selected clip → manifest → Phase 1 render.
- [ ] Add deterministic tests for manifest generation, path resolution, metadata, and boundary/handle calculations.

## Supporting work that may belong in Phase 2

These are useful parts of the broader workflow, but should not expand the first Clip Factory slice without an explicit decision:

- [ ] Player-style QA inside the app, including transport controls and clip scrubbing.
- [ ] Per-clip exclusion/reinclude controls.
- [ ] Better boundary review and confidence explanations.
- [ ] Progress and diagnostics for long clip-export batches.
- [ ] Multiple source files or merged source parts per answer.

## Explicit non-goals for the initial Phase 2 slice

- Replacing GPL FFmpeg; that remains a separate future licensing, packaging, and distribution investigation.
- Rebuilding a full Final Cut/Premiere-style multi-track timeline unless we later decide it is necessary.
- Breaking the Phase 1 manifest contract or requiring Filmora provenance for newly generated clips.
- Mutating or destructively rewriting the original source videos.

## Open decisions before implementation

1. What is the smallest useful source format and codec set for the first real birthday-project workflow?
2. Should the first release create clips for one person only, matching Phase 1, or support multiple people immediately?
3. Should Phase 2 start from a question list supplied by the user, an existing manifest, or both?
4. What default handle duration and export profile should generated clips use?
5. Should editing an existing manifest be supported in place, or should every run produce a new versioned project output?

## Definition of done

Phase 2 is complete when a user can take the actual long source media for a birthday project, select and label the answers in the app, export a valid manifest-backed project, open it in Phase 1, and produce the same kind of verified final movie without hand-editing JSON or performing a separate clip-generation workflow.
