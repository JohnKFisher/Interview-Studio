import Foundation

public struct TransitionPlanner {
    private let audioAnalyzer = AudioBoundaryAnalyzer()

    public init() {}

    public func planAnswerBoundary(
        from fromNode: RenderSequenceNode,
        fromClip: ResolvedManifestClip,
        to toNode: RenderSequenceNode,
        toClip: ResolvedManifestClip,
        settings: RenderSettings,
        frameRate: Double
    ) -> BoundaryTransition {
        let requestedFrames = max(0, settings.answerTransition.durationFrames)
        let durationUS = framesToMicroseconds(requestedFrames, frameRate: frameRate)
        let outgoingReal = fromClip.row.actualHandleAfterUS
        let incomingReal = toClip.row.actualHandleBeforeUS
        let outgoingVisible = fromClip.row.actualHandleAfterUS + fromClip.row.syntheticHandleAfterUS
        let incomingVisible = toClip.row.totalVisibleLeadingUS
        let canGenerateSynthetic = !fromClip.row.isHDRLike && !toClip.row.isHDRLike

        let requested = BoundaryTransition.Requested(style: settings.answerTransition.style, durationFrames: requestedFrames, durationUS: durationUS)
        let requirements = BoundaryTransition.Requirements(
            outgoingHandleAfterRequiredUS: durationUS,
            incomingHandleBeforeRequiredUS: durationUS
        )
        let availability = BoundaryTransition.Availability(
            outgoingRealHandleAfterUS: outgoingReal,
            incomingRealHandleBeforeUS: incomingReal,
            outgoingSyntheticAvailable: outgoingVisible >= durationUS || canGenerateSynthetic,
            incomingSyntheticAvailable: incomingVisible >= durationUS || canGenerateSynthetic
        )
        let audioPlan = audioAnalyzer.analyze(
            from: fromClip,
            to: toClip,
            requestedDurationUS: durationUS
        )

        var resolved = BoundaryTransition.Resolved(style: "clean_cut", durationFrames: 0, method: "fallback_clean_cut", fallbackUsed: requestedFrames > 0)
        var issues: [AssemblyIssue] = []

        if requestedFrames == 0 {
            resolved = .init(style: "clean_cut", durationFrames: 0, method: "requested_cut", fallbackUsed: false)
        } else if outgoingReal >= durationUS && incomingReal >= durationUS {
            resolved = .init(style: "soft_crossfade", durationFrames: requestedFrames, method: "real_handles", fallbackUsed: false)
        } else if outgoingVisible >= durationUS && incomingVisible >= durationUS {
            resolved = .init(style: "soft_crossfade", durationFrames: requestedFrames, method: "synthetic_handles", fallbackUsed: false)
            issues.append(
                AssemblyIssue(
                    severity: .warning,
                    code: "TRANSITION_USING_SYNTHETIC_PADDING",
                    humanMessage: "This answer boundary will use synthetic or previously padded handle material to preserve the requested crossfade.",
                    aiContext: [
                        "from_node_id": .string(fromNode.nodeID),
                        "to_node_id": .string(toNode.nodeID),
                        "requested_duration_frames": .number(Double(requestedFrames))
                    ],
                    suggestedFix: "If you want only real handle material here, regenerate one or both source clips with more real handle."
                )
            )
        } else if canGenerateSynthetic {
            resolved = .init(style: "soft_crossfade", durationFrames: requestedFrames, method: "synthetic_generated", fallbackUsed: false)
            issues.append(
                AssemblyIssue(
                    severity: .warning,
                    code: "TRANSITION_SYNTHETIC_GENERATED",
                    humanMessage: "This answer boundary will generate conservative synthetic padding so the requested crossfade can be preserved.",
                    aiContext: [
                        "from_node_id": .string(fromNode.nodeID),
                        "to_node_id": .string(toNode.nodeID),
                        "requested_duration_frames": .number(Double(requestedFrames))
                    ],
                    suggestedFix: "Regenerate source clips with more real handle if you want to avoid synthetic transition padding."
                )
            )
        } else {
            issues.append(
                AssemblyIssue(
                    severity: .warning,
                    code: "TRANSITION_FALLBACK_CLEAN_CUT",
                    humanMessage: "Soft crossfade was requested, but this boundary will use a clean cut because safe handle padding is not available.",
                    aiContext: [
                        "from_node_id": .string(fromNode.nodeID),
                        "to_node_id": .string(toNode.nodeID),
                        "requested_duration_frames": .number(Double(requestedFrames))
                    ],
                    suggestedFix: "Regenerate one or both clips with more handle or accept the clean cut fallback."
                )
            )
        }

        if audioPlan.mode == "quiet_window_bridge" {
            issues.append(
                AssemblyIssue(
                    severity: .info,
                    code: "TRANSITION_AUDIO_QUIET_WINDOW",
                    humanMessage: "This answer boundary will use quiet transition audio slices instead of full handle audio to avoid leaked speech.",
                    aiContext: [
                        "from_node_id": .string(fromNode.nodeID),
                        "to_node_id": .string(toNode.nodeID)
                    ],
                    suggestedFix: "If you want fuller transition audio here, regenerate clips with cleaner real handle room tone."
                )
            )
        } else if audioPlan.mode == "silence_gap" {
            issues.append(
                AssemblyIssue(
                    severity: .warning,
                    code: "TRANSITION_AUDIO_SILENCE_GAP",
                    humanMessage: "This answer boundary will mute transition audio rather than risk leaking stray speech from the handles.",
                    aiContext: [
                        "from_node_id": .string(fromNode.nodeID),
                        "to_node_id": .string(toNode.nodeID),
                        "silence_gap_us": .number(Double(audioPlan.silenceGapUS ?? 0))
                    ],
                    suggestedFix: "Cleaner real handles would allow a softer audio handoff here."
                )
            )
        }

        return BoundaryTransition(
            boundaryID: "boundary-\(fromNode.nodeID)-to-\(toNode.nodeID)",
            fromNodeID: fromNode.nodeID,
            toNodeID: toNode.nodeID,
            boundaryType: "answer_to_answer",
            requested: requested,
            resolved: resolved,
            requirements: requirements,
            availability: availability,
            audio: audioPlan,
            issues: issues
        )
    }

    public func planStructuralBoundary(
        from fromNode: RenderSequenceNode,
        to toNode: RenderSequenceNode,
        style: String,
        durationFrames: Int,
        frameRate: Double,
        boundaryType: String
    ) -> BoundaryTransition {
        let durationUS = framesToMicroseconds(durationFrames, frameRate: frameRate)
        return BoundaryTransition(
            boundaryID: "boundary-\(fromNode.nodeID)-to-\(toNode.nodeID)",
            fromNodeID: fromNode.nodeID,
            toNodeID: toNode.nodeID,
            boundaryType: boundaryType,
            requested: .init(style: style, durationFrames: durationFrames, durationUS: durationUS),
            resolved: .init(style: style, durationFrames: durationFrames, method: style == "cut" ? "direct" : "card_fade", fallbackUsed: false),
            requirements: .init(outgoingHandleAfterRequiredUS: 0, incomingHandleBeforeRequiredUS: 0),
            availability: .init(outgoingRealHandleAfterUS: 0, incomingRealHandleBeforeUS: 0, outgoingSyntheticAvailable: false, incomingSyntheticAvailable: false),
            audio: .notApplicable,
            issues: []
        )
    }

    private func framesToMicroseconds(_ frames: Int, frameRate: Double) -> Int64 {
        Int64((Double(frames) / frameRate * 1_000_000).rounded())
    }
}
