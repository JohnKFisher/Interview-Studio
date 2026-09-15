# Current Answer-Picking and Refinement Flow

Status: current-checkout behavior map, not a replacement design.

This document describes how an editor currently picks a spoken answer from an imported interview recording, refines its boundaries, associates it with a question, reviews it, completes it, and moves to the next question. It is intended as the baseline for designing a replacement flow.

## 1. Starting context

The editor opens a saved Interview Studio project and selects an interview year in the Project sidebar. The year must be open to edit. A year that has already been locked must first be unlocked.

The source recordings are imported into the selected interview year through the Questions toolbar. The current import path stages newly selected files and displays them immediately; saving the project persists the staged recordings into the project package. The answer editor can then resolve the recording from the package or its pending import staging area.

The working screen is a three-column macOS layout:

1. Project sidebar: the person and interview years.
2. Questions list: the ordered questions and each question's progress state.
3. Answer Editor: the selected question, recording player, waveform, marker controls, transcript panel, and review actions.

The current answer workflow is question-first. There is no separate global “pick an answer” queue or answer-bin screen.

## 2. Selecting the question and source recording

The editor clicks a question in the Questions list. That changes `selectedQuestionKey`, which identifies the question being edited. The question's stable `questionKey` is not changed by editing its displayed text.

For the selected interview year, the editor has a `selectedRecordingID`. In practice, the recording shown in the editor is resolved as follows:

1. If the selected answer already has a selected take, prefer the first answer part's source recording.
2. Otherwise use the explicitly selected recording.
3. Otherwise fall back to the first recording in the interview year.

This means selecting a different question can also change which recording is shown if that question already has an answer part attached to a recording. The editor does not currently choose a source recording through a dedicated “attach this recording to this question” step.

When the question or recording changes, the player preview is stopped, the current source time is reset to zero, and the waveform/media analysis is loaded or retrieved from cache for the new recording. A new `AVPlayer` is created when the resolved URL or analysis context changes.

Relevant implementation: [`DocumentWorkspace.swift`](/Users/jkfisher/Documents/Coding/Projects/Interview%20Studio/Sources/App/DocumentWorkspace.swift:74), [`DocumentWorkspace.swift`](/Users/jkfisher/Documents/Coding/Projects/Interview%20Studio/Sources/App/DocumentWorkspace.swift:107), and [`DocumentWorkspace.swift`](/Users/jkfisher/Documents/Coding/Projects/Interview%20Studio/Sources/App/DocumentWorkspace.swift:1270).

## 3. Finding a candidate answer

The editor uses the recording player to find the answer manually. They can:

- play the full recording;
- pause it;
- seek by clicking the waveform;
- seek by one-second increments;
- enter a source time in the seconds field; or
- use the player controls to scrub.

The waveform is an amplitude view of the selected recording. Before an answer has boundaries, it represents the full source recording. After boundaries exist, it overlays the current answer range and any calculated buffer range.

There is no current speech transcript-driven picker, candidate list, automatic question matching, or “next unreviewed answer” command. The editor decides which spoken section answers the selected question and manually marks it.

## 4. Marking the answer range

The Answer markers group shows the current source time and four marker actions:

- `Mark Start (I)` records the beginning of the candidate answer.
- `Mark End (O)` records the end of the candidate answer.
- `Interviewer Resumes (;)` records where interviewer speech resumes after the answer.
- `No Following Speech` declares that there is no following interviewer speech to protect against.

The `I` and `O` actions are now available both by clicking and by pressing the plain `I` or `O` key while the editor window has keyboard focus. The shortcut is implemented on the native SwiftUI buttons. The semicolon action remains click-only at present.

When a marker is pressed, the app stores the current `currentTimeUS` value as a raw `MediaTime`. The current time is fed by an AVPlayer periodic observer running every 50 ms, so the stored press point is the latest UI-observed player time rather than a separately sampled, synchronous timestamp at the exact key-down event.

If the selected question has no answer yet, the first marker creates an `InterviewAnswer`, an `AnswerTake`, and an `AnswerPart` attached to the currently resolved recording. If an answer exists, the marker updates the part for that recording in the selected take. If the selected take has no part for the recording, the action fails with “The selected recording is not attached to this answer.”

Every marker action:

1. updates the relevant raw marker;
2. discards any existing `refinedBoundaries` for that part;
3. sets the answer state to `in_progress`;
4. flushes the in-memory state to the document; and
5. starts or restarts asynchronous boundary refinement when both answer start and answer end are present.

The answer cannot be refined until it has both a start and an end, and the end must be later than the start.

Relevant implementation: [`DocumentWorkspace.swift`](/Users/jkfisher/Documents/Coding/Projects/Interview%20Studio/Sources/App/DocumentWorkspace.swift:901) and [`InterviewStudioModels.swift`](/Users/jkfisher/Documents/Coding/Projects/Interview%20Studio/Sources/Core/Phase2/InterviewStudioModels.swift:251).

