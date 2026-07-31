# HDR Color Reference For Future Video Apps

This document is a practical handoff for building a new app that assembles `4K 60 fps HDR` video from mixed source clips without repeating the color-management mistakes already paid for in Monthly Video Generator.

It mixes two kinds of knowledge:

1. General HDR/video-color lessons that should carry to a new app.
2. App-specific decisions that were validated in this repo and are worth preserving unless a new bakeoff proves otherwise.

This is not a generic HDR tutorial. It is a "what actually bit us, what worked, and what to keep frozen" reference.

## Scope And Target

The working target in this repo is:

- HDR delivery centered on `HLG`
- `BT.2020` primaries
- `BT.2020 non-constant luminance` matrix (`bt2020nc`)
- `HEVC Main10`
- Mixed source inputs:
  - SDR `BT.709` video
  - SDR stills, including old JPEG scans
  - Display P3 stills and HEICs
  - Native HLG video
  - Some PQ/HDR material

The most important design lesson is that a mixed-source HDR exporter is not "one colorspace conversion." It is a source-normalization problem first.

## Core Principles

### 1. Normalize per source type before final assembly

Do not assume one global filter chain is correct for every input. In practice, these classes behaved differently enough that they needed distinct handling:

- Native HLG video
- PQ video
- SDR `BT.709` video
- SDR Display P3 stills
- SDR `BT.709` stills
- HDR stills with gain maps
- Legacy clips with missing or incomplete color tags

The safest architecture is:

1. Inspect each clip's transfer, primaries, and HDR metadata.
2. Normalize that clip into a known intermediate contract.
3. Keep final assembly as close to identity as possible.

For this repo's progressive HDR path, that contract is effectively:

- transfer: `ITU_R_2100_HLG`
- primaries: `ITU_R_2020`
- matrix: `bt2020nc`
- 10-bit HEVC-friendly path

### 2. Metadata alone is not enough

One of the biggest failed assumptions was that explicit HDR metadata on output would be enough. It was not.

What failed:

- tagging output as HDR without a real per-frame re-grade / transform
- relying on advisory output dynamic-range settings
- assuming a colorspace relabel was equivalent to tone mapping

What worked better:

- explicit source-aware transforms
- explicit `zscale` transfer/primaries/matrix handling
- explicit HDR-to-SDR tone mapping when needed
- explicit SDR-to-HLG uplift when targeting HDR output from SDR sources

### 3. Freeze color math after source normalization

This repo reached a hard-won invariant in the progressive HDR pipeline:

- no new color, tone-map, background, or overlay math should be introduced after the established per-source normalization stage

Why this matters:

- later stages are much harder to reason about
- late creative changes can silently break source-specific fixes
- "just one more adjustment" after batching/concat/final packaging is how regressions become impossible to localize

For a new app, establish a clear normalization boundary early and keep it sacred.

### 4. Source-type-specific visual review beats theory

A major lesson from the HDR debugging passes:

- native HLG sources could look fine while SDR sources were badly wrong
- one tweak could fix darkness and then create blowout
- aggregate "looks better" judgment was not enough

The useful workflow was file-by-file review across a mixed sample, separated by source class.

Do not approve HDR color changes from only one or two hero clips.

## What Source Inspection Must Capture

At minimum, inspect and carry forward:

- whether the item is HDR at all
- transfer flavor: `sdr`, `hlg`, or `pq`
- color primaries
- whether primaries are effectively Display P3-like
- HDR metadata flavor, especially:
  - none
  - gain map
  - Dolby Vision fallback case

In this repo, `ColorInfo` is the core contract:

- `isHDR`
- `colorPrimaries`
- `transferFunction`
- `transferFlavor`
- `hdrMetadataFlavor`

Important behavior already encoded here:

- if transfer looks like PQ, treat it as `pq`
- if transfer looks like HLG, or `isHDR` is true, treat it as `hlg`
- if metadata implies HDR, the item must be treated as HDR even if other tags are incomplete
- Display P3 needs to stay distinct from plain `BT.709` SDR

Relevant code:

- [Sources/Core/Models/MediaModels.swift](/Users/jkfisher/Documents/Coding/Monthly%20Video%20Generator/Sources/Core/Models/MediaModels.swift)

