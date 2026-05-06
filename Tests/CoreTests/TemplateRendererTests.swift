import Core
import XCTest

final class TemplateRendererTests: XCTestCase {
    func testTrailingOverlayQuestionLayoutStaysWithinSafeBounds() {
        let renderer = TemplateRenderer()
        let style = BuiltInTemplates.overlayStyle(id: "age-lower-third-soft")
        let profile = ExportProfile.appleHLG4K60
        let layout = renderer.overlayLayout(
            ageText: "Age 12",
            questionText: "This is a deliberately long interview question that would previously run off the edge of the screen in the trailing lower-third layout.",
            showQuestionText: true,
            style: style,
            profile: profile
        )

        let margin: CGFloat = 80
        let questionRect = try! XCTUnwrap(layout.questionRect)
        XCTAssertGreaterThanOrEqual(questionRect.minX, margin)
        XCTAssertLessThanOrEqual(questionRect.maxX, layout.canvasSize.width - margin)
        XCTAssertLessThanOrEqual(questionRect.maxX, layout.ageRect.maxX)
    }

    func testLeadingOverlayQuestionLayoutStaysWithinSafeBounds() {
        let renderer = TemplateRenderer()
        let style = BuiltInTemplates.overlayStyle(id: "age-bottom-band")
        let profile = ExportProfile.appleHLG4K60
        let layout = renderer.overlayLayout(
            ageText: "Age 9",
            questionText: "Another long question string that still needs to wrap cleanly without colliding with the safe margins.",
            showQuestionText: true,
            style: style,
            profile: profile
        )

        let margin: CGFloat = 80
        let questionRect = try! XCTUnwrap(layout.questionRect)
        XCTAssertGreaterThanOrEqual(questionRect.minX, margin)
        XCTAssertLessThanOrEqual(questionRect.maxX, layout.canvasSize.width - margin)
    }
}
