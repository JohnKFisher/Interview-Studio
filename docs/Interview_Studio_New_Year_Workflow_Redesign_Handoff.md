# Interview Studio — New-Year Answer Workflow Redesign Handoff

**Status:** Product-design decisions complete enough for Codex `/grill-me` and implementation planning  
**Audience:** Codex / implementation agent  
**Primary goal:** Replace the current question-first editing workflow for **new interview years** with a recording-first workflow optimized for long interview recordings containing many questions and answers, while preserving the existing legacy workflow for old years.

---

## 1. Executive Summary

Interview Studio currently works well for the historical capture pattern where there is effectively **one source video per answer/question**. That workflow should remain intact for old interview years because it is already useful and because old years do not need to be migrated.

Going forward, however, new interviews may be recorded as **long source recordings containing many consecutive questions and answers**. The new workflow must therefore be recording-first rather than question-first.

The core new workflow is:

> **Capture → Refine → Assign → Finish**

The user should be able to:

1. Create a new interview year.
2. Add one or more long source recordings.
3. Work through a recording in real time and repeatedly press **I** and **O** to carve it into rough candidate answer clips without interrupting playback.
4. Refine those candidate clips in a separate pass.
5. Make limited internal cuts to remove pauses or unwanted material without turning Interview Studio into a general-purpose movie editor.
6. Approve clips.
7. Drag approved clips onto the appropriate canonical questions.
8. Compare/replace an already-assigned answer if another recording contains a better answer to the same question.
9. Finish/lock the year and feed it into the existing movie-generation path.
10. Preserve all source and editing state conservatively, with data loss treated as a critical failure.

The legacy workflow remains available behind a clearly separate **Use Legacy Interface** path. New years should use the new workflow and should not be editable through the old interface.

---

# 2. Product Context and Design Constraints

## 2.1 Internal tool, not a productized editor

Interview Studio is an internal tool with a single known user.

Assume:

- one user;
- use approximately twice per year;
- current macOS only;
- no need for cross-platform support;
- no need to support old macOS versions merely for hypothetical users;
- no need for consumer-grade onboarding, telemetry, generalized preference systems, feature flags, or extensive abstraction layers unless implementation quality genuinely benefits;
- native macOS patterns, drag-and-drop, keyboard shortcuts, split views, contextual menus, etc. are encouraged.

However, because the tool is used infrequently, the UI should be **easy to re-learn after months away**. Important actions should remain visibly labeled even when keyboard shortcuts exist.

The target is:

> **Simple, friendly, obvious, reliable, and efficient — but not overengineered.**

Do not turn this into Final Cut Pro.

---

# 3. Current Legacy Flow — Baseline to Preserve

The current implementation is question-first.

At a high level, the current system:

- opens a project and selects an interview year;
- selects a question;
- resolves a source recording for that question;
- manually seeks through the recording;
- marks raw answer start/end;
- runs automatic audio-based boundary refinement;
- calculates visible answer boundaries and safe/buffer boundaries;
- previews the answer or answer-with-buffers;
- marks the answer complete or skipped;
- later locks the year and renders the final movie.

The existing workspace is a three-column macOS layout:

1. Project sidebar
2. Questions list
3. Answer Editor

The current design assumes the question is selected before the answer is found. Source-recording assignment is mostly implicit.

That legacy behavior should remain available for historical years.

### Important existing concepts worth preserving where useful

The current data model already understands:

- stable question identity separate from question display text;
- interview answers;
- answer takes;
- answer parts;
- raw answer markers;
- refined boundaries;
- safe boundaries;
- lock/unlock year;
- publication/render planning.

The new UI does **not** need to expose the existing take/part complexity directly, but implementation should reuse compatible concepts where practical.

---

# 4. Top-Level Workflow Decision

## 4.1 Start New Year vs Legacy Interface

At the point where the user begins work, there should be an explicit conceptual split:

### Start New Year
Uses the new recording-first workflow.

### Use Legacy Interface
Uses the current question-first interface.

Exact labels may be refined, but the intended meaning is:

- new years default to the new workflow;
- legacy years remain in the legacy workflow;
- no migration of old years is required in this redesign;
- a new-workflow year should not be edited through the legacy editor.

The user may never need the legacy editor for new work, but it must not be removed because old years still depend on it.

---

# 5. New-Year Creation

Starting a new year should be intentionally short.

Collect:

- **Year**
  - currently not used for output behavior;
  - still store it for future-proofing.
- **Canonical age**
  - manually entered;
  - continue using the existing canonical-age concept;
  - do not add automatic age derivation from birth dates.
- **Initial source recordings**
  - optional;
  - user may choose several at once;
  - a year may also be created with zero recordings and recordings added later.

The canonical project question list is automatically available. Do not make the user re-import or rebuild questions for each year.

---

# 6. Persistent Workspace, Not a Wizard

The new experience should be a **persistent workspace with navigable stages**, not a step-by-step wizard that traps the user in a sequence.

Primary destinations:

- **Capture**
- **Refine**
- **Assign**
- **Finish**

The natural path is:

> Capture → Refine → Assign → Finish

But the user must be free to:

- move back to Capture;
- refine a different source;
- assign some answers early;
- return to an assigned answer for refinement;
- add another source recording later;
- jump to Finish to see remaining issues;
- reopen a finished recording;
- leave unresolved work and come back later.

State must survive these transitions.

---

# 7. Source Recording Model

## 7.1 Multiple source recordings per year

A year may contain multiple long source recordings.

The user is comfortable processing them one at a time.

Recommended default rhythm:

> Recording 1: Capture → Refine  
> Recording 2: Capture → Refine  
> Recording 3: Capture → Refine  
> Assign whenever useful

Assignment is always available; it is not forced to wait until every source recording has been processed.

## 7.2 Import all known recordings up front, but do not eagerly load/process everything

UX may allow selecting all recordings at year creation.

Technically:

