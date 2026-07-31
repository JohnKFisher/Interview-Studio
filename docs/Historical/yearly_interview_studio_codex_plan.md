# Yearly Interview Studio — Codex Build Plan

## Project Identity

**Name:** Yearly Interview Studio

**Purpose:** Build a macOS-focused app that assembles structured yearly interview clips into a polished final movie using `final_manifest.json` as the source of truth.

**Phase 1 Goal:** Assemble already-created clips into a finished 4K/60fps/HDR movie with question ordering, title/question/closing templates, persistent overlays, handle-aware transitions, gentle audio loudness matching, and a clear render-plan validation screen.

**Phase 2 Goal, not built yet:** Add a Clip Factory interface that imports long yearly interview videos, lets the user scrub/trim answers, creates new clips, names/places/labels them, and updates the same manifest contract used by Phase 1.

---

## Non-Negotiable Product Philosophy

1. **Phase 1 is not a timeline editor.**
   - The user works at the question/section level.
   - The app assembles answers automatically by metadata.
   - No arbitrary clip dragging in Phase 1.

2. **Phase 2 may include scrubbing and trimming.**
   - Do not architect the app in a way that rules this out.
   - Trimming belongs in the future Clip Factory, not the Phase 1 Assembly Studio.

3. **The manifest is the source of truth.**
   - `final_manifest.json` drives grouping, ordering, handles, HDR validation, clip paths, age labels, and answer timing.

4. **The app should be deterministic.**
   - Given the same manifest and app settings, it should produce the same render plan.

5. **Block export on true failures.**
   - Any blocker must include both a human-readable explanation and AI-readable structured JSON.

---

## Phase 1 User Flow

### 1. Import / Setup

User selects:
- a project/export folder
- `final_manifest.json`

The app:
- parses the manifest
- resolves clip paths, preferring `output_file` relative to the manifest/project folder
- validates that referenced media files exist
- filters to usable rows (`export_status` of `exported` or `skipped_existing`, status `ready` unless intentionally relaxed later)
- groups clips by `question_key`
- sorts questions by `question_original_index`
- sorts answers within each question by `age_sort_key`

### 2. Assembly Screen

The main interface should allow:
- reorder questions
- edit question display text without changing `question_key`
- set opening title text
- set closing title text
- select opening template
- select question-card template
- select closing template
- select age overlay style
- optionally enable persistent question overlay during answers
- choose global answer transition style
- set answer transition duration, default 12 frames, advanced override range 0–24 frames
- choose question-card duration via template default, with manual override
- toggle gentle audio loudness matching, default ON

The app should not include individual clip exclusion in Phase 1 unless later requested.

### 3. Render Plan Preview

This is a required Level 1 preview, not a video preview.

It should show:
- final sequence structure
- opening title
- questions in selected order
- answers under each question in age order
- answer durations
- transition status per boundary
- whether real handles, synthetic handles, or clean cuts are used
- missing ages as informational indicators
- HDR validation status
- confidence labels: High, Medium, Low
- blockers and warnings

Render button remains disabled if blockers exist.

### 4. Render

Render the final movie using the locked output profile:
- 4K
- 60fps
- HLG HDR
- BT.2020 primaries
- BT.2020 non-constant luminance matrix (`bt2020nc`)
- HEVC Main10

Internally define an `ExportProfile`, even if the UI exposes only one profile.

---

## Sequence Structure

The movie structure is:

```text
Opening card
Question card 1
Answer clips for Question 1, sorted by age
Question card 2
Answer clips for Question 2, sorted by age
...
Closing card
```

Use structure A only for Phase 1: question-by-question progression with ages shown inside each question.

Do not implement per-year grouping or hybrid grouping in Phase 1.

---

## Visual System

### Opening Card

Template-driven.

Fields:
- title text
- optional subtitle/family/year text later if needed
- duration from template, optionally user-overridden

### Question Card

Always full screen.

Purpose:
- acts as the section break
- provides breathing room between question sections