## 5. Automatic boundary refinement

The two manually marked answer points are not treated as the final visible clip boundaries. They are hints used to locate nearby speech activity.

The refiner works on audio extracted from the selected video. It analyzes a local region rather than the entire recording:

```text
search start = max(0, marked start - 2.500 seconds)
search end   = min(recording duration, marked end + 0.250 seconds)
```

Audio is reduced to mono and evaluated in 10 ms windows. For each window the refiner calculates RMS loudness in dBFS. It estimates a local noise floor from the 20th percentile of the windows in the search region, clamps that estimate between -60 and -30 dBFS, and chooses a speech threshold of:

```text
max(noise floor + 12 dB, -36 dBFS)
```

A window initially counts as speech when its loudness reaches that threshold. The refiner then applies two continuity rules:

- a speech run must last at least 8 windows, or 80 ms;
- a silent gap of at most 120 ms between speech runs is filled in.

The resulting contiguous regions are treated as speech bursts. The refiner associates the start marker with the first burst containing or preceding the start point, and associates the end marker with the first burst containing or preceding the end point.

From those bursts it calculates two different ranges:

### Visible answer range

This is the range intended to contain the answer itself:

- visible start = matched start burst start minus 100 ms, clamped to the recording;
- visible end = matched end burst end plus 150 ms, clamped to the recording.

Therefore, the green visible markers can move away from the exact positions at which Start and End were pressed. The intended logic is to include the surrounding speech onset and release instead of cutting exactly at a potentially imprecise button point.

### Safe preview/publication range

This is the range used when the app wants additional context around the answer:

- safe leading start extends backward from the visible start toward the previous speech burst, with a maximum intended lead of 2 seconds and a 150 ms separation rule;
- if `No Following Speech` is marked, safe trailing end is the end of the recording;
- otherwise, if `Interviewer Resumes` is marked, safe trailing end is at most 150 ms before that marker, but never earlier than the visible end;
- otherwise, if a following speech burst is detected, safe trailing end is 150 ms before that burst;
- if no following speech is found, safe trailing end is the end of the recording.

The interviewer-resumes point does not directly replace the visible answer end. It primarily constrains the trailing safe buffer. If it falls inside the calculated visible answer, the result is flagged for review.

The result stores visible and safe boundaries, confidence, diagnostic reasons, algorithm identifier/version, and a `manualOverride` flag. Automatic results currently set `manualOverride` to false.

Relevant implementation: [`AnswerBoundaryRefinement.swift`](/Users/jkfisher/Documents/Coding/Projects/Interview%20Studio/Sources/Core/Phase2/AnswerBoundaryRefinement.swift:42) and [`MediaAnalysis.swift`](/Users/jkfisher/Documents/Coding/Projects/Interview%20Studio/Sources/App/MediaAnalysis.swift:153).

## 6. Seeing the result in the editor

While refinement runs, the editor shows “Refining answer boundaries…”. When it completes:

- the green waveform markers represent `visibleStart` and `visibleEnd`;
- the orange/safe markers represent `safeLeadingStart` and `safeTrailingEnd`;
- the timeline summary describes the selected visible range and buffers;
- a low-confidence or failed refinement produces a review/error message.

The answer state panel displays the answer state and the raw start/end values in microseconds. It does not separately display the refined boundary timestamps in the status text, so the refined result is primarily understood visually from the waveform and by previewing it.

Because refinement is asynchronous, a result is only applied if the selected year, question, recording, take, part, and raw marker values still match the request that produced it. Changing the selection or changing a marker cancels or invalidates older work.

## 7. Reviewing and previewing

The editor has three relevant playback modes:

1. `Preview Answer`: seeks to the refined visible start and stops at the refined visible end.
2. `Preview With Buffers`: seeks to the safe leading start and stops at the safe trailing end.
3. `Play Full Recording`: plays the source without a range boundary.

Range preview uses zero-tolerance AVPlayer seeking and a boundary observer. It pauses at the requested end and updates the displayed current time to that end. This is intended to keep playback aligned with the calculated range, although actual media/keyframe behavior still requires owner-level audible/visual verification.

The waveform can also be clicked to seek without changing any answer marker. Seeking is not itself an edit to the answer.

## 8. Completing or skipping the selected answer

The editor reviews the visible and buffered previews, then chooses one of two paths:

### Complete After Review

Completion requires:

- a selected interview year;
- a selected question;
- a selected recording attached to the selected take;
- both raw answer start and raw answer end; and
- a range that has made it through the editor's marker/refinement path.

The current completion guard explicitly checks that both raw markers are present, but it does not independently reject an end marker earlier than the start marker. Automatic refinement does require `answerEnd > answerStart`, so an out-of-order pair can leave refinement unavailable while the completion guard itself remains more permissive than the refinement guard.