- register all recordings;
- show all recordings in Sources;
- load/player-analyze only the active recording as needed;
- do not create AVPlayers for every source;
- do not eagerly generate proxies/transcripts/full expensive analysis for every recording unless clearly justified;
- avoid unnecessary memory use;
- avoid unnecessary hard-drive pressure;
- release/cache resources appropriately when switching sources.

## 7.3 Source states

Each source recording has a simple explicit state:

- **Not Started**
- **In Progress**
- **Finished**

Also persist:

- resume/playback position;
- candidate/refinement summary;
- source order.

### Finished is explicit

Reaching the end of a recording does **not** automatically mark it Finished.

The user explicitly chooses **Finish Recording** when satisfied that capture is complete.

Finished is reversible. Reopening a Finished recording returns it to In Progress without disturbing existing candidates, edits, or assignments.

## 7.4 Persistent Sources area

Keep a compact Sources area persistently visible in the new workspace.

Each source row should provide lightweight state such as:

- `Recording 1 — Finished · 8 approved`
- `Recording 2 — In Progress · 5 candidates, 2 need review`
- `Recording 3 — Not Started`

Do not turn this into a large dashboard.

Each source exposes explicit actions such as:

- Continue/Open Capture
- Refine Clips
- Review Clips
- Reopen Recording

Do not guess whether the user intended Capture or Refine solely from state.

## 7.5 Source order is editable

Sources may be dragged to reorder.

Source order affects:

- organizational order;
- Refine All ordering;
- Assign clip ordering.

Source reordering must **not** modify timestamps, candidate identity, assignments, or media.

---

# 8. Capture — Primary Goal

Capture is a **fast, rough marking pass**.

The video plays normally and the user repeatedly marks rough answer boundaries:

> `I → O → I → O → I → O ...`

The core principle:

> **Capture must not interrupt playback or force refinement/assignment decisions.**

When a rough answer is captured, the user should be able to keep watching immediately.

No naming.
No modal assignment.
No refinement dialog.
No question selection.

---

# 9. Capture Interaction Semantics

These rules are deliberate and should be implemented exactly unless `/grill-me` finds a serious technical problem.

## 9.1 I / O behavior

### First I
Begins the current provisional candidate.

### Repeated I before any O
The latest I replaces the earlier I.

Interpretation:

> “I started too early; use this newer start.”

### First O
Sets the provisional Out.

The provisional candidate may be visibly represented immediately, but it is still correctable.

### Repeated O before the next I
The latest O replaces the earlier O.

Interpretation:

> “I hit O too early; keep playing and use this later O instead.”

### New I after a valid I → O pair
The previous candidate becomes committed to the capture queue, and the new I starts the next provisional candidate.

Conceptually:

`I → O → I`

means:

1. commit previous candidate;
2. start next candidate.

## 9.2 Pause does not commit

If the user has:

`I → O → Pause`

do not commit merely because playback paused.

The current valid I/O pair remains provisional so the user may:

- resume;
- press O again to extend/change it;
- press I to commit and begin the next candidate.

## 9.3 Leaving Capture with a valid I/O pair

If the user chooses:

- Finish Recording;
- Review/Refine;
- switch to another source;
- otherwise explicitly leaves Capture;

and a valid provisional `I → O` pair exists, commit it automatically.

## 9.4 Leaving Capture with unmatched I

If the user has marked I but never O, do **not** guess an endpoint and do **not** silently discard it.

Show a lightweight warning, conceptually:

> **Unfinished clip at 18:42**  
> You marked an In point but no Out point.

Actions:

- **Return to Capture**
- **Discard In Point & Continue**

This is a hard data-safety rule.

---

# 10. Capture Candidate Strip

Already-created candidates from the active source should remain visible in a compact list/strip.

Show enough to orient the user:

- stable automatic clip identifier;
- thumbnail;
- duration;
- perhaps source time.

Capabilities in Capture:

- lightweight replay;
- delete/discard/undo recent mistake;
- selecting a candidate for quick inspection.

Do **not** turn Capture into an editing surface.

If the user notices Clip 8 is slightly wrong while already working on Clip 9, the intended response is:

> fix Clip 8 during Refine.

Capture is for rough identification, not precision.

---

# 11. Capture Layout

Capture should be strongly **video-first**.

Recommended conceptual layout:

### Left
Persistent Sources sidebar.

### Main / center top
Large video player.

### Center below player
Waveform/timeline with:

- current playback position;
- provisional I/O markers;
- obvious current provisional candidate.

### Controls
Visible controls for:

- Play/Pause;
- Mark In;
- Mark Out;
- Finish Recording.

### Secondary area
Compact candidate strip/list.

Questions should not compete for attention in Capture.

---

# 12. Capture Keyboard Controls

Capture should be keyboard-efficient but not keyboard-dependent.

Expected shortcuts:

- **Space** — Play/Pause
- **I** — Set/replace In
- **O** — Set/replace Out
- **Delete/Backspace** — remove the most recent committed candidate where sensible
- Arrow keys — standard small seek behavior if practical

Visible UI controls should show their shortcuts.

Shortcuts should not fire while focus is in text-entry controls.

Normal macOS Undo/Redo should remain available.

---

# 13. Optional Capture Polish

These are **not core requirements**.

Implement only if cheap and reliable.

## Playback speed
If trivial with existing AVPlayer behavior:

- 1× default
- simple 1.25× / 1.5× / 2× type control

Otherwise keep 1× only.

## Speech/silence navigation
If analysis already provides this cheaply:

- Jump to next speech
- Jump to next silence/gap

Do not build complex infrastructure solely for these controls.

---

# 14. Background Work During Capture

After a candidate is committed, Interview Studio may opportunistically run background work:

- answer boundary refinement;
- clip-level transcription.

Rules:

- never interfere with smooth playback;
- throttle/defer if CPU, memory, or I/O causes visible capture lag;
- neither result is required for the workflow;
- preserve raw I/O even if analysis fails;
- a failed transcript must never block anything;
- a failed boundary refinement must still permit manual refinement.

---

# 15. Refine — Primary Goal

Refine is a separate, deliberate cleanup pass.

The user should **not** have to refine during Capture.