## Proven Normalization Rules In This Repo

These are the source-normalization rules that emerged as the least-wrong working set.

### HDR output target

For HDR delivery, the pipeline normalizes toward:

- transfer: `arib-std-b67` (`HLG`)
- primaries: `bt2020`
- matrix: `bt2020nc`

### PQ source to HDR output

PQ sources should not be treated as if they are already HLG. They need an explicit transfer conversion:

```text
zscale=transferin=smpte2084:primariesin=bt2020:matrixin=bt2020nc:
transfer=arib-std-b67:primaries=bt2020:matrix=bt2020nc
```

Lesson:

- PQ-to-HLG is a real transfer conversion, not a metadata swap.

### Native HLG source to HDR output

Native HLG sources largely stay in the same family, but still go through explicit normalization:

```text
zscale=transferin=arib-std-b67:primariesin=bt2020:matrixin=bt2020nc:
transfer=arib-std-b67:primaries=bt2020:matrix=bt2020nc
```

Lesson:

- even "already HLG" clips benefit from explicit normalization into the pipeline contract.

### SDR source to HDR output

This was the hardest part and the most expensive area for regressions.

The current approved path is:

1. Resolve SDR source transfer:
   - `iec61966-2-1` for sRGB-like transfers
   - otherwise `bt709`
2. Resolve SDR source primaries:
   - `smpte432` for Display P3-like inputs
   - otherwise `bt709`
3. For clips with missing/incomplete SDR tags, pre-normalize with:

```text
colorspace=iall=bt709:all=bt709:fast=1
```

4. Convert SDR into linear light.
5. Apply a precomputed luma-lift `3D LUT`.
6. Convert into HLG/BT.2020 with an explicit nominal peak.
7. Apply mild contrast compensation.

Current filter shape:

```text
zscale=transferin=<sdr transfer>:primariesin=<sdr primaries>:matrixin=bt709:transfer=linear,
format=gbrpf32le,
lut3d=file=.../sdr_luma_lift_33.cube:interp=tetrahedral,
zscale=transfer=arib-std-b67:primaries=bt2020:matrix=bt2020nc:range=tv:npl=400,
eq=contrast=1.08
```

Current approved constants:

- `hdrSDRNominalPeak = 400`
- `hdrSDRContrastCompensation = 1.08`

Critical history:

- an earlier `npl=225` branch made SDR sources land too dark
- restoring `npl=1000` fixed darkness but blew out highlights
- especially old scanned JPEGs exposed the blowout problem clearly
- `npl=400` landed as the better compromise: HDR uplift without clipping highlights

Takeaway:

- SDR-to-HDR uplift is where "technically plausible" settings most often fail visually
- nominal peak is not a cosmetic knob; it materially changes perceived white and highlight headroom

### HDR source to SDR output

This is a separate path and must not be collapsed into a simple colorspace remap.

For PQ to SDR:

```text
zscale=transferin=smpte2084:primariesin=bt2020:matrixin=bt2020nc:transfer=linear,
format=gbrpf32le,
tonemap=mobius:desat=2,
zscale=transfer=bt709:primaries=bt709:matrix=bt709
```

For HLG to SDR:

```text
zscale=transferin=arib-std-b67:primariesin=bt2020:matrixin=bt2020nc:transfer=linear:npl=1400,
format=gbrpf32le,
zscale=primaries=bt709,
tonemap=mobius:desat=2,
zscale=transfer=bt709:matrix=bt709:range=tv
```

Current approved constant:

- `hlgSDRNominalPeak = 1400`

Lesson:

- HLG-to-SDR needed an explicit nominal peak and gamut reduction before tone mapping
- without that, iPhone HLG clips stayed visibly blown out in SDR output

Relevant code:

- [Sources/Core/Render/FFmpeg/FFmpegCommandBuilder.swift](/Users/jkfisher/Documents/Coding/Monthly%20Video%20Generator/Sources/Core/Render/FFmpeg/FFmpegCommandBuilder.swift)

## Display P3 Is Not "Basically BT.709"

Do not flatten Display P3 into generic SDR just because it is not HDR.

What mattered here:

- Display P3 stills needed transfer-aware handling
- Display P3 should flow through `primariesin=smpte432`
- treating P3 like plain `bt709` can shift color and reduce fidelity before HDR uplift

