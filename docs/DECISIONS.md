# Decisions

## 2026-05-03 - Publish the project as a GitHub repository
Initial project files are being committed to a new GitHub repository so future work has version history and a shared remote. Status: approved.

## 2026-05-03 - Phase 1 is a SwiftPM-first macOS Assembly Studio
The first implementation pass uses a SwiftPM core library plus a native macOS app target and a CLI target for smoke verification. This keeps manifest parsing, render planning, media inspection, and rendering testable outside the UI. Status: approved.

## 2026-05-03 - Lock Phase 1 exports to one HDR profile
Phase 1 exports are fixed to `3840x2160`, `60 fps`, `HLG`, `BT.2020`, `bt2020nc`, `HEVC Main10`, and `MOV`, with export blocked when required FFmpeg capabilities or HDR safety checks fail. This keeps Phase 1 deterministic and avoids shipping multiple partially-supported output modes. Status: approved.

## 2026-05-03 - Use ProRes intermediates and a final HEVC assembly encode
The renderer now writes 10-bit ProRes intermediate segments and performs the HEVC Main10 encode only once at final assembly time. This was chosen after repeated per-segment x265 renders proved too slow and harder to debug, while preserving the locked final export contract. Status: approved.

## 2026-05-03 - Detach renderer subprocesses from terminal stdin
FFmpeg subprocesses are launched with `stdin` detached and `-nostdin` enabled so Assembly Studio renders do not get suspended by terminal job control during CLI or debug runs. This fixes a real observed hang mode during smoke export verification. Status: approved.

## 2026-05-06 - Move render inspectors into separate windows and add live style previews
The main Assembly Studio window now stays focused on controls, compact status, and live previews, while full Sequence and Issues detail lives in dedicated windows reachable from both buttons and the Window menu. This keeps the core workflow compact without hiding important diagnostics. Status: approved.

## 2026-05-06 - Prefer conservative transition audio over leaked handle speech
Answer-to-answer transitions now analyze nearby audio and handle quality, keep normal crossfades only when the seam looks safe, and otherwise switch to quiet-window bridging or a muted fallback. This was chosen because avoiding stray interviewer/next-question speech is more important than preserving every soft handle crossfade. Status: approved.

## 2026-05-07 - Keep the HDR MOV master and add a Plex MP4 companion
Phase 1 still renders the approved HDR `MOV` master first, then optionally packages a second Plex-friendly `MP4` companion by remuxing the finished master with TV-style metadata and per-question chapters. This was chosen so Plex support does not redefine or risk the protected master export contract. Status: approved.

## 2026-05-07 - Default Title Case and default-on Plex metadata for sidecar-backed projects
Question title casing is now a display/render treatment stored in the sidecar and defaults on for both new and older projects, while Plex companion export also defaults on and blocks export until its required metadata fields are filled or the feature is turned off. This was chosen to make the new presentation and library behavior explicit in-project instead of hidden in transient UI state. Status: approved.

## 2026-05-07 - Use temp storage for success-path render work and persist diagnostics only on failure or opt-in
Renderer intermediates now live in an app-scoped system temp folder and are cleaned up on success or cancel, while persistent diagnostics are kept only for failures or when the user explicitly asks to preserve a successful run. This was chosen to stop filling Application Support with throwaway work products while keeping useful failure evidence. Status: approved.