Default source-level rhythm:

> Capture source → Refine source

But the user may leave, assign, process another source, and come back later.

---

# 16. Refine Queue Behavior

## 16.1 Default
Refine candidates for the selected source.

## 16.2 Secondary convenience
Provide **Refine All Unreviewed** across the year.

This should:

- walk unresolved candidates in source order;
- use capture/source-time order within each source;
- automatically continue from one source to the next;
- make current source identity prominent during the transition.

Do not create a complex queue-management UI.

## 16.3 First-pass order

Walk candidates in capture order.

## 16.4 Actions per candidate

### Approve & Next
Marks the current candidate approved and advances.

### Skip for Now
Leaves it unresolved/unapproved and advances.

### Discard
Removes it from the active workflow and moves it to Recently Discarded.

## 16.5 No autoplay on advance

Approve & Next and Skip for Now should automatically select the next candidate but **not** autoplay it.

## 16.6 Skipped candidates

After the normal first pass completes, if skipped candidates remain, offer:

> **Review Skipped Clips**

Do not automatically loop back and trap the user.

The user may leave Refine with skipped clips unresolved.

---

# 17. Refine Timeline Context

Refine should not show only the captured range.

The user needs surrounding source context in case the rough I/O was too early/late.

Show a locally zoomed timeline centered around the candidate with a reasonable amount of media before and after it.

Exact default context duration may be tuned during implementation.

Requirements:

- enough context to recover a missed word or late mark;
- user may seek farther into the source if needed;
- do not force the whole source recording into the primary detailed timeline at all times.

---

# 18. Refine Layout

In Refine, the **timeline becomes the main working surface**.

Recommended conceptual layout:

### Left
Persistent Sources sidebar.

### Center/top
Video preview, somewhat smaller than Capture.

### Center/main
Large detailed waveform/timeline showing:

- current answer boundaries;
- safe/buffer boundaries;
- removed internal ranges;
- surrounding source context.

### Right
Compact candidate queue/state:

- Approved
- Needs Review
- Skipped

### Primary controls
- Preview Answer
- Preview With Buffers
- Remove Selection
- Approve & Next
- Skip for Now
- Discard

---

# 19. Outer Answer Boundary Model

The current system uses rough raw marks and automatic refinement.

The new workflow should preserve that architecture conceptually while making the UI clearer.

## 19.1 Raw Capture I/O

Raw Capture marks must remain preserved in data.

They are useful for:

- diagnostics;
- rerunning future algorithms;
- recovering intent.

But they should not dominate the Refine UI.

Default presentation:

- hidden or very subtle ticks;
- optional **Show Original Marks** if useful.

## 19.2 Refined/manual answer boundaries

These are the prominent editable boundaries during Refine.

The user should be able to:

- drag start/end handles;
- select a boundary;
- nudge it with keyboard arrows;
- use larger modifier-based nudges if useful;
- preview around that edge.

## 19.3 Safe/buffer boundaries

Safe boundaries remain visually secondary and system-managed.

If the user manually changes an outer answer boundary:

> **recalculate the corresponding safe buffer automatically.**

Do not make the user manually manage two separate boundary systems under normal use.

---

# 20. Boundary Preview Behavior

Provide two distinct previews.

## Preview Answer
Primary preview.

Plays:

- actual visible answer;
- all approved internal cuts;
- internal crossfades;
- **no outer safe buffers**.

## Preview With Buffers
Secondary verification.

Plays:

- safe leading buffer;
- answer;
- safe trailing buffer.

Buffer preview is optional. It is not required before approval.

---

# 21. Future Boundary-Detection Work — Explicitly Out of Scope

The existing speech-start/speech-stop and safe-buffer detection needs future improvement.

This redesign should **not** become a boundary-algorithm rewrite.

However, architecture must not make that future work harder.

Design for:

- improved speech onset detection;
- improved speech ending detection;
- improved safe leading/trailing logic;
- rerunning new refinement algorithms;
- manual override;
- algorithm/version metadata if already useful;
- preserving raw user marks separately from derived boundaries.

Treat this as:

> **Known future work; design for it now, do not solve it unless naturally required by the redesign.**

---

# 22. Internal Cuts — Scope and Model

The user needs limited ability to trim pauses or unwanted sections from within an answer.

This must **not** become a full movie editor.

## 22.1 Interaction

In Refine:

1. select an unwanted range inside the answer;
2. choose **Remove Selection**;
3. range becomes visibly excluded;
4. Preview Answer skips it.

Repeat if necessary.

Nondestructive.

No razor/blade tool.
No tracks.
No transition inspector.
No movable clip objects.
No general NLE timeline.

## 22.2 Internal cut buffers

Internal cuts have **no safe buffers**.

This distinction is mandatory.

### Outer answer boundaries
Use normal answer refinement + safe-buffer logic.

### Internal cut boundaries
Use exact user-selected edit points.

Do not apply speech-buffer expansion around internal cuts.

## 22.3 Internal crossfade/dissolve

At each internal cut, join the retained pieces with an automatic tiny crossfade:

- approximately **0.1–0.2 seconds**;
- both video and audio;
- no user-configurable duration;
- no transition UI;
- intent is only to soften awkward visual/audio jumps.

It should not feel like a stylistic dissolve.

## 22.4 Multiple internal cuts

Allowed.

An answer candidate may therefore be represented internally as multiple retained segments from the **same source recording**.

---

# 23. One Candidate Per Question

A single canonical question gets **one assigned candidate answer at a time**.

Do not build a UI for composing one question from:

- candidate A from Recording 1;
- candidate B from Recording 2.

If another answer to the same question is found, the user compares and either:

- keeps the current answer;
- replaces it with the new candidate.

Internal cuts inside one candidate are allowed.

Combining separate candidates into one answer is out of scope.

---

# 24. Approval State

Approval is explicit.

A candidate created during Capture is not automatically “good.”

During Refine it becomes one of:

- unresolved / not yet reviewed;
- skipped for now;
- approved;
- discarded/recently discarded.