Practical rule:

- keep transfer and primaries as separate decisions
- SDR is not a single thing

## Gain-Map HDR Stills Need Special Handling

HDR stills were another place where naive handling failed.

Important lessons:

- gain-map-aware decoding matters
- source-image orientation must also be applied to the auxiliary gain map
- otherwise some photos produce rotated ghost-image overlays or other visibly wrong HDR results

For future apps:

- do not assume "still image decoded successfully" means HDR stills were decoded correctly
- HDR still support needs explicit validation beyond generic image decoding

Relevant code:

- [Sources/Core/Render/StillImageClipFactory.swift](/Users/jkfisher/Documents/Coding/Monthly%20Video%20Generator/Sources/Core/Render/StillImageClipFactory.swift)

## Missing Or Bad Source Tags Are Common

Some legacy camera/video clips arrived with missing AVFoundation color tags even though FFmpeg still exposed unknown or legacy stream characteristics.

What worked:

- for SDR clips with missing/incomplete tags, inject a `BT.709` prelude before later `zscale` work:

```text
colorspace=iall=bt709:all=bt709:fast=1
```

Why:

- this gave the later normalization step a valid source colorspace path
- it prevented `zscale` failures like "no path between colorspaces"

Takeaway:

- real libraries contain incomplete metadata
- the pipeline should fail clearly on impossible cases, but it should also have a narrow, explicit strategy for common legacy-tag gaps

## Output Metadata Still Matters

Metadata alone is not enough, but it still matters.

For final output, the app now writes explicit output color metadata based on dynamic range:

- SDR output: `BT.709`
- HDR output: `BT.2020 HLG`

This matters because:

- players rely on it
- media analyzers rely on it
- debugging becomes much harder when the actual transform and the declared metadata drift apart

Practical rule:

- color transforms and output signaling must agree

## FFmpeg Capability Requirements Matter

The pipeline depends on more than "some ffmpeg binary exists."

Required capabilities vary by path, but the important ones here are:

- `zscale`
- `tonemap` for HDR-to-SDR paths
- `xfade`
- `acrossfade`
- `overlay` where media-derived backgrounds are used
- a suitable encoder:
  - `libx265` for final HDR delivery in the approved default path
  - `hevc_videotoolbox` only in narrower cases

This repo learned to treat FFmpeg availability as a packaging and preflight problem, not just a runtime surprise.

Practical rules:

- pin versions
- verify filters/codecs before starting expensive renders
- fail early if a required capability is missing
- do not silently swap to a different backend unless that fallback is explicitly approved

Relevant code:

- [Sources/Core/Render/FFmpeg/FFmpegTypes.swift](/Users/jkfisher/Documents/Coding/Monthly%20Video%20Generator/Sources/Core/Render/FFmpeg/FFmpegTypes.swift)

## What Actually Went Wrong Historically

These are the failures most worth remembering.

### Failure: Metadata-only HDR thinking

Symptom:

- output was tagged as HDR but did not actually render correctly

Lesson:

- explicit per-source transforms beat advisory HDR signaling

### Failure: One-size-fits-all SDR uplift

Symptom:

- some fixes helped HLG but broke SDR
- some fixes brightened SDR but then blew out highlights

Lesson:

- review old JPEGs, SDR video, Display P3 stills, and native HLG separately

### Failure: `npl=1000` on SDR-to-HLG uplift

Symptom:

- SDR white landed around HDR-bright, causing obvious blowout
- older scanned images were especially bad

Lesson:

- very high nominal peak can make SDR uplift look impressive at first glance while actually being wrong

### Failure: treating HLG-to-SDR as a simple remap

Symptom:

- iPhone HDR highlights stayed blown out in SDR exports

Lesson:

- HLG-to-SDR needed explicit nominal-peak handling plus tone mapping

### Failure: missing source tags breaking `zscale`

Symptom:

- immediate colorspace-path failures on legacy clips

Lesson:

- a narrow BT.709 prelude for missing SDR tags is much safer than pretending bad metadata does not exist

### Failure: gain-map still orientation mismatch

Symptom:

- rotated or ghosted HDR still artifacts

Lesson:

- auxiliary HDR metadata must follow the source image's orientation too

## Recommendations For A New App

