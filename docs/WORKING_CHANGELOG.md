# Working Changelog

Internal notes for building public-facing changelogs. Keep entries understandable to non-technical users, but not fully polished.

## Unreleased

### Added

- [needs review] Phase 2 prototype support for importing local source recordings, reviewing answer markers, and storing optional on-device transcripts.
- [needs review] A native answer-publication path that writes a package-backed manifest and derived answer clips.

### Changed

- [needs review] Current status documents now distinguish the protected Phase 1 assembly lane from the incomplete Phase 2 prototype.
- Manifest fallback paths are constrained to the selected project folder, including symlink-aware containment checks.

### Fixed

- Existing native answer outputs and FFmpeg render outputs are no longer silently overwritten.
- Generated Phase 2 answer names sanitize project identifiers before constructing output paths.

### Reliability / Data Safety

- Native answer publication now reopens generated media and validates readability, tracks, dimensions, frame rate, and duration before recording manifest output metadata.

### Internal / Maintenance

- Local app bundles carry FFmpeg/FFprobe attribution and version/hash provenance when a complete host pair is copied.
