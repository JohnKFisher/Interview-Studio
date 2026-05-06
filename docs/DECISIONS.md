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
