import AVFoundation
import AppKit
import Core
import Foundation

enum PreviewFrameStatus: Equatable {
    case loading
    case ready
    case failed(String)
}

struct PreviewFrameModel: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let image: NSImage
    let status: PreviewFrameStatus
}

struct AppPreviewRenderer: Sendable {
    private let templateRenderer = TemplateRenderer()

    func seededFrames(for plan: RenderPlan, existing: [PreviewFrameModel]) -> [PreviewFrameModel] {
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        return descriptors(for: plan).map { descriptor in
            let preservedImage = existingByID[descriptor.id]?.image ?? placeholderImage(profile: plan.exportProfile)
            return PreviewFrameModel(
                id: descriptor.id,
                title: descriptor.title,
                subtitle: descriptor.subtitle,
                image: preservedImage,
                status: .loading
            )
        }
    }

    func renderFrame(id: String, plan: RenderPlan) async throws -> PreviewFrameModel {
        let descriptor = try descriptor(for: id, plan: plan)
        switch descriptor.kind {
        case .opening(let node):
            let cardSet = BuiltInTemplates.cardSet(id: plan.settings.selectedCardSetID)
            let image = try await MainActor.run {
                try templateRenderer.renderCardNSImage(
                    title: node.text?.title ?? "",
                    subtitle: node.text?.subtitle ?? "",
                    cardSet: cardSet,
                    profile: plan.exportProfile,
                    isQuestionCard: false
                )
            }
            return PreviewFrameModel(id: descriptor.id, title: descriptor.title, subtitle: descriptor.subtitle, image: image, status: .ready)
        case .question(let node):
            let cardSet = BuiltInTemplates.cardSet(id: plan.settings.selectedCardSetID)
            let image = try await MainActor.run {
                try templateRenderer.renderCardNSImage(
                    title: node.text?.title ?? node.questionText ?? "",
                    subtitle: node.text?.subtitle ?? "",
                    cardSet: cardSet,
                    profile: plan.exportProfile,
                    isQuestionCard: true
                )
            }
            return PreviewFrameModel(id: descriptor.id, title: descriptor.title, subtitle: descriptor.subtitle, image: image, status: .ready)
        case .overlay(let node):
            let style = BuiltInTemplates.overlayStyle(id: plan.settings.selectedOverlayStyleID)
            let baseImage = try baseFrameImage(for: node, profile: plan.exportProfile)
            let image = try await MainActor.run {
                try overlayPreviewImage(baseImage: baseImage, node: node, style: style, profile: plan.exportProfile)
            }
            return PreviewFrameModel(id: descriptor.id, title: descriptor.title, subtitle: descriptor.subtitle, image: image, status: .ready)
        }
    }

    private func descriptor(for id: String, plan: RenderPlan) throws -> PreviewDescriptor {
        guard let descriptor = descriptors(for: plan).first(where: { $0.id == id }) else {
            throw TemplateRendererError.failedToRenderImage("Missing preview descriptor for \(id).")
        }
        return descriptor
    }

    private func descriptors(for plan: RenderPlan) -> [PreviewDescriptor] {
        var descriptors: [PreviewDescriptor] = []

        if let openingNode = plan.sequence.first(where: { $0.type == .openingCard }) {
            descriptors.append(
                .init(
                    id: "preview-opening",
                    title: "Opening Card",
                    subtitle: openingNode.text?.title ?? plan.project.projectName,
                    kind: .opening(openingNode)
                )
            )
        }

        if let questionNode = plan.sequence.first(where: { $0.type == .questionCard }) {
            descriptors.append(
                .init(
                    id: "preview-question",
                    title: "Question Card",
                    subtitle: questionNode.text?.title ?? questionNode.questionText ?? "",
                    kind: .question(questionNode)
                )
            )
        }

        if let overlayNode = PreviewSelection.riskiestOverlayNode(in: plan) {
            descriptors.append(
                .init(
                    id: "preview-overlay",
                    title: "Answer Overlay",
                    subtitle: overlayNode.questionText ?? overlayNode.identity?.age ?? overlayNode.nodeID,
                    kind: .overlay(overlayNode)
                )
            )
        }

        return descriptors
    }

    private func overlayPreviewImage(baseImage: NSImage, node: RenderSequenceNode, style: OverlayStyle, profile: ExportProfile) throws -> NSImage {
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

private struct PreviewDescriptor {
    enum Kind {
        case opening(RenderSequenceNode)
        case question(RenderSequenceNode)
        case overlay(RenderSequenceNode)
    }

    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
}