## 24.1 Editing an approved clip

Opening or previewing changes nothing.

A substantive edit such as:

- changing outer boundaries;
- changing an internal cut;
- adding/removing an internal cut;

invalidates approval.

State becomes:

> **Needs Review**

This applies whether the clip is:

- unassigned;
- already assigned to a question.

### Assigned answer edits
The answer stays attached to the question while Needs Review.

Use **Approve Changes** to restore reviewed status.

### Unassigned approved clip edits
It remains unassigned but should no longer appear in the normal ready-to-assign pool until approved again.

---

# 25. Assignment — Primary Goal

Assignment answers:

> **Which canonical question does this approved clip belong to?**

Only **approved, unassigned** clips belong in the normal assignment pool.

---

# 26. Assignment Layout

Recommended two-pane workspace.

## Left / center — Approved unassigned clips

Cards show:

- stable automatic clip ID;
- thumbnail;
- duration;
- source recording;
- source time or other useful orientation;
- transcript snippet if available;
- Play control.

Cards are draggable.

Ordering:

1. source order;
2. source-time/capture order within source.

No manual naming required.

Stable IDs should not renumber unpredictably when neighboring clips are deleted.

## Right — Questions

Show questions in canonical project order.

Each question clearly indicates:

- Answered
- Unanswered

No search/filter is needed because the question set is small.

Answered questions remain valid drop targets.

---

# 27. Assignment Interaction

## 27.1 Primary method
Drag an approved clip onto a question.

## 27.2 Secondary method
Provide a simple non-drag action such as:

> **Assign to Question…**

This is useful because the tool may not be used for months and drag behavior should not be the only discoverable mechanism.

## 27.3 Assign to unanswered question
Assign immediately.

The clip leaves the unassigned pool.

## 27.4 After assignment
The question becomes the clip’s permanent home in the UI.

From the question, user can:

- play answer;
- inspect source;
- Edit/Refine answer.

Editing does not unassign it.

---

# 28. Duplicate Answer / Compare and Replace

A later source recording may contain another answer to a question that already has one.

This interaction must stay deliberately simple.

Dropping a new candidate onto an answered question opens a lightweight comparison:

### Current Answer
- Play
- source
- duration
- transcript snippet if available

### New Candidate
- Play
- source
- duration
- transcript snippet if available

Decisions:

- **Keep Current**
- **Replace with New**

Do not expose take-management terminology.

No waveform editing inside compare.

If one needs editing, leave comparison and refine it.

## Replacement behavior

If replacing:

- new candidate becomes assigned;
- previous answer becomes approved + unassigned;
- previous answer returns to the unassigned pool;
- no destructive deletion.

---

# 29. Unassign

Provide a deliberate **Unassign Answer** action.

Unassigning:

- removes answer from the question;
- returns the intact clip to approved/unassigned;
- preserves all refinement/internal-cut work;
- leaves question unanswered.

Unassign is different from Discard.

---

# 30. No “Unused” Clip State

Do **not** create an explicit Unused state.

There was no concrete workflow need for it.

Approved clips are simply:

- assigned;
- unassigned.

If an approved clip never gets assigned, that is sufficient information.

Do not force the user to formally classify why.

---

# 31. Clip-Level Transcription

Transcription is useful, but currently considered flaky on whole recordings.

New rule:

> **Do not transcribe the entire source recording as a workflow prerequisite.**

Instead, after a candidate is created, Interview Studio may attempt **clip-level transcription** in the background.

## Requirements

- completely optional;
- never blocks Capture;
- never blocks Refine;
- never blocks Assign;
- never blocks Finish;
- quiet failure;
- transcript is convenience metadata only;
- thumbnail/duration/source/playback must remain enough to use the workflow.

## After edits

If the clip changes:

- old transcript becomes stale;
- re-run transcription when practical;
- continue normally while pending;
- failure is harmless.

Transcript is never a source of truth.

---

# 32. Suggested Question — Conditional Enhancement

If clip transcription is reliable enough, Interview Studio may attempt to suggest a likely canonical question.

Example:

> Suggested Question: “What was your favorite part of summer?”

Rules:

- suggestion only;
- never auto-assign;
- never hide other questions;
- never block manual assignment;
- only implement if current macOS/local techniques are trustworthy enough and inexpensive enough.

This is **conditional polish**, not a required feature.

Codex `/grill-me` should explicitly assess whether this is worthwhile.

---

# 33. Canonical Questions

Questions are **global project entities**, not year-specific snapshots.

Use stable question identity.

## 33.1 Editing wording

Editing the text of an existing question updates that question globally.

The newest wording is what should appear before all of its answers in the final movie.

Do not preserve old per-year wording copies.

If the user actually wants a meaningfully different question:

> create a **new question** with a new stable identity.

Leave the old question unanswered in future years if it is no longer asked.

## 33.2 Reordering questions

Canonical question order is global/current.

If order changes later, the newest order controls final movie structure.

## 33.3 Adding new questions

New questions may be added later.

They should be available for subsequent years.

Older years simply have no answer for them unless explicitly edited later.

## 33.4 Question management location

Keep question management separate from Assign.

Provide project-level **Manage Questions** for:

- Add
- Edit wording
- Reorder

Assign should consume the canonical list, not manage it.

---

# 34. Final Movie Structure

Legacy and new-workflow years must render together seamlessly.

The final movie should not expose which editor created an answer.

For each canonical question:

1. show the question using the **current canonical wording**;
2. use the **current canonical question order**;
3. include only years that have an actual assigned answer;
4. order those answers chronologically.

The visible label associated with each answer is **age**, not year.

Example:

- Age 4
- Age 6

If no answer exists for Age 5:

> go directly from Age 4 to Age 6.

No placeholder.
No “No answer.”
No empty title card.

Canonical age already exists per year and should continue to be manually managed.

---

# 35. Finish / Lock Year

Finish is a readiness summary, not another editor.

Show:

- number of questions with assigned answers;
- unanswered question count;
- approved unassigned clip count;
- skipped/unreviewed candidate count;
- sources still Not Started/In Progress;
- media consolidation status;
- any hard blockers.

