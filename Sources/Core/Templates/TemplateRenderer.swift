import AppKit
import Foundation

public struct OverlayRenderLayout: Hashable, Sendable {
    public var canvasSize: CGSize
    public var ageRect: CGRect
    public var questionRect: CGRect?

    public init(canvasSize: CGSize, ageRect: CGRect, questionRect: CGRect?) {
        self.canvasSize = canvasSize
        self.ageRect = ageRect
        self.questionRect = questionRect
    }
}

public enum TemplateRendererError: LocalizedError {
    case failedToRenderImage(String)

    public var errorDescription: String? {
        switch self {
        case .failedToRenderImage(let message):
            return message
        }
    }
}

public struct TemplateRenderer: Sendable {
    public init() {}

    public func renderCardImage(
        title: String,
        subtitle: String,
        cardSet: CardSet,
        profile: ExportProfile,
        destinationURL: URL,
        isQuestionCard: Bool
    ) throws {
        let bitmap = try cardBitmap(
            title: title,
            subtitle: subtitle,
            cardSet: cardSet,
            profile: profile,
            isQuestionCard: isQuestionCard
        )
        try writePNG(bitmap: bitmap, destinationURL: destinationURL)
    }

    public func renderCardNSImage(
        title: String,
        subtitle: String,
        cardSet: CardSet,
        profile: ExportProfile,
        isQuestionCard: Bool
    ) throws -> NSImage {
        let size = NSSize(width: profile.width, height: profile.height)
        let bitmap = try cardBitmap(
            title: title,
            subtitle: subtitle,
            cardSet: cardSet,
            profile: profile,
            isQuestionCard: isQuestionCard
        )
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    public func renderOverlayImage(
        ageText: String,
        questionText: String?,
        showQuestionText: Bool,
        style: OverlayStyle,
        profile: ExportProfile,
        destinationURL: URL
    ) throws {
        let bitmap = try overlayBitmap(
            ageText: ageText,
            questionText: questionText,
            showQuestionText: showQuestionText,
            style: style,
            profile: profile
        )
        try writePNG(bitmap: bitmap, destinationURL: destinationURL)
    }

    public func renderOverlayNSImage(
        ageText: String,
        questionText: String?,
        showQuestionText: Bool,
        style: OverlayStyle,
        profile: ExportProfile
    ) throws -> NSImage {
        let size = NSSize(width: profile.width, height: profile.height)
        let bitmap = try overlayBitmap(
            ageText: ageText,
            questionText: questionText,
            showQuestionText: showQuestionText,
            style: style,
            profile: profile
        )
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    public func overlayLayout(
        ageText: String,
        questionText: String?,
        showQuestionText: Bool,
        style: OverlayStyle,
        profile: ExportProfile
    ) -> OverlayRenderLayout {
        let size = CGSize(width: profile.width, height: profile.height)
        let ageFont = NSFont.systemFont(ofSize: 54, weight: .bold)
        let questionFont = NSFont.systemFont(ofSize: 44, weight: .semibold)

        let ageAttributes: [NSAttributedString.Key: Any] = [
            .font: ageFont,
            .foregroundColor: NSColor(hex: style.foregroundHex)
        ]
        let questionAttributes: [NSAttributedString.Key: Any] = [
            .font: questionFont,
            .foregroundColor: NSColor(hex: style.questionForegroundHex)
        ]

        let margin: CGFloat = 80
        let agePadding = NSEdgeInsets(top: 16, left: 26, bottom: 16, right: 26)
        let questionPadding = NSEdgeInsets(top: 14, left: 22, bottom: 14, right: 22)

        let ageSize = (ageText as NSString).size(withAttributes: ageAttributes)
        let ageRect = positionedRect(
            contentSize: CGSize(
                width: ageSize.width + agePadding.left + agePadding.right,
                height: ageSize.height + agePadding.top + agePadding.bottom
            ),
            containerSize: size,
            margin: margin,
            alignment: style.alignment
        )

        guard showQuestionText,
              let questionText,
              !questionText.isEmpty else {
            return .init(canvasSize: size, ageRect: ageRect, questionRect: nil)
        }

        let maxQuestionWidth = min(size.width - (margin * 2), max(size.width * 0.42, 880))
        let measuredQuestionBounds = (questionText as NSString).boundingRect(
            with: CGSize(width: maxQuestionWidth - questionPadding.left - questionPadding.right, height: size.height * 0.28),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: questionAttributes
        ).integral

        let questionContentWidth = min(
            max(measuredQuestionBounds.width + questionPadding.left + questionPadding.right, 420),
            maxQuestionWidth
        )
        let questionContentHeight = measuredQuestionBounds.height + questionPadding.top + questionPadding.bottom
        let questionRect = positionedQuestionRect(
            contentSize: CGSize(width: questionContentWidth, height: questionContentHeight),
            ageRect: ageRect,
            containerSize: size,
            margin: margin,
            alignment: style.alignment
        )

        return .init(canvasSize: size, ageRect: ageRect, questionRect: questionRect)
    }

    private func cardBitmap(
        title: String,
        subtitle: String,
        cardSet: CardSet,
        profile: ExportProfile,
        isQuestionCard: Bool
    ) throws -> NSBitmapImageRep {
        let size = NSSize(width: profile.width, height: profile.height)
        let bitmap = try makeBitmap(size: size)
        try draw(into: bitmap, size: size) {
            let backgroundRect = NSRect(origin: .zero, size: size)
            drawGradient(
                colors: [NSColor(hex: cardSet.backgroundHex), NSColor(hex: cardSet.accentHex).withAlphaComponent(0.75)],
                in: backgroundRect
            )

            let titleFontSize: CGFloat = isQuestionCard ? 138 : 128
            let titleFont = NSFont.systemFont(ofSize: titleFontSize, weight: .semibold)
            let subtitleFont = NSFont.systemFont(ofSize: 48, weight: .medium)
            let footerFont = NSFont.systemFont(ofSize: 28, weight: .medium)

            let titleRect = NSRect(x: 520, y: 900, width: size.width - 1040, height: 420)
            drawCenteredText(
                title,
                in: titleRect,
                font: titleFont,
                color: NSColor(hex: cardSet.foregroundHex)
            )

            if !subtitle.isEmpty {
                let subtitleRect = NSRect(x: 720, y: 760, width: size.width - 1440, height: 80)
                drawCenteredText(
                    subtitle,
                    in: subtitleRect,
                    font: subtitleFont,
                    color: NSColor(hex: cardSet.subtitleHex)
                )
            }

            let lineRect = NSRect(x: (size.width - 280) / 2, y: 1440, width: 280, height: 6)
            NSColor(hex: cardSet.accentHex).setFill()
            NSBezierPath(rect: lineRect).fill()

            let footerRect = NSRect(x: 0, y: 110, width: size.width, height: 40)
            drawCenteredText(
                "Yearly Interview Studio",
                in: footerRect,
                font: footerFont,
                color: NSColor(hex: cardSet.subtitleHex).withAlphaComponent(0.75)
            )
        }
        return bitmap
    }

    private func overlayBitmap(
        ageText: String,
        questionText: String?,
        showQuestionText: Bool,
        style: OverlayStyle,
        profile: ExportProfile
    ) throws -> NSBitmapImageRep {
        let size = NSSize(width: profile.width, height: profile.height)
        let bitmap = try makeBitmap(size: size)
        try draw(into: bitmap, size: size) {
            NSColor.clear.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

            let ageFont = NSFont.systemFont(ofSize: 54, weight: .bold)
            let questionFont = NSFont.systemFont(ofSize: 44, weight: .semibold)
            let agePadding = NSEdgeInsets(top: 16, left: 26, bottom: 16, right: 26)
            let questionPadding = NSEdgeInsets(top: 14, left: 22, bottom: 14, right: 22)

            let ageAttributes: [NSAttributedString.Key: Any] = [
                .font: ageFont,
                .foregroundColor: NSColor(hex: style.foregroundHex)
            ]
            let questionAttributes: [NSAttributedString.Key: Any] = [
                .font: questionFont,
                .foregroundColor: NSColor(hex: style.questionForegroundHex)
            ]

            let layout = overlayLayout(
                ageText: ageText,
                questionText: questionText,
                showQuestionText: showQuestionText,
                style: style,
                profile: profile
            )

            if let questionRect = layout.questionRect,
               let questionText,
               showQuestionText,
               !questionText.isEmpty {
                drawRoundedRect(questionRect, radius: 18, fill: NSColor(hex: style.backgroundHex).withAlphaComponent(0.85))
                let drawRect = questionRect.insetBy(dx: questionPadding.left, dy: questionPadding.top)
                (questionText as NSString).draw(
                    with: drawRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: questionAttributes
                )
            }

            drawRoundedRect(layout.ageRect, radius: layout.ageRect.height / 2, fill: NSColor(hex: style.backgroundHex).withAlphaComponent(0.92))
            let ageTextRect = layout.ageRect.insetBy(dx: agePadding.left, dy: agePadding.top)
            (ageText as NSString).draw(in: ageTextRect, withAttributes: ageAttributes)
        }
        return bitmap
    }

    private func drawGradient(colors: [NSColor], in rect: NSRect) {
        guard colors.count >= 2, let gradient = NSGradient(colors: colors) else {
            colors.first?.setFill()
            NSBezierPath(rect: rect).fill()
            return
        }
        gradient.draw(in: rect, angle: 315)
    }

    private func drawCenteredText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
    }

    private func positionedRect(contentSize: CGSize, containerSize: CGSize, margin: CGFloat, alignment: String) -> CGRect {
        switch alignment {
        case "topLeading":
            return CGRect(x: margin, y: containerSize.height - contentSize.height - margin, width: contentSize.width, height: contentSize.height)
        case "topTrailing":
            return CGRect(x: containerSize.width - contentSize.width - margin, y: containerSize.height - contentSize.height - margin, width: contentSize.width, height: contentSize.height)
        case "bottomLeading":
            return CGRect(x: margin, y: margin, width: contentSize.width, height: contentSize.height)
        default:
            return CGRect(x: containerSize.width - contentSize.width - margin, y: margin, width: contentSize.width, height: contentSize.height)
        }
    }

    private func positionedQuestionRect(contentSize: CGSize, ageRect: CGRect, containerSize: CGSize, margin: CGFloat, alignment: String) -> CGRect {
        let verticalGap: CGFloat = 16
        let isTrailing = alignment.contains("Trailing")
        let proposedX = isTrailing ? ageRect.maxX - contentSize.width : ageRect.minX
        let clampedX = min(max(proposedX, margin), containerSize.width - margin - contentSize.width)

        let proposedY: CGFloat
        switch alignment {
        case "topLeading", "topTrailing":
            proposedY = ageRect.minY - contentSize.height - verticalGap
        default:
            proposedY = ageRect.maxY + verticalGap
        }
        let clampedY = min(max(proposedY, margin), containerSize.height - margin - contentSize.height)

        return CGRect(x: clampedX, y: clampedY, width: contentSize.width, height: contentSize.height)
    }

    private func drawRoundedRect(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private func makeBitmap(size: NSSize) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw TemplateRendererError.failedToRenderImage("AppKit could not allocate a bitmap drawing surface.")
        }
        return bitmap
    }

    private func draw(into bitmap: NSBitmapImageRep, size: NSSize, drawBlock: () -> Void) throws {
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw TemplateRendererError.failedToRenderImage("AppKit could not create a graphics context for template rendering.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer {
            NSGraphicsContext.restoreGraphicsState()
        }
        drawBlock()
        context.flushGraphics()
    }

    private func writePNG(bitmap: NSBitmapImageRep, destinationURL: URL) throws {
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw TemplateRendererError.failedToRenderImage("AppKit could not encode a PNG image for template output.")
        }
        try pngData.write(to: destinationURL)
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let a, r, g, b: UInt64
        switch cleaned.count {
        case 8:
            r = (value >> 24) & 0xFF
            g = (value >> 16) & 0xFF
            b = (value >> 8) & 0xFF
            a = value & 0xFF
        default:
            r = (value >> 16) & 0xFF
            g = (value >> 8) & 0xFF
            b = value & 0xFF
            a = 0xFF
        }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}