If building a fresh `4K60 HDR` assembler, I would start with these rules:

1. Choose one HDR delivery contract and normalize everything into it.
   - For compatibility with what worked here, `HLG + BT.2020 + bt2020nc + Main10 HEVC` is a reasonable default.

2. Build source inspection as a first-class model, not an afterthought.
   - Transfer, primaries, HDR metadata flavor, frame rate, orientation, and source type should all be explicit.

3. Separate these code paths clearly:
   - PQ -> HDR target
   - HLG -> HDR target
   - SDR BT.709 -> HDR target
   - SDR Display P3 -> HDR target
   - HDR -> SDR fallback/export
   - HDR stills with gain maps

4. Keep normalization early and final packaging late.
   - No creative or corrective color math after normalization.

5. Use a mixed validation corpus every time color math changes.
   - Old scans
   - Modern JPEGs
   - Display P3 HEICs
   - SDR MOVs
   - Native iPhone HLG clips
   - Any PQ sample you care about

6. Review file-by-file before and after.
   - Do not approve color changes only from one montage or one summary render.

7. Preflight your ffmpeg toolchain like a dependency, not a convenience.
   - Verify filters, encoder, and packaging presence before render start.

8. Make output metadata explicit and aligned with the real transform.

9. Treat nominal peak values as calibrated choices.
   - They should be documented, testable, and changed only with visual evidence.

10. Be suspicious of solutions that are "simpler" because they remove source distinctions.
   - Those are often the exact changes that reintroduce regressions.

## Suggested Starting Defaults For A Successor App

If the new app has a similar target as this one, these are the most defensible starting assumptions:

- HDR delivery format: `HEVC Main10`
- HDR transfer: `HLG`
- HDR primaries: `BT.2020`
- HDR matrix: `bt2020nc`
- Native HLG sources: preserve family, normalize explicitly
- PQ sources: explicit PQ-to-HLG conversion
- SDR sources headed to HDR:
  - keep P3 distinct from BT.709
  - use explicit SDR-to-linear conversion
  - use a tested uplift path, not just a gain multiplier
  - start from the proven `npl=400` family rather than `1000`
- HDR-to-SDR fallback:
  - explicit tone mapping
  - separate HLG and PQ branches

These should still be treated as starting defaults, not universal laws.

## Where To Look In This Repo

- [docs/DECISIONS.md](/Users/jkfisher/Documents/Coding/Monthly%20Video%20Generator/docs/DECISIONS.md)
- [docs/WHERE_WE_STAND.md](/Users/jkfisher/Documents/Coding/Monthly%20Video%20Generator/docs/WHERE_WE_STAND.md)
- [Sources/Core/Models/MediaModels.swift](/Users/jkfisher/Documents/Coding/Monthly%20Video%20Generator/Sources/Core/Models/MediaModels.swift)
- [Sources/Core/Render/FFmpeg/FFmpegCommandBuilder.swift](/Users/jkfisher/Documents/Coding/Monthly%20Video%20Generator/Sources/Core/Render/FFmpeg/FFmpegCommandBuilder.swift)
- [Sources/Core/Render/FFmpeg/FFmpegTypes.swift](/Users/jkfisher/Documents/Coding/Monthly%20Video%20Generator/Sources/Core/Render/FFmpeg/FFmpegTypes.swift)
- [Sources/Core/Render/FFmpeg/FFmpegProgressivePipeline.swift](/Users/jkfisher/Documents/Coding/Monthly%20Video%20Generator/Sources/Core/Render/FFmpeg/FFmpegProgressivePipeline.swift)
- [Sources/Core/Render/StillImageClipFactory.swift](/Users/jkfisher/Documents/Coding/Monthly%20Video%20Generator/Sources/Core/Render/StillImageClipFactory.swift)

## Bottom Line

The most valuable lesson is not a single filter string. It is this:

- mixed-source HDR export succeeds when the pipeline respects source differences early, declares a single target contract clearly, and stops changing color math after normalization

The most dangerous mistake is this:

- treating HDR as metadata decoration on top of a mostly-SDR pipeline

And the most specific setting worth carrying forward from this repo is this:

- for SDR-to-HLG uplift in this family of outputs, `npl=400` was the hard-won correction after both "too dark" and "blown out" failures