Each warning/blocker should be actionable/clickable and take the user to the relevant place when practical.

Primary action:

> **Lock Year**

---

# 36. Finish: Hard Blockers vs Warnings

## Hard blockers

Examples:

- an assigned answer has Needs Review edits;
- a Capture source contains an unmatched provisional I with no O;
- required media is missing;
- required consolidation failed/incomplete;
- document/media state would risk incorrect or missing render output.

Do not lock/render through a state that risks data corruption or ambiguous output.

## Warnings, user may proceed

Examples:

- unanswered questions;
- approved clips still unassigned;
- candidates still skipped/unreviewed;
- a source remains Not Started;
- a source remains In Progress.

The user may deliberately lock despite warnings.

---

# 37. Locking Does Not Destroy Editing State

Locking means:

> **This is the version approved for publication/rendering.**

Locking must **not** delete, collapse, or purge:

- approved unassigned clips;
- skipped candidates;
- discarded recovery metadata;
- source progress;
- unresolved candidates;
- internal edits;
- source recordings.

If the year is later unlocked, editing state should return exactly as it was.

Actual cleanup remains a separate explicit operation.

---

# 38. Final Movie Generation

The existing app already has a lock/publication/final-render path.

This redesign should feed into that system rather than redesigning movie generation from scratch.

However, implementation will likely need to adapt the publication layer for:

- candidates with multiple retained internal segments;
- tiny internal audio/video crossfades;
- new answer/candidate state;
- seamless coexistence with legacy answers.

Once real interview data is running through the system, final movie pacing, buffer behavior, transitions, and related output details may be tuned separately.

Do not speculatively redesign the entire final-movie system now.

---

# 39. Source Media Storage Strategy

This is a major data-safety area.

## 39.1 Working model

Newly added recordings may initially be **external references**.

Reason:

- avoid immediate project bloat;
- avoid copying many GB before needed;
- allow lightweight setup.

## 39.2 Consolidation is mandatory, not optional

The project must not permanently depend on external file locations.

Normal macOS Save/Auto Save should make the project self-contained.

Conceptually:

> external reference = temporary staging  
> saved project = consolidated/self-contained

There may be technical reasons to separate lightweight metadata autosave from large media copy operations internally, but the user should not need to remember a special consolidation command.

---

# 40. Automatic Save and Consolidation

Use normal macOS automatic saving.

When external media is pending consolidation:

- copy it safely into the project package;
- do not repeatedly copy the same data;
- do not block the UI unnecessarily;
- never report success before copy is complete and verified;
- failure must be surfaced.

If an external file disappears before consolidation:

> offer **Locate Recording…**

Do not silently drop it.

---

# 41. What Gets Consolidated

If a source contributes anything still considered potentially useful, preserve the **complete original source recording**.

Do **not** trim the original down to only used answer ranges.

Reason:

- future re-refinement;
- recovery if a boundary was wrong;
- discovering missed material later;
- archival safety.

A full source is considered needed if it has any surviving candidate such as:

- assigned answer;
- approved unassigned candidate;
- skipped-for-now candidate;
- otherwise retained candidate.

---

# 42. Source Cleanup Rules

## 42.1 Not Started / In Progress source

Automatically retain/consolidate.

Do not call it unused merely because it has no candidates yet.

## 42.2 Finished source with surviving candidates

Automatically retain/consolidate full source.

## 42.3 Finished source with zero surviving candidates

This source is legitimately unused.

Ask whether to:

- Keep in Project
- Exclude/Remove from Project

Do not silently remove it.

---

# 43. Previously Consolidated Source Becomes Unused

Example:

1. Recording 2 was consolidated because it had a candidate.
2. Later that candidate is discarded.
3. Recording 2 now contributes nothing.

Interview Studio may detect:

> Recording 2 is no longer used by this interview.

It may offer to remove the project’s internal copy and show potential space savings.

However:

> **Save may automatically add required media. Save may never automatically delete previously consolidated media.**

Removal always requires explicit confirmation.

If the user chooses Keep, persist that decision so the app does not nag on every future save merely because the source remains unused.

---

# 44. Never Delete External Originals

This is a hard invariant.

Any **Remove from Project** operation means:

> remove Interview Studio’s internal project copy/reference only.

Interview Studio must never delete or modify:

- Desktop original;
- Finder original;
- exported source;
- external drive original;
- any external source location.

---

# 45. Data Safety — Hard Architectural Requirement

Data preservation is more important than aggressive cleanup.

Bias toward retaining data whenever state is ambiguous.

### Automatic behavior may be additive.
### Destructive behavior must be explicit.

Implementation must be careful around:

- interrupted media copies;
- crashes;
- autosave during copy;
- partial files;
- inconsistent metadata;
- failed consolidation;
- stale references;
- source replacement;
- package writes;
- undo/redo interactions.

If uncertain:

> keep existing data.

Do not optimistically delete because metadata “looks unused.”

Consider robust transactional/atomic strategies where appropriate.

---

# 46. Removing a Source Recording Manually

`Remove Recording…` must be strongly data-safe.

## No candidates
Allow removal after simple confirmation.

## Has candidates, none assigned
Warn that candidates depend on the source and require explicit confirmation before removing them.

## Has assigned answers
Do **not** allow simple cascading removal.

Tell the user which assigned questions depend on the source.

Require those answers to be:

- unassigned;
- replaced;

before the source can be removed.

Removing source from Interview Studio never deletes the original external file.

If removing a consolidated internal copy, require explicit confirmation.

---

# 47. Recently Discarded

Discard should not equal unrecoverable destruction.

Provide a lightweight **Recently Discarded** area for the year.

Discarded candidates:

- disappear from active workflow;
- remain recoverable;
- retain their source relationship;
- do not delete source media.

Recently Discarded is not a complex trash-management system.

## Persistence

Discarded candidates remain recoverable indefinitely until explicitly purged.

Do **not** purge because of:

