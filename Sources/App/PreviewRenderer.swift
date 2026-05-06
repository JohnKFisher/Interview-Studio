import AVFoundation
import AppKit
import Core
import Foundation

struct PreviewFrameModel: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let image: NSImage
}

struct AppPreviewRenderer {
    private let templateRenderer = TemplateRenderer()

    func buildFrames(plan: RenderPlan) -> [PreviewFrameModel] {
        let cardSet = BuiltInTemplates.cardSet(id: plan.settings.selectedCardSetID)
        let overlayStyle = BuiltInTemplates.overlayStyle(id: plan.settings.selectedOverlayStyleID)
        var frames: [PreviewFrameModel] = []

        if let openingNode = plan.sequence.first(where: { $0.type == .openingCard }),
           let image = try? templateRenderer.renderCardNSImage(
                title: openingNode.text?.title ?? "",
                subtitle: openingNode.text?.subtitle ?? "",
                cardSet: cardSet,
                profile: plan.exportProfile,
                isQuestionCard: false
           ) {
            frames.append(
                .init(
                    id: "preview-opening",
                    title: "Opening Card",
                    subtitle: openingNode.text?.title ?? plan.project.projectName,
                    image: image
                )
            )
        }

        if let questionNode = plan.sequence.first(where: { $0.type == .questionCard }),
           let image = try? templateRenderer.renderCardNSImage(
                title: questionNode.text?.title ?? questionNode.questionText ?? "",
                subtitle: questionNode.text?.subtitle ?? "",
                cardSet: cardSet,
                profile: plan.exportProfile,
                isQuestionCard: true
           ) {
            frames.append(
                .init(
                    id: "preview-question",
                    title: "Question Card",
                    subtitle: questionNode.text?.title ?? questionNode.questionText ?? "",
                    image: image
                )
            )
        }

        if let overlayNode = PreviewSelection.riskiestOverlayNode(in: plan),
           let image = try? overlayPreviewImage(node: overlayNode, style: overlayStyle, profile: plan.exportProfile) {
            frames.append(
                .init(
                    id: "preview-overlay",
                    title: "Answer Overlay",
                    subtitle: overlayNode.questionText ?? overlayNode.identity?.age ?? overlayNode.nodeID,
                    image: image
                )
            )
        }

        return frames
    }

    private func overlayPreviewImage(node: RenderSequenceNode, style: OverlayStyle, profile: ExportProfile) throws -> NSImage {
        let baseImage = try baseFrameImage(for: node, profile: profile)
        let ageText = node.overlays.first(where: { $0.type == "age_overlay" })?.text ?? node.identity?.age ?? ""
        let questionText = node.overlays.first(where: { $0.type == "question_overlay" })?.text
        let showQuestion = node.overlays.first(where: { $0.type == "question_overlay" })?.enabled ?? false
        let overlayImage = try templateRenderer.renderOverlayNSImage(
            ageText: ageText,
            questionText: questionText,
            showQuestionText: showQuestion,
            style: style,
            profile: profile
        )

        let canvasSize = NSSize(width: profile.width, height: profile.height)
        let composed = NSImage(size: canvasSize)
        composed.lockFocus()
        defer { composed.unlockFocus() }

        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()
        let fittedRect = aspectFitRect(imageSize: baseImage.size, canvasSize: canvasSize)
        baseImage.draw(in: fittedRect)
        overlayImage.draw(in: NSRect(origin: .zero, size: canvasSize))
        return composed
    }

    private func baseFrameImage(for node: RenderSequenceNode, profile: ExportProfile) throws -> NSImage {
        guard let clipRef = node.clipRef,
              let timing = node.timing else {
            return placeholderImage(profile: profile)
        }

        let asset = AVAsset(url: URL(fileURLWithPath: clipRef.resolvedPath))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let midpointSeconds = max(Double(timing.answerStartInOutputUS + timing.answerEndInOutputUS) / 2_000_000, 0)
        let cgImage = try generator.copyCGImage(at: CMTime(seconds: midpointSeconds, preferredTimescale: 600), actualTime: nil)
        return NSImage(cgImage: cgImage, size: .zero)
    }

    private func placeholderImage(profile: ExportProfile) -> NSImage {
        let size = NSSize(width: profile.width, height: profile.height)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let gradient = NSGradient(colors: [NSColor(calibratedWhite: 0.12, alpha: 1), NSColor(calibratedWhite: 0.22, alpha: 1)])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 315)
        return image
    }

    private func aspectFitRect(imageSize: NSSize, canvasSize: NSSize) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return NSRect(origin: .zero, size: canvasSize)
        }

        let scale = min(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        let fittedSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: (canvasSize.width - fittedSize.width) / 2,
            y: (canvasSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}