Fields:
- edited question display text
- template ID
- duration from template, optionally user-overridden

Do not show “Question 3 of 18.” User explicitly wants only the question text.

### Age Overlay

Persistent for the full answer clip.

Fields:
- `age` display text from manifest, such as `6 Years Old`
- style ID
- position, font, background, opacity controlled by template/style

### Question Overlay During Answers

Optional.

If enabled:
- persistent for the full answer clip
- small, low-attention orientation label
- edge-aligned, preferably top-left or top-right
- designed as context UI, not as a prominent title
- no fade-out required

Long questions should be handled with controlled wrapping, smaller font, or ellipsis.

---

## Transition System

The user wants consistency. Do not mix visible transition styles arbitrarily.

### Global Answer Transition

Default:
- Soft Crossfade
- 12 frames at 60fps

Advanced override:
- 0–24 frames
- 0 means clean cut

### Transition Strategy

Use a global answer transition strategy with deterministic fallback.

For each answer-to-answer boundary:

1. **Real handle crossfade**
   - Preferred.
   - Use when outgoing clip has enough real trailing handle and incoming clip has enough real leading handle.

2. **Renderer-owned synthetic padding**
   - Use when real handles are insufficient but synthetic padding can be safely generated inside the final render pipeline.
   - Do not mutate source clips.
   - Generate synthetic frames in the same output color pipeline.

3. **Clean cut fallback**
   - Use when crossfade cannot be safely performed.
   - This is acceptable but should be surfaced in the render plan.

4. **Blocker**
   - Only block if the selected transition mode requires crossfade with no fallback, or if media/color/renderer validation fails.

### Question Card Transitions

Question-card transitions are separate from answer-to-answer transitions.

Allow templates/setting to define:
- cut
- fade
- fade through black

Question cards are the primary breathing room between sections.

---

## Audio System

Default: **Gentle Loudness Match ON**.

Definition:
- measure each answer clip’s integrated loudness and true peak
- apply gain to reach a consistent target loudness
- apply true-peak limiting to prevent clipping
- do not aggressively compress dynamics
- do not add noise reduction, dialogue enhancement, EQ, or music ducking in Phase 1

Recommended initial values:
- target integrated loudness: approximately `-16 LUFS`
- true peak ceiling: approximately `-1 dBTP`

The goal is to avoid volume whiplash while preserving the natural sound of each age/year.

---

## Color and HDR System

Use lessons from the existing Monthly Video Generator HDR work.

Core rules:
- normalize per source type before final assembly
- do not treat HDR metadata as a substitute for real color transforms
- keep Display P3 distinct from BT.709 SDR
- freeze color math after source normalization
- final output metadata must match actual transforms
- fail early if required FFmpeg filters/codecs are unavailable

Target output:
- HLG
- BT.2020 primaries
- `bt2020nc` matrix
- HEVC Main10
- 4K 60fps

The renderer should inspect source/output signatures from the manifest and/or ffprobe.

HDR/Dolby rows require `hdr_dolby_validation` to be acceptable before use.

---

## Confidence Labels

Confidence is informational only. It should never itself block export.

Definition:
**Confidence = how safe this clip/boundary is for clean visual/technical assembly.**

It is deterministic and rule-based, not AI guesswork.

### High Confidence

Typical criteria:
- full real handles
- no synthetic padding needed
- no meaningful warnings
- HDR validation passed or not applicable

### Medium Confidence

Typical triggers:
- partial handles
- synthetic padding used
- minor warnings such as merged clips
- clean cut fallback used where crossfade was preferred

### Low Confidence

Typical triggers:
- no real handles
- HDR prevents synthetic padding
- major warnings
- suspicious fallback modes
- large duration drift beyond tolerance, if not blocking

Show confidence in render-plan preview so the user can identify spots that may feel less smooth.

---

## Missing Ages

Missing ages are not errors.

If a question has clips for ages 3, 4, 6, and 9, simply render those clips.