- Save;
- Auto Save;
- closing project;
- locking year;
- rendering final movie.

## Permanent purge

Only via explicit action such as:

> **Permanently Delete Discarded Clips**

with confirmation.

Even permanent candidate purge must not delete the source recording.

---

# 48. Undo / Redo

Provide strong normal macOS Undo/Redo for editorial actions.

Examples:

- delete recent capture candidate;
- discard candidate;
- restore candidate;
- move outer boundary;
- add/remove internal cut;
- assign clip;
- replace assigned answer;
- unassign answer;
- edit answer.

Do not try to make huge file-management/consolidation operations ordinary Undo-stack actions.

Media cleanup uses explicit confirmations and separate safeguards.

---

# 49. Workspace Restoration

Because work may span sessions, reopening should restore context closely.

Persist at least:

- open year;
- active workspace destination;
- selected source;
- source resume position;
- selected candidate in Refine;
- selected candidate in Assign when sensible;
- unresolved/skipped state;
- source status.

Never autoplay on reopen.

Example:

If the user quits while refining Clip 12 from Recording 2:

> reopen to Recording 2 → Refine → Clip 12, paused.

---

# 50. Performance Principles

The new system must not create major lag, memory pressure, or unnecessary disk pressure.

Important principles:

- only one active source player at a time;
- release old player resources appropriately;
- do not transcribe entire long files;
- do not eagerly run expensive analysis across every source;
- clip-level background work should throttle when playback needs resources;
- waveform/media analysis should cache sensibly;
- project UI should remain responsive during consolidation;
- large file copies should not masquerade as ordinary lightweight saves if that would freeze the app.

The user prefers the aesthetically clean “add all recordings up front” experience only if it does not materially harm performance.

---

# 51. Legacy Years and New Years

## Legacy years

- remain editable with legacy interface;
- no migration required;
- keep current behavior.

## New-workflow years

- use new workspace;
- should not be edited through legacy interface;
- preserve new concepts such as candidate state, internal cuts, assignment state, source progress.

## Rendering

Legacy and new years render together seamlessly.

Workflow provenance is not visible in the final movie.

---

# 52. State Model — Conceptual

Codex should refine exact implementation types, but product semantics should resemble the following.

## SourceRecordingState
- notStarted
- inProgress
- finished

## CandidateReviewState
Possible conceptual states:

- captured/unreviewed
- skippedForNow
- approved
- needsReview
- discarded/recentlyDiscarded

## AssignmentState
For an approved candidate:

- unassigned
- assigned(questionID)

No explicit Unused state.

## Year lock state
- open/editable
- locked

Lock does not destroy unresolved material.

---

# 53. Candidate Data — Conceptual Requirements

A candidate needs enough data to support:

- stable clip identity;
- source recording identity;
- raw Capture I;
- raw Capture O;
- refined/manual visible outer boundaries;
- safe outer boundaries;
- ordered retained segments after internal removals;
- internal removal ranges or equivalent representation;
- approval/review state;
- assignment state;
- transcript metadata/status;
- optional question suggestion metadata;
- creation/capture ordering;
- Recently Discarded recovery.

Do not force the UI to expose implementation-oriented “take” or “part” concepts.

---

# 54. Internal Segment Representation — Important Implementation Note

Because internal cuts are allowed, an answer may no longer be representable as a single continuous `start → end` range.

A useful conceptual representation is:

> one candidate → one source recording → ordered retained time ranges

Example:

- 10:00–10:12
- 10:14–10:31
- 10:34–10:45

Each internal join gets the automatic tiny AV crossfade.

Outer safe buffers belong only to the answer’s true outer boundaries.

Internal boundaries do not receive safe buffers.

Codex should examine whether the existing answer-part model can cleanly support this without exposing unnecessary complexity.

---

# 55. Capture and Refine State Separation

Do not conflate:

- candidate captured;
- candidate refined;
- candidate approved;
- candidate assigned.

These are different user decisions.

The current legacy interface has a seam where these concepts are not strongly distinguished. The redesign should be clearer.

---

# 56. Save/Consolidation and Editing-State Separation

Do not conflate:

- clip discarded;
- source unused;
- source removable from project;
- external original removable.

They are different things.

Candidate discard does not delete source.

Source cleanup removes only project-internal media and only after explicit authorization.

External originals are never deleted.

---

# 57. End-of-Recording Flow

After the last clip in a recording is refined, present simple next actions:

- **Process Next Recording**
- **Assign Answers**

If unresolved/skipped candidates remain:

- mention them;
- do not block either action.

If this was the final source:

- Assign Answers becomes the natural prominent next step;
- Add Recording remains available later.

---

# 58. Assignment Availability

Assignment is always available.

The user does not have to wait until every source is finished.

This is important because it allows:

- progressive organization;
- questions to show answered state while later sources are still being processed;
- natural handling of duplicate answers discovered later.

---

# 59. Question List in Assign

Use current canonical question order.

Show only clear answer state.

No search/filter needed.

Answered questions remain drop targets.

The final canonical order should always be the newest global order.

---

# 60. Age and Year Semantics

## Age
Canonical per-year age already exists.

Continue manual entry/update.

Age is what appears in the final movie.

## Year
Collect and store year on new-year creation for future-proofing.

Current output logic does not need to use it.

---

# 61. Missing Answers in Final Movie

If a question has answers at Age 4 and Age 6 but none at Age 5:

> render Age 4 → Age 6.

No placeholder.

If a question was added years later, older years without that answer are simply omitted from that question’s answer sequence.

---

# 62. Optional / Secondary Features

These should not delay the core redesign.

## Intended secondary features
- clip-level background transcription;
- Refine All Unreviewed;
- Recently Discarded;
- strong Undo/Redo;
- full workspace restoration;
- lightweight compare/replace.

## Conditional polish
- transcript-based likely-question suggestion;
- playback speed control;
- speech/silence jump commands.

If conditional features are unreliable or expensive, skip them.

---

# 63. Explicitly Out of Scope for This Pass

Do not allow the redesign to balloon into these projects:

