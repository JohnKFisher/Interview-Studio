# Interview Studio

Interview Studio is a macOS app in active development for organizing interview source media, publishing validated answer clips, and assembling interview video into a finished file.

The root `VERSION` and `BUILD_NUMBER` files are the authoritative app identity for the current checkout. The build number is expected to change as new builds are made.

The stable product boundary remains the assembly/export phase: import a project folder that contains `final_manifest.json`, review the generated sequence and issues, tweak a few presentation details, then export a real `3840x2160` / `60 fps` / HLG master movie. A Phase 2 prototype also imports source recordings into a package, reviews answer ranges, and publishes native answer clips and manifests, but that workflow is still under active verification.

## Project Status

Phase 1 Assembly Studio is complete for its defined assembly-from-manifest scope. Phase 2 is now an active, incomplete prototype rather than a proposed-only plan; it is not release-ready until real-media round trips and the remaining workflow checks pass. The current checklist is in [docs/PHASE_2_PLAN.md](docs/PHASE_2_PLAN.md).

Built primarily for my own workflow, but possibly useful if you also have a manifest-driven interview pipeline and want a Mac-native finishing tool instead of stitching everything together by hand.

The current app has two distinct lanes: a protected Phase 1 assembly lane for prepared projects and an in-progress Phase 2 source-media/answer-publication lane.

Right now this should be read as an in-progress app repo, not a finished product.

GitHub Releases now provide a signed and notarized developer-preview path, while the repo remains source-first until the Phase 2 and self-contained FFmpeg distribution gates are closed.

## What It Does

- Loads an interview project folder using `final_manifest.json`
- Persists app-specific edits in `yearly_interview_studio_project.json`
- Builds a deterministic render plan with cards, answer clips, overlays, and transitions
- Shows live previews plus dedicated Sequence and Issues windows
- Renders a real HDR `MOV` master using FFmpeg
- Optionally remuxes a Plex-friendly `MP4` companion with metadata and chapters
- Phase 2 prototype: imports local source recordings, stores package metadata, reviews answer markers, and publishes native answer clips

## What It Does Not Do Yet

The Phase 1 assembly lane still assumes the clips and manifest already exist.

Phase 2 can now ingest recordings and generate a new package-backed manifest, but its workflow remains incomplete: multipart answers, full boundary QA, cancellation/retry UX, incremental manifest editing, and a real-media round trip still require validation.

The Phase 2 implementation status is tracked in [docs/PHASE_2_PLAN.md](docs/PHASE_2_PLAN.md) and [docs/WHERE_WE_STAND.md](docs/WHERE_WE_STAND.md).

Phase 1 is intentionally narrow; these are boundaries of the completed phase and the broader product:

- one person per project
- one locked export profile
- no timeline editor yet
- no clip trimming or player-style QA workflow yet

## Workflow Shape

The Phase 1 assembly lane sits on top of an existing clip/manifest generation pipeline. The Phase 2 prototype now covers part of the source-media side while it is being validated.

The rough shape is:

1. Generate a project folder that contains `final_manifest.json` and the referenced media.
2. Open that folder in Interview Studio.
3. Review question grouping, issue surfacing, previews, overlays, and output settings.
4. Export the HDR master movie.
5. Optionally keep the Plex companion output if you want a library-friendly copy.

The remaining Phase 2 work is tracked separately and is not yet a release-ready replacement for the prepared-project workflow.

The app keeps its own sidecar state in `yearly_interview_studio_project.json` so presentation edits and metadata do not have to mutate the source manifest.

## Current Strengths

- Deterministic Phase 1 export contract: `3840x2160`, `60 fps`, `HEVC Main10`, `BT.2020`, `bt2020nc`, `HLG`, `MOV`
- Conservative HDR handling that blocks export instead of silently falling back to SDR
- Deterministic output-frame/audio-sample timing checks that reject gross stream-duration drift
- Sidecar-backed question text edits, ordering, Title Case preference, and Plex metadata
- Safer answer-to-answer audio transitions that prefer clean seams over stray speech leakage
- A real macOS app plus a CLI smoke-test path built from the same shared core

## Current Limits

- macOS only
- single-person projects only
- Phase 1 requires an already-prepared manifest-backed project folder
- export can be slow on CPU-heavy systems, especially for card generation and SDR-to-HLG conversion
- FFmpeg / FFprobe availability still matters
- the Plex metadata path is intentionally simple and can block export until required fields are filled in or disabled

For the fuller current-state view, see [docs/WHERE_WE_STAND.md](docs/WHERE_WE_STAND.md).

## Building And Running

Requirements:

- macOS 26 or newer
- Swift toolchain compatible with `swift-tools-version: 6.2`
- a compatible `ffmpeg`/`ffprobe` pair with `zscale`, `xfade`, `acrossfade`, `overlay`, and `libx265`; the app checks the bundled tools and other installed candidates until it finds a capable pair

