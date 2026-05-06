import Foundation

public enum PreviewSelection {
    public static func riskiestOverlayNode(in plan: RenderPlan) -> RenderSequenceNode? {
        plan.sequence
            .filter { $0.type == .answerClip }
            .max(by: { score(for: $0) < score(for: $1) })
    }

    private static func score(for node: RenderSequenceNode) -> Int {
        let questionLength = node.questionText?.count ?? 0
        let warningCount = node.issues.count
        return questionLength * 100 + warningCount
    }
}