- full movie editor/NLE;
- full transcript editor;
- whole-recording transcript-driven answer picker;
- complex take management;
- combining separate candidates into one answer;
- legacy-year migration;
- rewriting all final movie generation logic;
- completely redesigning speech/buffer analysis;
- generalized multi-user/product architecture;
- old macOS compatibility work;
- cross-platform support.

---

# 64. UX Principles

The implementation should feel:

- obvious;
- forgiving;
- reversible;
- keyboard-efficient;
- visually calm;
- native to macOS;
- easy to re-learn after months away.

Avoid:

- hidden modes;
- dense professional-editor terminology;
- destructive one-way actions;
- clever state inference where an explicit label is safer;
- modal dialogs during rapid Capture;
- forcing transcription/analysis success before continuing.

---

# 65. Core Workflow Examples

## Example A — Normal single-source new year

1. Start New Year.
2. Enter year and age.
3. Add Recording 1.
4. Capture:
   - I
   - O
   - I
   - O
   - etc.
5. Finish Recording.
6. Refine Clips.
7. Approve each usable clip.
8. Assign approved clips to questions.
9. Finish screen shows readiness.
10. Lock Year.
11. Final movie path uses the answers.

## Example B — O pressed too early

1. Press I.
2. Press O too early.
3. Continue playback.
4. Press O again.
5. Latest O replaces the earlier O.
6. Press I for next answer.
7. Previous candidate commits.

No Undo required.

## Example C — I pressed too early

1. Press I.
2. Realize answer has not started.
3. Press I again.
4. Latest I replaces earlier I.

## Example D — pause after I/O

1. Press I.
2. Press O.
3. Pause.
4. Candidate remains provisional.
5. Resume.
6. Optionally press O again.
7. Next I commits it.

## Example E — leaving with valid I/O

1. Press I.
2. Press O.
3. Choose Refine Clips.
4. Candidate commits automatically.
5. Enter Refine.

## Example F — leaving with unmatched I

1. Press I.
2. Choose another source.
3. Interview Studio warns about unfinished clip.
4. Return to Capture or explicitly discard the I point.

## Example G — internal pause removal

1. Candidate approved for rough outer range.
2. Select unwanted pause inside answer.
3. Remove Selection.
4. Preview Answer skips removed range.
5. Retained segments are joined with ~0.1–0.2 sec AV crossfade.
6. No internal safe buffers.

## Example H — duplicate answer discovered later

1. Recording 1 produces Clip 4.
2. Clip 4 assigned to Question 8.
3. Recording 2 later produces Clip 17 that also answers Question 8.
4. Drag Clip 17 onto Question 8.
5. Compare Current vs New.
6. Choose Replace.
7. Clip 17 becomes assigned.
8. Old Clip 4 returns to approved/unassigned.

## Example I — source becomes unused

1. Recording 3 is consolidated.
2. Its only candidate is later discarded.
3. Recording 3 now contributes nothing.
4. On save/cleanup, Interview Studio offers:
   - Keep in Project
   - Remove from Project
5. Never delete the external original.
6. Never remove automatically.

---

# 66. Implementation Risk Areas Codex Must Examine

The `/grill-me` pass should challenge the design specifically around these areas.

## Data model
- Best representation for candidate lifecycle.
- Whether existing AnswerTake/AnswerPart can support the new workflow cleanly.
- How to support internal retained segments without contaminating legacy behavior.
- Stable identity and ordering.
- How legacy and new answers coexist in publication.

## Media handling
- Safe referenced-media staging.
- Auto Save + large media consolidation.
- Atomic/transactional copy behavior.
- Recovery after interrupted copy.
- Detecting/repairing missing external source before consolidation.
- Avoiding duplicate multi-GB copies.
- Safe internal package cleanup.

## AV playback
- Smooth Capture while analysis/transcription runs.
- Accurate I/O timestamp capture.
- Current implementation uses periodic player time updates; investigate whether new Capture should sample more accurately at keypress.
- Seek behavior around candidate boundaries.
- Previewing multipart retained segments.

## Crossfades
- Implement ~0.1–0.2 sec audio+video crossfade at internal cuts.
- Ensure no accidental outer-buffer behavior at internal boundaries.
- Make publication/export match Refine preview.

## Automatic refinement
- Preserve raw marks.
- Apply/refuse stale background results correctly.
- Recalculate safe buffers after manual outer edit.
- Keep algorithm replaceable for future work.

## Transcription
- Reliable clip-level transcription on current macOS.
- Background scheduling.
- cancellation/stale results after edits.
- whether suggested question ranking is trustworthy enough to ship.

## Undo
- Correct Undo/Redo integration with model mutations.
- Avoid Undo corrupting background-analysis/consolidation state.

## Lock/render
- Ensure new multipart candidates render seamlessly alongside legacy answers.
- Preserve unresolved editing state when locked.
- Hard blocker validation.

---

# 67. `/grill-me` Instructions for Codex

Before implementing, perform a rigorous `/grill-me` pass against this document.

The purpose is **not** to reopen settled product preferences casually.

Instead, challenge the plan where implementation reality creates:

- data-loss risk;
- contradictory state semantics;
- AVFoundation limitations;
- persistence/consolidation hazards;
- impossible or fragile Undo behavior;
- significant performance problems;
- conflicts with the existing project model;
- publication incompatibility;
- unnecessarily large architectural changes.

For each concern:

1. cite the specific requirement involved;
2. explain why it is risky or contradictory;
3. propose the smallest practical adjustment;
4. clearly distinguish:
   - required product change;
   - implementation detail;
   - optional optimization.

Do not expand scope merely because a more generalized architecture is aesthetically appealing.

This is an internal single-user macOS tool.

---

# 68. Implementation Priorities

Suggested order:

## Phase 1 — Data model and persistence safety
- new-workflow year marker/version;
- source states/order/resume;
- candidate model;
- approval state;
- assignment state;
- internal segments;
- Recently Discarded;
- legacy coexistence;
- save/consolidation plan.