Build the app bundle:

```bash
./script/build_and_run.sh build
```

This local development build writes `YearlyInterviewStudio-package-<build>` under the system temporary directory outside the checkout, increments `BUILD_NUMBER` once before the build, and applies an ad hoc signature. Set `OUTPUT_DIR` explicitly if you need another staging location; a FileProvider-synced checkout is not a safe signing location.

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
- `script/package_release.sh` - release-only signed/notarized packaging helper
- `.github/workflows/release.yml` - tag-triggered GitHub release build
- `docs/WHERE_WE_STAND.md` - plain-language current state
- `docs/PHASE_2_PLAN.md` - current Clip Factory plan and checklist
- `docs/DECISIONS.md` - decision log for durable project choices

## Notes On Packaging

The packaged `.app` reads source-controlled version values from the root `VERSION` and `BUILD_NUMBER` files. Local `script/build_and_run.sh` builds use the next build number and normally copy a complete host `ffmpeg` / `ffprobe` pair when both tools are present. It writes tool provenance into the bundle and carries [ATTRIBUTIONS.md](ATTRIBUTIONS.md). The local signature is ad hoc; ad hoc signing is not distribution signing.

`script/package_release.sh` remains an optional distribution-signing path. It builds with SwiftPM's release configuration under a temporary directory, preserves the checked-in build number, refuses ad hoc signing, applies a Developer ID Application signature with the hardened runtime and secure timestamp, verifies the signature, submits a ZIP to Apple's notary service, staples the returned ticket to the app, validates it, and creates a final ZIP. The normal GitHub CI path does not require this script or any signing secrets.

The GitHub CI workflow installs a compatible Homebrew `ffmpeg` / `ffprobe` pair on the arm64 `macos-26` runner, bundles both tools into the app, records their provenance, and verifies the resulting ZIP. The app therefore has the tools it needs when launched from that CI artifact. Local builds also use a complete host pair when one is available and otherwise fall back to runtime discovery. FFmpeg redistribution, corresponding-source obligations, and codec/patent review remain open considerations before broad public distribution.

The GitHub artifact is ad hoc signed but not Developer ID signed or notarized. It is a prerelease/developer preview, not a claim that the Phase 2 workflow or real-media owner acceptance is complete.

## GitHub Releases

The CI workflow runs on pushes, pull requests, and manual dispatch. It uploads a release-configuration app ZIP as a short-lived GitHub Actions artifact. To additionally publish that artifact as an unsigned GitHub prerelease, make sure the tag commit contains the intended `BUILD_NUMBER`, then push a matching tag:

```bash
git tag "v$(tr -d '[:space:]' < VERSION)"
git push origin "v$(tr -d '[:space:]' < VERSION)"
```

The workflow rejects a tag whose version does not exactly match `VERSION`, refuses to overwrite an existing release, and publishes a GitHub prerelease with generated notes. It does not edit or commit `VERSION` or `BUILD_NUMBER`; reserve the intended build number in the release-preparation commit before tagging. No GitHub or Apple signing secrets are required for this CI path.

The optional signed path still requires a Developer ID certificate and Apple notarization credentials. If that path is enabled later, create a protected GitHub environment named `release` and add these environment secrets:

- `DEVELOPER_ID_APPLICATION_P12_BASE64` — base64 of a `.p12` containing the Developer ID Application certificate and its private key
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD` — password protecting that `.p12`
- `APPLE_NOTARY_KEY_P8_BASE64` — base64 of the App Store Connect API key `.p8`
- `APPLE_NOTARY_KEY_ID` — the API key ID
- `APPLE_NOTARY_ISSUER_ID` — the issuer UUID

The workflow imports the certificate into a temporary keychain, derives the Developer ID Application identity, signs inside-out with the hardened runtime, and deletes temporary signing material after the job. It uses the repository `GITHUB_TOKEN` only for release publication; no GitHub personal access token is required. Protecting the `release` environment with required reviewers is recommended.

The certificate must be a Developer ID Application certificate for distribution outside the Mac App Store, not a Mac App Distribution or development certificate. The notarization key must be authorized for the notary service. Apple documents the [Developer ID signing requirements](https://developer.apple.com/developer-id/) and the [custom `notarytool` workflow](https://developer.apple.com/documentation/Security/customizing-the-notarization-workflow); GitHub documents [workflow permissions and release access](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).

The release workflow currently produces a signed and notarized ZIP, but it does not make the app self-contained until the FFmpeg distribution decision is resolved. This limitation is deliberate and should be closed before calling a release a turnkey install for other users.

## AI Assistance

Like most of my recent projects, this one is built with heavy AI assistance using tools like Codex and Claude.

The workflow choices, guardrails, testing expectations, and project direction are still mine. The typing speed definitely is not.
