# Decisions

## 2026-05-03 - Publish the project as a GitHub repository
Initial project files are being committed to a new GitHub repository so future work has version history and a shared remote. Status: approved.

## 2026-05-03 - Phase 1 is a SwiftPM-first macOS Assembly Studio
The first implementation pass uses a SwiftPM core library plus a native macOS app target and a CLI target for smoke verification. This keeps manifest parsing, render planning, media inspection, and rendering testable outside the UI. Status: approved.

## 2026-05-03 - Lock Phase 1 exports to one HDR profile
Phase 1 exports are fixed to `3840x2160`, `60 fps`, `HLG`, `BT.2020`, `bt2020nc`, `HEVC Main10`, and `MOV`, with export blocked when required FFmpeg capabilities or HDR safety checks fail. This keeps Phase 1 deterministic and avoids shipping multiple partially-supported output modes. Status: approved.

## 2026-05-03 - Use ProRes intermediates and a final HEVC assembly encode (superseded)
The renderer originally wrote 10-bit ProRes intermediate segments and performed the HEVC Main10 encode at final assembly time. This was chosen after repeated per-segment x265 renders proved too slow and harder to debug. The approach was later superseded by the hardware-HEVC path below after real runs showed that ProRes scratch volume and software HEVC assembly were still unacceptable.

## 2026-09-16 - Use standard ProRes 422 for Phase 1 intermediates (superseded)
The short-lived ProRes 422 reduction preserved 10-bit 4:2:2 pixels but did not solve the observed peak-space and runtime problem. It remains historical context for the renderer experiments, not the preferred production path.

## 2026-09-16 - Assemble Phase 1 in bounded HEVC chunks
Phase 1 groups the ordered segments into deterministic approximately 60-second chunks, deletes only validated source segments for each completed chunk, and stream-copies the chunks into the final master while rebuilding final audio timestamps before the one AAC encode. This topology remains active, but its segment/chunk video encoder is now selected by preflight as described below.

## 2026-09-17 - Prefer hardware HEVC for Phase 1 segment and chunk encoding
When FFmpeg exposes `hevc_videotoolbox`, Phase 1 uses hardware HEVC Main10 with `p010le` for both compressed segment intermediates and chunk assembly. This removes the multi-gigabyte ProRes scratch path and the software `libx265` bottleneck. A `libx265` path remains available when hardware HEVC is not exposed. All outputs still pass the existing 4K/60 HLG BT.2020/Main10/audio/timing validators; real-media quality, playback, HDR appearance, and peak-space comparison remain owner validation gates. Status: implemented in source; build and owner render validation pending.

## 2026-09-17 - Preserve render-plan duration at segment and chunk boundaries
Phase 1 derives every rendered node, transition, chunk, chapter, and final assembly from the export frame clock. Each block gets an explicit video frame count and matching 48 kHz audio sample count, and completed chunks are reopened and stream-duration validated before their source segments are deleted. This prevents fractional per-segment durations from accumulating into progressive A/V drift and makes a repeated mismatch identify the specific chunk. Status: implemented and covered by focused plus smoke validation.

## 2026-05-03 - Detach renderer subprocesses from terminal stdin
FFmpeg subprocesses are launched with `stdin` detached and `-nostdin` enabled so Assembly Studio renders do not get suspended by terminal job control during CLI or debug runs. This fixes a real observed hang mode during smoke export verification. Status: approved.

## 2026-05-06 - Move render inspectors into separate windows and add live style previews
The main Assembly Studio window now stays focused on controls, compact status, and live previews, while full Sequence and Issues detail lives in dedicated windows reachable from both buttons and the Window menu. This keeps the core workflow compact without hiding important diagnostics. Status: approved.

## 2026-05-06 - Prefer conservative transition audio over leaked handle speech
Answer-to-answer transitions now analyze nearby audio, handle quality, and peak transients; they keep normal crossfades only when the seam looks safe, avoid loudness normalization on short transition slices, reduce gain for quiet-window bridges, and otherwise switch to a muted fallback. Unknown transition modes also fail closed to silence. This was chosen because avoiding stray interviewer/next-question speech and sound bursts is more important than preserving every soft handle crossfade. Status: approved and implemented.

## 2026-05-07 - Keep the HDR MOV master and add a Plex MP4 companion
Phase 1 still renders the approved HDR `MOV` master first, then optionally packages a second Plex-friendly `MP4` companion by remuxing the finished master with TV-style metadata and per-question chapters. This was chosen so Plex support does not redefine or risk the protected master export contract. Status: approved.

## 2026-05-07 - Default Title Case and default-on Plex metadata for sidecar-backed projects
Question title casing is now a display/render treatment stored in the sidecar and defaults on for both new and older projects, while Plex companion export also defaults on and blocks export until its required metadata fields are filled or the feature is turned off. This was chosen to make the new presentation and library behavior explicit in-project instead of hidden in transient UI state. Status: approved.