On completion, the selected take becomes `reviewed`, the answer becomes `complete`, and `lastReviewedAt` is set. Completion does not itself set new boundaries or create a separate assignment record; the answer was already associated with the selected question and recording when the markers were stored.

### Mark Skipped

Skipping sets the selected question's answer state to `skipped`. It can create the answer record even when no range was marked. Skipped answers remain visible in the Questions list but are omitted from publication.

The main answer state progression is therefore:

```text
not_started -> in_progress -> complete
                         \-> skipped
```

`needs_review` is available in the data model and is used conceptually by low-confidence analysis, but the current UI primarily presents the refinement warning while leaving the answer in progress until the editor completes it.

## 9. Moving to the next answer

There is no explicit Next Answer or Next Unreviewed button in the current editor. The editor clicks the next question in the Questions list, usually following the displayed question order.

That selection change:

1. changes `selectedQuestionKey`;
2. resolves the answer and its preferred source recording for the new question;
3. stops any active range preview;
4. resets the visible source time to zero;
5. cancels or invalidates refinement and transcription work for the previous context;
6. loads the new recording's player and waveform; and
7. shows the new question's existing answer state, if any.

For a new question, the editor repeats the manual recording search, marker capture, automatic refinement, preview, and completion sequence. The current flow does not automatically advance after completion, preserve a separate “last reviewed position,” or guarantee that the next question is the next incomplete one.

## 10. Save, lock, and publication consequences

Marker changes and completion changes are flushed to the document model immediately. The user still needs to save the project to persist the document package. The year remains open while answers are being edited.

When all required work is ready, `Lock Year` validates and generates answer clips and a render plan for that interview year. After every interview year is locked, `Render Final Movie` builds the final production in question order.

Publication uses refined boundaries when available. If refinement is absent, the native publisher can fall back to raw start/end markers with a lower-confidence raw-marker boundary object. The actual source range used for native answer generation is the safe leading-to-safe trailing range, while manifest metadata records the visible answer boundaries and the raw marker values.

Relevant implementation: [`Publication.swift`](/Users/jkfisher/Documents/Coding/Projects/Interview%20Studio/Sources/Core/Phase2/Publication.swift:56) and [`DocumentWorkspace.swift`](/Users/jkfisher/Documents/Coding/Projects/Interview%20Studio/Sources/App/DocumentWorkspace.swift:844).

## 11. Current behavior seams to resolve in a replacement design

These are observations about the current flow, not decisions for the replacement:

- The workflow starts with a question, even though the editor's primary task is finding a good answer in source media.
- Source recording assignment is implicit. There is no explicit, inspectable “this answer comes from this recording” step in the UI.
- The app stores raw press hints and then replaces the visible range with VAD-derived boundaries. The relationship between the user's points and the green/orange markers is not obvious in the current UI.
- `currentTimeUS` is updated on a 50 ms periodic observer, so a button press is quantized to the latest observed player time.
- There is no explicit distinction between “candidate selected,” “refinement accepted,” and “answer committed.” `Complete After Review` is the main commit gate.
- Every marker change automatically starts refinement, rather than letting the editor choose when to analyze or whether to keep the raw points.
- The editor sees raw times in microseconds but refined times mainly as waveform markers; the two layers are not presented as a side-by-side decision.
- The visible answer range and safe publication/preview range are separate, but the reason for that separation is not strongly surfaced.
- `Interviewer Resumes` affects the safe trailing boundary more than the visible answer boundary, which may not match the editor's mental model of an end marker.
- `No Following Speech` expands the safe trailing range to the end of the recording; it does not mean the visible answer continues to the end.
- There is no answer candidate queue, confidence-ranked candidate list, next-unreviewed navigation, or automatic advance after completion.
- The current take model can represent multiple parts, but this screen's normal interaction creates or edits one part for the selected recording and does not expose a deliberate multipart workflow.
- A skipped answer has no media selection requirement and is omitted later, but skipping is presented alongside marker completion rather than as a separately explained disposition.

## 12. Replacement-flow questions this baseline leaves open

The redesign can decide, explicitly:

1. Should the editor begin from a question, from a recording, or from a queue of unanswered questions and candidate answer regions?
2. Should selecting a source recording be a first-class assignment action?
3. Should answer selection be exact/manual, speech-assisted, transcript-assisted, or a combination?
4. Should raw press points remain visible independently from automatic visible boundaries?
5. Should refinement happen continuously, on demand, or only after the editor accepts a candidate?
6. What is the explicit review contract: preview only, accept boundaries, reject/refine, or complete?
7. Should the editor be able to adjust visible and safe boundaries directly and preserve that as a manual override?
8. After completion, should the app advance to the next question, next unanswered question, or a user-selected queue item?
9. How should multiple recordings, retakes, multipart answers, and alternate takes be selected and compared?
10. What must remain visible after leaving an answer so the editor can trust what was committed?
