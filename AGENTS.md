Interview Studio — Project Instructions

Follow the global Codex instructions and conditional rules from the active $CODEX_HOME.

Project purpose

Interview Studio is a macOS app for assembling structured yearly-interview clips into polished final movies. The current product centers on loading a prepared final_manifest.json project, reviewing the generated sequence and issues, adjusting presentation settings, and exporting a finished HDR movie.

Core invariants

* final_manifest.json is the authoritative source for clip identity, grouping, ordering, paths, handles, age metadata, and other source facts.
* Assembly must remain deterministic: the same manifest and settings should produce the same render plan.
* Keep editable presentation state separate from stable source identity; for example, changing displayed question text must not mutate question_key.
* The render plan is the explicit, inspectable bridge between project data/settings and rendering. Do not bypass or casually weaken that boundary.
* Block export when media correctness or HDR-safe rendering cannot be established; never silently produce a knowingly incorrect SDR/HDR result.
* Rendering fidelity—especially HDR, color, brightness, cadence, timing, audio boundaries, and transitions—is high-risk. Preserve verified behavior unless a requested change intentionally alters it.
* Do not modify user source media.

Product architecture

* Assembly Studio operates at the interview/question/section level. It is not a general nonlinear timeline editor.
* Scrubbing, trimming, clip creation, and manifest growth belong to the Clip Factory side of the product. Do not force timeline-editor concepts into Assembly Studio or make architectural choices that prevent those capabilities from existing separately.
* Prefer automatic metadata-driven assembly over requiring users to manually arrange individual answer clips.
* Blockers and significant validation problems should remain actionable and machine-readable as well as understandable to the user.

Current technical direction

* The current renderer targets 4K/60fps HLG HDR, HEVC Main10, BT.2020 / bt2020nc, with source-aware normalization rather than metadata-only HDR tagging.
* FFmpeg/FFprobe are currently part of the rendering pipeline; changes to renderer discovery, bundled tools, HDR transforms, transition construction, or final muxing require careful regression validation.
* Preserve the ability to generate both the primary master and the optional Plex-friendly companion output without allowing companion packaging concerns to compromise the master.

Project documentation

Treat current repository plans, schemas, status documents, and HDR/color references as authoritative project context where applicable. In particular, preserve compatibility with the documented manifest and render-plan contracts unless the task explicitly changes those contracts.

If implementation evidence contradicts project documentation, surface the conflict and determine which is stale rather than silently inventing a new contract.