The render plan should optionally show informational missing-age indicators when the global set of ages suggests something might be absent:

```text
Included: Age 3, Age 4, Age 6, Age 9
Missing from this question: Age 5, Age 7, Age 8
```

Status level: Info, not warning.

---

## Blockers, Warnings, and Info

### Blockers

Block export for:
- invalid manifest schema
- missing referenced clip file
- unreadable/corrupt media
- required FFmpeg/renderer capability missing
- HDR validation failure for required HDR/Dolby content
- impossible render graph
- output destination invalid or unwritable

### Warnings

Do not block by default for:
- synthetic padding required
- partial handles
- clean cut fallback
- merged source clips
- SDR clips being uplifted to HDR
- duration drift within tolerance

### Info

Use info for:
- missing ages
- template defaults used
- audio loudness matching applied

Every blocker/warning should have:
- human-readable message
- AI-readable structured issue object

---

## Phase 2 Architectural Hooks

Do not build Phase 2 yet, but preserve space for it.

Phase 2 will be a Clip Factory with:
- import long yearly interview video
- scrub and trim clips
- identify question/answer boundaries
- assign person, question, age
- export individual answer clips
- create/update `final_manifest.json`
- ensure Phase 1 Assembly Studio can immediately consume the result

Do not couple Phase 1 too tightly to Filmora provenance. Treat Filmora fields as provenance/debug data, not permanent requirements for future generated clips.

Future Phase 2-generated manifest rows must satisfy the same Phase 1 contract:
- identity fields
- question grouping
- age sorting
- output file reference
- answer start/end in output
- real/synthetic handle data
- HDR/color signature data
- validation status

---

## Recommended App Architecture

### Modules

```text
YearlyInterviewStudio/
  App/
    YearlyInterviewStudioApp.swift
    AppState.swift
  Core/
    Manifest/
      ManifestModels.swift
      ManifestParser.swift
      ManifestValidator.swift
      ManifestPathResolver.swift
    Project/
      ProjectModel.swift
      ProjectSettings.swift
      QuestionGroupBuilder.swift
    RenderPlan/
      RenderPlanModels.swift
      RenderPlanBuilder.swift
      RenderPlanValidator.swift
      ConfidenceEvaluator.swift
      IssueModels.swift
    Templates/
      TemplateModels.swift
      BuiltInTemplates.swift
    MediaInspection/
      FFprobeModels.swift
      MediaInspector.swift
    Render/
      ExportProfile.swift
      Renderer.swift
      FFmpegCommandBuilder.swift
      AudioPipelineBuilder.swift
      ColorPipelineBuilder.swift
      TransitionPlanner.swift
  UI/
    ImportView.swift
    AssemblyView.swift
    QuestionOrderView.swift
    TemplateSettingsView.swift
    RenderPlanPreviewView.swift
    IssueListView.swift
  Tests/
    ManifestParserTests.swift
    RenderPlanBuilderTests.swift
    TransitionPlannerTests.swift
    ConfidenceEvaluatorTests.swift
```

### Build Order

1. Manifest models/parser
2. Path resolution and validation
3. Question grouping and sorting
4. Project settings model
5. Render plan schema/models
6. Render plan builder
7. Render plan validator and issue system
8. Confidence evaluator
9. Minimal SwiftUI import/assembly UI
10. Level 1 render plan preview UI
11. FFmpeg preflight checks
12. Basic clean-cut renderer
13. Card/overlay rendering
14. Audio gentle loudness matching
15. Handle-aware transition planner
16. HDR/color pipeline integration
17. Final export and validation
18. Polish and test fixtures

---

## Immediate Codex Task

Start by implementing the data layer and render plan logic only. Do not start with FFmpeg rendering.

First milestone:
- load `final_manifest.json`
- parse into typed models
- group by question
- sort questions and ages
- build a render plan
- validate it
- show text/JSON output in tests or a simple CLI

Only after this is correct should UI and rendering be added.
