# Project Philosophy

Read this file when making UX, product, or architecture tradeoffs, proposing significant behavioral changes, evaluating multiple valid approaches, or when broader project philosophy materially affects the decision.

## Product Direction

Personal-use apps optimized for clarity, reliability, low friction, and repeated daily use over novelty or broad-market appeal.

Favor:
- understandable behavior over magic,
- local-first and least-privilege defaults,
- reversible changes over destructive ones,
- explicit tradeoffs over silent fallbacks,
- practical usability over feature count.

Avoid unnecessary complexity, hidden automation, excessive background behavior, and speculative future-proofing.

## UX Philosophy

Favor native platform conventions and predictable interaction patterns.

Prefer:
- focused primary screens,
- low-noise interfaces,
- obvious controls,
- readable layouts,
- visible status/progress,
- graceful degradation,
- and inspectable/recoverable user data.

Support:
- light and dark system appearance,
- basic accessibility,
- keyboard navigation where practical,
- dynamic platform colors rather than hardcoded colors.

Default to English-only unless localization is explicitly requested.

## Platform Preferences

Default stack:
- Swift for Apple-native apps
- Tauri (Rust + WebView) for cross-platform desktop apps

Target current major OS version minus one unless otherwise specified.