## 2026-09-16 - Keep the Phase 1 Plex default separate from package-backed Phase 2
The default-on Plex companion decision applies to sidecar-backed Phase 1 projects, whose UI exposes the companion toggle and metadata fields. New package-backed Phase 2 projects default the optional companion off until that workflow exposes equivalent configuration, so an invisible empty companion cannot block the protected master. Existing writable packages are repaired on open only when they contain the exact accidental default state (enabled with every Plex field empty); the repair is idempotent, recorded in migration history, and leaves explicit/non-empty settings as blockers. Status: approved and implemented in the current checkout.

## 2026-09-16 - Treat Phase 2 publication builds as ephemeral derived cache
Package-backed answer clips and manifests are built under the canonical cache only for the duration of lock or final-render consumption. Partial builds are removed on failure or cancellation, successful builds are removed after their consumer finishes, and a cross-process project lease permits pruning stale UUID builds before the next run. Source recordings in ImportStaging remain outside this cleanup boundary. Status: approved and implemented in the current checkout.

## 2026-05-07 - Use temp storage for success-path render work and persist diagnostics only on failure or opt-in
Renderer intermediates now live in an app-scoped system temp folder and are cleaned up on success or cancel, while persistent diagnostics are kept only for failures or when the user explicitly asks to preserve a successful run. Failure diagnostics retain only the render plan and redacted command log; generated media and graphics remain rebuildable temp artifacts and are never copied into Application Support. This was chosen to stop filling Application Support with throwaway work products while keeping useful failure evidence. Status: approved.

## 2026-07-31 - Keep GPL FFmpeg for now while deferring a replacement investigation
Interview Studio will continue using the working GPL-enabled FFmpeg path for the current Phase 1 workflow. Replacing GPL FFmpeg entirely remains a future investigation for licensing, packaging, and distribution reasons, but it is deliberately out of scope while the current renderer remains useful and functional. Status: approved.

## 2026-07-31 - Complete Phase 1 within the assembly-from-manifest scope
Phase 1 is considered complete for its defined product boundary: importing prepared manifest-backed projects, reviewing the deterministic assembly plan, and exporting the locked HDR master plus optional Plex companion. Raw clip creation, manifest authoring, trimming, and timeline work remain future phases rather than unfinished Phase 1 requirements. Status: approved.

## 2026-09-02 - Treat render plans and outputs as inspectable contracts
Render-plan issue identities are deterministic and summary counts are computed from the deduplicated issue set. The renderer now stages master and companion files beside their intended destinations, reopens each staged file, checks the frozen HLG/Main10 profile and duration, and promotes only validated files. A companion failure returns an actionable warning while preserving a validated master. Structural output proof does not replace owner playback or perceptual HDR acceptance. Status: approved.

## 2026-09-02 - Keep package and diagnostics writes transactional and privacy-minimal
Package inventory verification enumerates every visible non-hidden package file, sidecars use atomic writes, migration and CLI publication use owned staging, and subprocess diagnostics omit command arguments, working paths, and environment values. Source media and user-selected final outputs are never overwritten implicitly. Status: approved.

## 2026-09-02 - Use root files for app version identity
VERSION and BUILD_NUMBER are the source-controlled version contract. The packaged app reads the generated bundle values, and script/build_and_run.sh increments BUILD_NUMBER exactly once per packaged app build. Status: approved.

## 2026-09-13 - Add an explicit recording-first workflow for per-age entries
New age entries use an explicit recording-first workflow with Capture, Refine, Assign, and Finish stages. Age is the canonical identity and calendar year is secondary repeatable metadata. Existing sessions without the workflow field continue to use the question-first path, while unknown workflow values open read-only. Status: approved and implemented in the current checkout.

## 2026-09-13 - Treat captured clips as durable candidates before assignment
Recording-first In/Out pairs create permanent source-scoped candidate labels and remain editable, discardable, restorable, and unassigned until approved. A candidate can be assigned to at most one question and a question can have at most one candidate; replacement requires an explicit comparison. Internal cuts remain nondestructive and publication adds safe buffers only at retained outer boundaries. Status: approved and implemented in the current checkout.

## 2026-09-13 - Make recording imports recoverable package transactions
Recording-first imports are copied into package-local staging, journaled with source identity and checksums, verified before atomic promotion, and included in the package inventory only after successful consolidation. Recovery keeps pending work available after interruption and never deletes source media implicitly. Status: approved and implemented in the current checkout.

## 2026-09-13 - Keep age archiving reversible and metadata-only
Archiving removes an age entry from active selection and future renders without deleting recordings, candidates, assignments, or previous publications. Restore returns the same session identity; permanent deletion and archive-management UI remain out of scope for this slice. Status: approved and implemented in the current checkout.
