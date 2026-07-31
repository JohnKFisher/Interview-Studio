# Graph Report - .  (2026-07-30)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 580 nodes · 1593 edges · 16 communities (14 shown, 2 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 109 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `61de1b55`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Community 0
- Community 1
- Community 2
- Community 3
- Community 4
- Community 5
- Community 6
- Community 7
- Community 8
- Community 9
- Community 10
- Community 11
- Community 12
- Community 13
- Community 14
- Community 15

## God Nodes (most connected - your core abstractions)
1. `CodingKeys` - 59 edges
2. `AppState` - 51 edges
3. `RenderSequenceNode` - 42 edges
4. `RenderPlan` - 36 edges
5. `Renderer` - 34 edges
6. `AssemblyIssue` - 30 edges
7. `ExportProfile` - 28 edges
8. `BoundaryTransition` - 27 edges
9. `ProjectDocument` - 25 edges
10. `Foundation` - 23 edges

## Surprising Connections (you probably didn't know these)
- `drawIcon()` --calls--> `NSColor`  [INFERRED]
  script/generate_app_icon.swift → Sources/Core/Templates/TemplateRenderer.swift
- `AppState` --calls--> `AppPreviewRenderer`  [INFERRED]
  Sources/App/AppState.swift → Sources/App/PreviewRenderer.swift
- `AppState` --calls--> `QuestionGroupBuilder`  [INFERRED]
  Sources/App/AppState.swift → Sources/Core/Project/QuestionGroupBuilder.swift
- `AppState` --calls--> `Renderer`  [INFERRED]
  Sources/App/AppState.swift → Sources/Core/Rendering/Renderer.swift
- `AppState` --calls--> `RenderPlanBuilder`  [INFERRED]
  Sources/App/AppState.swift → Sources/Core/RenderPlan/RenderPlanBuilder.swift

## Import Cycles
- None detected.

## Communities (16 total, 2 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.08
Nodes (67): CaseIterable, Codable, Hashable, Identifiable, Sendable, Entry, ManifestParserConfidence, high (+59 more)

### Community 1 - "Community 1"
Cohesion: 0.06
Nodes (32): App, Commands, Never, Notification, NSApplicationDelegate, NSObject, ObservableObject, Scene (+24 more)

### Community 2 - "Community 2"
Cohesion: 0.06
Nodes (35): ManifestPathResolution, ManifestPathResolver, URL, LoadedManifestProject, QuestionGroup, ResolvedManifestClip, Bool, Int (+27 more)

### Community 3 - "Community 3"
Cohesion: 0.04
Nodes (57): CodingKeys, actualHandleAfterUS, actualHandleBeforeUS, age, ageKey, ageRawText, ageSortKey, ageYears (+49 more)

### Community 4 - "Community 4"
Cohesion: 0.13
Nodes (21): FFmpegBinarySet, FFmpegLocator, URL, DateFormatter, format(), JSONEncoder, Renderer, RendererError (+13 more)

### Community 5 - "Community 5"
Cohesion: 0.13
Nodes (21): CGRect, CGSize, NSBitmapImageRep, NSFont, BuiltInTemplates, CardSet, OverlayStyle, String (+13 more)

### Community 6 - "Community 6"
Cohesion: 0.09
Nodes (21): AppKit, AVFoundation, Float, Foundation, drawIcon(), pngData(), CGFloat, Data (+13 more)

### Community 7 - "Community 7"
Cohesion: 0.08
Nodes (27): CodingKey, CodingKeys, channels, codecType, colorPrimaries, colorSpace, colorTransfer, height (+19 more)

### Community 8 - "Community 8"
Cohesion: 0.10
Nodes (20): Int32, LocalizedError, ManifestParser, ManifestParserError, invalidJSON, noUsableClips, topLevelNotArray, String (+12 more)

### Community 9 - "Community 9"
Cohesion: 0.13
Nodes (13): Core, YearlyInterviewStudioCLI, QuestionGroupBuilder, ManifestAndRenderPlanTests, RendererTests, AudioProfile, quietHandles, speechyHandles (+5 more)

### Community 10 - "Community 10"
Cohesion: 0.16
Nodes (17): Decodable, ColorInfo, FFmpegCapabilities, FFmpegPreflight, FFmpegPreflightResult, FFprobeEnvelope, Format, MediaInspectionResult (+9 more)

### Community 11 - "Community 11"
Cohesion: 0.18
Nodes (12): Equatable, AppPreviewRenderer, PreviewDescriptor, PreviewFrameModel, PreviewFrameStatus, failed, loading, ready (+4 more)

### Community 12 - "Community 12"
Cohesion: 0.24
Nodes (7): Key, KeyedDecodingContainer, Bool, Double, Int, Int64, String

### Community 13 - "Community 13"
Cohesion: 0.56
Nodes (4): Set, Bool, String, TitleCaseFormatter

## Knowledge Gaps
- **112 isolated node(s):** `PackageDescription`, `AppPreferenceKey`, `loading`, `ready`, `failed` (+107 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `CodingKeys` connect `Community 3` to `Community 0`, `Community 7`?**
  _High betweenness centrality (0.185) - this node is a cross-community bridge._
- **Why does `Foundation` connect `Community 6` to `Community 0`, `Community 2`, `Community 4`, `Community 5`, `Community 7`, `Community 8`, `Community 9`, `Community 10`, `Community 12`?**
  _High betweenness centrality (0.155) - this node is a cross-community bridge._
- **Why does `AppState` connect `Community 1` to `Community 0`, `Community 2`, `Community 4`, `Community 6`, `Community 9`, `Community 11`?**
  _High betweenness centrality (0.149) - this node is a cross-community bridge._
- **Are the 5 inferred relationships involving `AppState` (e.g. with `AppPreviewRenderer` and `QuestionGroupBuilder`) actually correct?**
  _`AppState` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `AppPreferenceKey`, `loading` to the rest of the system?**
  _112 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.0849007314524556 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.06015037593984962 - nodes in this community are weakly interconnected._