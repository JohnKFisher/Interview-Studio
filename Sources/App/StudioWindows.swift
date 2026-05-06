import Core
import SwiftUI

enum StudioWindowID {
    static let sequence = "sequence-window"
    static let issues = "issues-window"
}

struct SequenceWindowView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let renderPlan = appState.renderPlan {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    let boundaries = Dictionary(
                        uniqueKeysWithValues: renderPlan.boundaries.map { ("\($0.fromNodeID)->\($0.toNodeID)", $0) }
                    )
                    ForEach(Array(renderPlan.sequence.enumerated()), id: \.element.id) { index, node in
                        SequenceNodeCard(node: node)
                        if index < renderPlan.sequence.count - 1 {
                            let nextNode = renderPlan.sequence[index + 1]
                            if let boundary = boundaries["\(node.nodeID)->\(nextNode.nodeID)"] {
                                BoundaryCard(boundary: boundary)
                            }
                        }
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("No Sequence Yet", systemImage: "list.number", description: Text("Load a project to inspect the current render order."))
        }
    }
}

struct IssuesWindowView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let renderPlan = appState.renderPlan {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    issuesSection(title: "Blockers", issues: renderPlan.issues.filter { $0.severity == .blocker })
                    issuesSection(title: "Warnings", issues: renderPlan.issues.filter { $0.severity == .warning })
                    issuesSection(title: "Info", issues: renderPlan.issues.filter { $0.severity == .info })
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("No Issues Yet", systemImage: "exclamationmark.bubble", description: Text("Load a project to inspect blockers, warnings, and notes."))
        }
    }

    @ViewBuilder
    private func issuesSection(title: String, issues: [AssemblyIssue]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            if issues.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.code)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(issue.humanMessage)
                        if !issue.suggestedFix.isEmpty {
                            Text(issue.suggestedFix)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

struct StudioWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Open Sequence") {
                openWindow(id: StudioWindowID.sequence)
            }
            Button("Open Issues") {
                openWindow(id: StudioWindowID.issues)
            }
        }
    }
}

private struct SequenceNodeCard: View {
    let node: RenderSequenceNode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(nodeLabel)
                .font(.headline)
            Text(node.type.rawValue.replacingOccurrences(of: "_", with: " "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let timing = node.timing {
                Text(String(format: "Duration %.2fs", Double(timing.durationUS) / 1_000_000))
                    .foregroundStyle(.secondary)
            }
            if let confidence = node.confidence {
                Text("Confidence: \(confidence.level.rawValue.capitalized)")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private var nodeLabel: String {
        node.text?.title ?? node.questionText ?? node.identity?.age ?? node.nodeID
    }
}

private struct BoundaryCard: View {
    let boundary: BoundaryTransition

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transition")
                .font(.subheadline.weight(.semibold))
            Text("\(boundary.resolved.style) via \(boundary.resolved.method)")
                .foregroundStyle(.secondary)
            Text(audioSummary)
                .foregroundStyle(boundary.audio.mode == "silence_gap" ? .orange : .secondary)
            if !boundary.audio.reasons.isEmpty {
                Text(boundary.audio.reasons.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 18)
        .padding(.vertical, 4)
    }

    private var audioSummary: String {
        switch boundary.audio.mode {
        case "full_crossfade":
            return "Audio: full crossfade"
        case "quiet_window_bridge":
            return "Audio: quiet-window bridge"
        case "silence_gap":
            let milliseconds = Double(boundary.audio.silenceGapUS ?? 0) / 1_000
            return String(format: "Audio: silence gap fallback (%.0fms target)", milliseconds)
        default:
            return "Audio: not applicable"
        }
    }
}