## Phase 2 — Capture
- source list;
- player;
- waveform;
- I/O state machine;
- candidate strip;
- keyboard shortcuts;
- persistence/resume.

## Phase 3 — Refine
- source-specific queue;
- Refine All;
- outer boundary editing;
- preview modes;
- internal cuts;
- crossfades;
- approval/skip/discard;
- Needs Review.

## Phase 4 — Assign
- unassigned pool;
- question list;
- drag/drop;
- Assign to Question fallback;
- compare/replace;
- unassign;
- edit assigned answer.

## Phase 5 — Finish/Lock
- readiness summary;
- blockers/warnings;
- lock integration;
- unlock restoration;
- final publication compatibility.

## Phase 6 — Background convenience
- clip transcription;
- transcript display;
- optional question suggestion if trustworthy;
- optional playback speed;
- optional speech/silence navigation.

---

# 69. Acceptance Criteria — Core Workflow

A build should not be considered functionally complete until the following are true.

## New year
- can create a new year with year + age;
- can create with zero sources;
- can add multiple sources later;
- Sources list persists and can reorder.

## Capture
- active source plays smoothly;
- I/O rules work exactly as specified;
- repeated I and O correction works;
- pause does not commit;
- leaving with valid I/O commits;
- unmatched I warns;
- candidates appear in compact strip;
- recent candidate may be replayed/deleted;
- playback is not interrupted by candidate creation.

## Refine
- source-specific queue works;
- Refine All works;
- surrounding context is available;
- outer boundaries can be adjusted;
- safe buffers remain secondary;
- changing outer boundary recalculates buffer;
- internal selection can be removed;
- internal cuts have no buffers;
- internal AV crossfade works;
- Preview Answer vs With Buffers is correct;
- Approve/Skip/Discard behave correctly;
- no autoplay after advancing;
- skipped clips can be revisited;
- edits invalidate prior approval.

## Assign
- only approved/unassigned clips appear normally;
- drag/drop assignment works;
- non-drag assignment fallback works;
- questions show answered/unanswered;
- assigned clip leaves pool;
- question becomes home for assigned answer;
- duplicate assignment invokes compare;
- replace returns prior answer to pool;
- unassign returns answer to pool.

## Persistence
- app restores workspace context;
- source resume position persists;
- autosave does not lose work;
- required media eventually consolidates;
- missing source can be relocated;
- consolidated media is never silently removed;
- external originals are never deleted.

## Finish
- warnings/blockers are correct;
- unresolved noncritical work does not block;
- true unsafe states block;
- locking preserves all editing data;
- unlocking restores state;
- legacy and new answers render together.

---

# 70. Non-Negotiable Data-Safety Invariants

These should be treated as testable invariants.

1. **Never delete external original source media.**
2. **Never silently remove previously consolidated media.**
3. **Never silently discard an unmatched In point when leaving Capture.**
4. **Never make transcript success required.**
5. **Never make automatic boundary refinement success required.**
6. **Never destroy unresolved candidate state merely because a year is locked.**
7. **Never purge Recently Discarded automatically.**
8. **Never let background analysis overwrite newer user edits with stale results.**
9. **Never allow source removal to orphan an assigned answer.**
10. **When state is ambiguous, preserve data rather than clean it up.**

---

# 71. Important Existing Behavior to Revisit Carefully

The current legacy implementation records marker times from a periodic AVPlayer observer. That means the raw marker can reflect the most recently observed UI time rather than a freshly sampled timestamp exactly at keypress.

Because rapid I/O capture becomes a central interaction in the new design, Codex should explicitly investigate whether the new workflow should capture the player time more directly/accurately on the key action.

This is an implementation-quality investigation, not an invitation to change the I/O UX.

---

# 72. Final Product Vision

The new Interview Studio year workflow should feel like this:

> Open the year.  
> Pick the recording.  
> Play it.  
> Tap I and O as answers happen.  
> Keep going.  
> Clean the clips up afterward.  
> Remove a pause if necessary.  
> Approve them.  
> Drag them onto the right questions.  
> Compare and replace if a better duplicate appears.  
> Finish the year.  
> Render the same chronological age-based interview movie as before.

The user should never feel like they are operating a professional nonlinear editor, managing complex “takes,” or fighting a transcript system.

The application should do the organizational and archival work quietly and conservatively behind the scenes while remaining extremely reluctant to destroy anything.

---

# 73. Final Scope Classification

## Core requirements
- Start New Year vs Legacy Interface split
- recording-first new-year workflow
- persistent Capture / Refine / Assign / Finish workspace
- multiple sources
- source state/order/resume
- rapid forgiving I/O capture
- candidate strip
- background boundary analysis
- source-specific Refine
- Refine All
- explicit approval/skip/discard
- editable outer boundaries
- automatic safe-buffer recalculation
- internal cuts
- no internal buffers
- tiny AV crossfade
- assignment drag/drop + fallback
- compare/replace
- unassign
- Needs Review after substantive edit
- project-level canonical questions
- current question text/order global
- age-based chronological final output
- Finish blockers/warnings
- lock/unlock integration
- safe media consolidation
- conservative cleanup
- Recently Discarded
- strong Undo/Redo
- workspace restoration
- legacy/new seamless publication

## Secondary intended
- clip-level background transcription
- transcript snippets
- lightweight source/candidate progress summaries

## Conditional polish
- likely-question suggestion from transcript
- playback speed
- speech/silence jumps

## Future work
- improve speech-start/speech-stop detection
- improve safe-buffer detection
- potentially tune final movie assembly after real-world use

---

# 74. Closing Direction to Codex

Treat this document as the product specification for the redesign.

Run `/grill-me` first.

Do not begin by rewriting the entire app.

Prefer incremental changes that preserve:

- legacy years;
- existing project data;
- existing final rendering behavior;
- source-media safety.

Where the current architecture is incompatible with these requirements, explain the conflict clearly and propose the smallest robust migration.

The most important qualitative goals are:

> **Fast Capture. Clear Refine. Simple Assign. Safe Data. No accidental destruction.**
