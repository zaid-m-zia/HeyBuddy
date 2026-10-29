import XCTest
import AppKit
@testable import Buddy

@MainActor
final class DrawingEngineTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> DrawingPoint { DrawingPoint(x: x, y: y) }
    private func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DrawingRect {
        DrawingRect(x: x, y: y, width: w, height: h)
    }
    private var mapper: CanvasMapper { CanvasMapper(size: CGSize(width: 800, height: 600)) }

    func testMappingAndBounds() {
        XCTAssertEqual(mapper.point(p(0, 0)), CGPoint(x: 0, y: 600))
        XCTAssertEqual(mapper.point(p(1000, 1000)), CGPoint(x: 800, y: 0))
        XCTAssertEqual(mapper.rect(r(100, 200, 200, 100)), CGRect(x: 80, y: 420, width: 160, height: 60))
        XCTAssertFalse(p(.nan, 10).isValid)
        XCTAssertFalse(r(950, 100, 100, 20).isValid)
        XCTAssertFalse(r(100, 100, 0, 20).isValid)
    }

    func testValidationRejectsBadElementsIndividually() throws {
        let json = #"[{"type":"circle","rect":{"x":100,"y":100,"width":200,"height":100}},{"type":"circle","rect":{"x":-3,"y":100,"width":200,"height":100}},{"type":"unknown","point":{"x":200,"y":200}}]"#
        let decoded = try JSONDecoder().decode([DrawingElement].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded.filter(\.isValid).count, 1)
        let rendered = DrawingRenderer().render(decoded, mapper: mapper, backingScale: 2)
        XCTAssertEqual(rendered.count, 1)
        let mixed = #"{"say":"Keep speaking","drawings":[17,{"type":"circle","rect":{"x":100,"y":100,"width":200,"height":100}}]}"#
        let step = try JSONDecoder().decode(Step.self, from: Data(mixed.utf8))
        XCTAssertEqual(step.say, "Keep speaking")
        XCTAssertEqual(step.drawings?.count, 1)
    }

    func testOutlineHighlightAndSpotlightStyles() {
        let elements = [
            DrawingElement(kind: .rect, geometry: .rect(r(100, 100, 200, 100))),
            DrawingElement(kind: .highlight, geometry: .rect(r(100, 220, 200, 45))),
            DrawingElement(kind: .spotlight, geometry: .rect(r(100, 320, 200, 100)))
        ]
        let layers = DrawingRenderer().render(elements, mapper: mapper, backingScale: 2)
        XCTAssertEqual(layers.count, 3)
        let outline = layers[0].layer as? CAShapeLayer
        XCTAssertNil(outline?.fillColor)
        XCTAssertEqual(outline?.contentsScale, 2)
        XCTAssertEqual(layers[1].layer.backgroundColor?.alpha ?? -1, 0.25, accuracy: 0.001)
        let spotlight = layers[2].layer as? CAShapeLayer
        XCTAssertEqual(spotlight?.fillRule, .evenOdd)
        XCTAssertEqual(spotlight?.fillColor?.alpha ?? -1, 0.55, accuracy: 0.001)
    }

    func testGeometryAndLabelPlacement() {
        let shapes = [
            DrawingElement(kind: .arrow, geometry: .segment(p(100, 100), p(300, 300))),
            DrawingElement(kind: .curvedArrow, geometry: .cubic(p(100, 100), p(150, 50), p(250, 350), p(300, 300))),
            DrawingElement(kind: .regularPolygon, geometry: .regularPolygon(r(400, 200, 100, 100), 5)),
            DrawingElement(kind: .brace, geometry: .rect(r(600, 200, 30, 200)))
        ]
        let layers = DrawingRenderer().render(shapes, mapper: mapper, backingScale: 1)
        XCTAssertEqual(layers.count, 4)
        XCTAssertEqual(layers[0].layer.sublayers?.count, 2) // shaft, then head
        XCTAssertNotNil((layers[2].layer as? CAShapeLayer)?.path)

        var placer = DrawingLabelPlacer(canvas: CGRect(x: 0, y: 0, width: 400, height: 300))
        let first = placer.place(near: CGPoint(x: 390, y: 290), size: CGSize(width: 120, height: 28))
        let second = placer.place(near: CGPoint(x: 390, y: 290), size: CGSize(width: 120, height: 28))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 400, height: 300).contains(first))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 400, height: 300).contains(second))
        XCTAssertTrue(first.intersection(second).isNull)
    }

    func testSerializationAndPerStepLimit() throws {
        let element = DrawingElement(id: "curve-1", kind: .curve,
                                     geometry: .cubic(p(100, 100), p(150, 80), p(230, 300), p(300, 300)),
                                     duration: 0.4, order: 2, purpose: "show direction")
        let decoded = try JSONDecoder().decode(DrawingElement.self, from: JSONEncoder().encode(element))
        XCTAssertEqual(decoded.id, "curve-1")
        XCTAssertTrue(decoded.isValid)
        let many = (0..<12).map { index in
            DrawingElement(id: "mark-\(index)", kind: .circle,
                           geometry: .rect(r(Double(index * 30), 100, 25, 25)))
        }
        XCTAssertEqual(DrawingRenderer().render(many, mapper: mapper, backingScale: 2).count, 8)
    }

    func testLegacyPlanAndLayerLifecycle() throws {
        _ = NSApplication.shared
        let old = #"{"steps":[{"say":"Hello","annotations":[{"type":"circle","box_2d":[100,200,300,400]}]}]}"#
        let plan = try JSONDecoder().decode(Plan.self, from: Data(old.utf8))
        let step = try XCTUnwrap(plan.steps?.first)
        let overlay = Overlay(frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        overlay.showAnnotations(for: step, stepIndex: 0)
        overlay.showAnnotations(for: step, stepIndex: 0)
        XCTAssertEqual(overlay.activeDrawingCount, 1)
        overlay.cancel()
        XCTAssertEqual(overlay.activeDrawingCount, 0)

        let spotlight = Step(say: "Focus", cue: nil, focus: nil, annotations: nil, keep: false,
                             drawings: [DrawingElement(kind: .spotlight, geometry: .rect(r(100, 100, 300, 300)))])
        overlay.showAnnotations(for: spotlight, stepIndex: 1)
        XCTAssertEqual(overlay.activeSpotlightCount, 1)
        overlay.finishStep(spotlight, stepIndex: 1)
        XCTAssertEqual(overlay.activeSpotlightCount, 0)
        overlay.cancel()
        XCTAssertEqual(overlay.activeDrawingCount, 0)
    }

    func testStaleFinishCannotHideNewPresentation() async {
        _ = NSApplication.shared
        let overlay = Overlay(frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        let stale = expectation(description: "stale completion")
        stale.isInverted = true
        overlay.finishPresentation { stale.fulfill() }
        overlay.beginPresentation()
        await fulfillment(of: [stale], timeout: 0.5)
        overlay.hide()
    }

    func testEveryAdvertisedPrimitiveDecodesValidatesAndRenders() throws {
        let point = p(300, 300)
        let rect = r(200, 200, 200, 120)
        let samples: [(DrawingKind, DrawingGeometry, String?)] = [
            (.pointer, .point(point), nil), (.line, .segment(p(100, 100), point), nil),
            (.polyline, .path([p(100, 100), point]), nil),
            (.arrow, .segment(p(100, 100), point), nil),
            (.curvedArrow, .cubic(p(100, 100), p(150, 50), p(250, 350), point), nil),
            (.curve, .cubic(p(100, 100), p(150, 50), p(250, 350), point), nil),
            (.circle, .rect(rect), nil), (.ellipse, .rect(rect), nil),
            (.rect, .rect(rect), nil), (.roundedRect, .rect(rect), nil),
            (.polygon, .path([p(100, 100), p(200, 100), point]), nil),
            (.regularPolygon, .regularPolygon(rect, 5), nil),
            (.underline, .rect(rect), nil), (.highlight, .rect(rect), nil),
            (.spotlight, .rect(rect), nil), (.brace, .rect(rect), nil),
            (.bracket, .rect(rect), nil), (.freehand, .path([p(100, 100), point]), nil),
            (.label, .point(point), "Target"), (.explanatoryLabel, .point(point), "Why"),
            (.badge, .point(point), "1")
        ]
        for (kind, geometry, text) in samples {
            let encoded = try JSONEncoder().encode(DrawingElement(kind: kind, geometry: geometry, text: text))
            let decoded = try JSONDecoder().decode(DrawingElement.self, from: encoded)
            XCTAssertEqual(decoded.kind, kind)
            XCTAssertTrue(decoded.isValid, "\(kind) should validate")
            XCTAssertEqual(DrawingRenderer().render([decoded], mapper: mapper, backingScale: 2).count, 1,
                           "\(kind) should render")
        }
    }

    func testColorSelectionAndInvalidDrawingNeverBecomeHighlight() throws {
        let red = #"{"type":"rect","rect":{"x":100,"y":100,"width":200,"height":100},"style":{"color":"red"},"purpose":"identify Settings"}"#
        let element = try JSONDecoder().decode(DrawingElement.self, from: Data(red.utf8))
        XCTAssertTrue(element.isValid)
        let layer = try XCTUnwrap(DrawingRenderer().render([element], mapper: mapper, backingScale: 2).first?.layer as? CAShapeLayer)
        XCTAssertNil(layer.fillColor)
        XCTAssertNotNil(layer.strokeColor)
        let unknown = #"{"type":"unknown","rect":{"x":100,"y":100,"width":200,"height":100}}"#
        let invalid = try JSONDecoder().decode(DrawingElement.self, from: Data(unknown.utf8))
        XCTAssertFalse(invalid.isValid)
        XCTAssertTrue(DrawingRenderer().render([invalid], mapper: mapper, backingScale: 2).isEmpty)
        let badColor = red.replacingOccurrences(of: "red", with: "chartreuse")
        XCTAssertFalse(try JSONDecoder().decode(DrawingElement.self, from: Data(badColor.utf8)).isValid)
    }

    func testWholeScreenshotResizeAndSecondaryDisplayCoordinates() {
        let frame = CGRect(x: -1200, y: 100, width: 1200, height: 800)
        let displayMapper = CanvasMapper(size: frame.size)
        let global = CGPoint(x: -900, y: 700)
        let normalized = displayMapper.normalized(global, displayFrame: frame)
        XCTAssertEqual(normalized, p(250, 250))
        XCTAssertEqual(displayMapper.point(normalized), CGPoint(x: 300, y: 600))
        XCTAssertEqual(Screen.accessibilityPoint(global, primaryDisplayTop: 900), CGPoint(x: -900, y: 200))
        XCTAssertTrue(Screen.captureMatchesDisplay(pixelSize: CGSize(width: 1920, height: 1280), displayFrame: frame))
        XCTAssertFalse(Screen.captureMatchesDisplay(pixelSize: CGSize(width: 1280, height: 800), displayFrame: frame))
        // A 2x Retina image resized to 1280 pixels has the same normalized center.
        XCTAssertEqual(displayMapper.point(p(500, 500)), CGPoint(x: 600, y: 400))
    }

    func testArrowPointerUsesEndpointAndSpotlightHoleIsTransparent() throws {
        let arrow = DrawingElement(kind: .arrow, geometry: .segment(p(100, 100), p(750, 500)))
        XCTAssertEqual(arrow.anchor, p(750, 500))
        let curved = DrawingElement(kind: .curvedArrow,
                                    geometry: .cubic(p(100, 100), p(200, 50), p(650, 450), p(750, 500)))
        XCTAssertEqual(curved.anchor, p(750, 500))
        let renderedArrow = try XCTUnwrap(DrawingRenderer().render([arrow], mapper: mapper, backingScale: 2).first)
        let shaft = renderedArrow.layer.sublayers?.first as? CAShapeLayer
        XCTAssertEqual(shaft?.path?.currentPoint, mapper.point(p(750, 500)))
        let spotlight = DrawingElement(kind: .spotlight, geometry: .rect(r(100, 100, 300, 300)))
        let mask = try XCTUnwrap(DrawingRenderer().render([spotlight], mapper: mapper, backingScale: 2).first?.layer as? CAShapeLayer)
        let path = try XCTUnwrap(mask.path)
        XCTAssertFalse(path.contains(mapper.point(p(250, 250)), using: .evenOdd, transform: .identity))
        XCTAssertTrue(path.contains(mapper.point(p(900, 900)), using: .evenOdd, transform: .identity))
    }

    func testMultipleDrawingsAndLegacyFallbackSurviveInvalidNewPlan() throws {
        _ = NSApplication.shared
        let json = #"{"say":"Click Settings","drawings":[{"type":"unknown"}],"annotations":[{"type":"rect","box_2d":[100,200,250,400]}]}"#
        let step = try JSONDecoder().decode(Step.self, from: Data(json.utf8))
        let overlay = Overlay(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        overlay.showAnnotations(for: step, stepIndex: 0)
        XCTAssertEqual(overlay.activeDrawingCount, 1)
        overlay.cancel()
        let two = Step(say: "Two targets", cue: nil, focus: nil, annotations: nil, keep: false,
                       drawings: [DrawingElement(kind: .rect, geometry: .rect(r(100, 100, 150, 80))),
                                  DrawingElement(kind: .arrow, geometry: .segment(p(400, 400), p(200, 150)))])
        overlay.beginPresentation()
        overlay.showAnnotations(for: two, stepIndex: 0)
        XCTAssertEqual(overlay.activeDrawingCount, 2)
        overlay.beginPresentation()
        overlay.showAnnotations(for: step, stepIndex: 0)
        XCTAssertEqual(overlay.activeDrawingCount, 1, "A new request must replace old layers and step indices")
        overlay.cancel()
        XCTAssertEqual(overlay.activeDrawingCount, 0)
    }

    func testSpeechStepSurvivesEmptyAndMalformedDrawingLists() throws {
        let empty = #"{"say":"Here is the answer","cue":"answer","drawings":[]}"#
        let malformed = #"{"say":"Keep speaking","drawings":[23,{"type":"unknown"}]}"#
        let first = try JSONDecoder().decode(Step.self, from: Data(empty.utf8))
        let second = try JSONDecoder().decode(Step.self, from: Data(malformed.utf8))
        XCTAssertEqual(first.say, "Here is the answer")
        XCTAssertEqual(first.cue, "answer")
        XCTAssertEqual(first.drawings?.count, 0)
        XCTAssertEqual(second.say, "Keep speaking")
        XCTAssertEqual(second.drawings?.filter(\.isValid).count, 0)
    }

    func testUniqueLocalOCRSnapsTextArrowAndCompactUIOutline() throws {
        let target = try XCTUnwrap(OCRTarget(text: "Settings", visionBox: CGRect(x: 0.20, y: 0.60, width: 0.10, height: 0.05)))
        XCTAssertEqual(target.rect, r(200, 350, 100, 50))
        let original = [
            DrawingElement(kind: .highlight, geometry: .rect(r(180, 330, 140, 80)), targetText: "Settings"),
            DrawingElement(kind: .arrow, geometry: .segment(p(100, 100), p(300, 300)), targetText: "Settings"),
            DrawingElement(kind: .rect, geometry: .rect(r(170, 310, 180, 110)), targetText: "Settings")
        ]
        let plan = Plan(steps: [Step(say: "Open Settings", cue: nil, focus: nil,
                                     annotations: nil, keep: false, drawings: original)],
                        actions: nil, say: nil, points: nil)
        let refined = DrawingTargetResolver.refine(plan, targets: [target])
        let drawings = try XCTUnwrap(refined.steps?.first?.drawings)
        XCTAssertEqual(drawings[0].geometry, .rect(target.rect))
        XCTAssertEqual(drawings[1].geometry, .segment(p(100, 100), p(250, 375)))
        XCTAssertEqual(drawings[2].geometry, .rect(r(160, 320, 180, 110)))
        let ambiguous = DrawingTargetResolver.refine(plan, targets: [target, target])
        XCTAssertEqual(ambiguous.steps?.first?.drawings?[0].geometry, original[0].geometry)
    }

    func testModelAliasesAndLegacyCoordinatesKeepTheirShapes() throws {
        let json = #"{"visual":true,"steps":[{"say":"Open Settings","drawings":[{"type":"Rectangle","box_2d":[100,200,220,420],"style":{"color":"RED"}},{"type":"ARROW","from":[250,100],"to":[160,310]},{"type":"Highlight","rect":{"x":200,"y":300,"width":100,"height":25}},{"type":"mystery","rect":{"x":1,"y":1,"width":2,"height":2}}]}]}"#
        let plan = try JSONDecoder().decode(Plan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.visual, true)
        let drawings = try XCTUnwrap(plan.steps?.first?.drawings)
        XCTAssertEqual(drawings[0].kind, .rect)
        XCTAssertEqual(drawings[0].geometry, .rect(r(200, 100, 220, 120)))
        XCTAssertEqual(drawings[1].geometry, .segment(p(100, 250), p(310, 160)))
        XCTAssertEqual(drawings[2].kind, .highlight)
        XCTAssertFalse(drawings[3].isValid)
        let layers = DrawingRenderer().render(drawings, mapper: mapper, backingScale: 2)
        XCTAssertEqual(layers.count, 3)
        XCTAssertNil((layers[0].layer as? CAShapeLayer)?.fillColor)
        let malformedFlag = #"{"visual":"true","steps":[{"say":"Still spoken","drawings":[]}]}"#
        let recovered = try JSONDecoder().decode(Plan.self, from: Data(malformedFlag.utf8))
        XCTAssertNil(recovered.visual)
        XCTAssertEqual(recovered.normalizedSteps().first?.say, "Still spoken")
    }

    func testPointerRequiresIntentionalValidEndpoint() throws {
        _ = NSApplication.shared
        let overlay = Overlay(frame: CGRect(x: 50, y: 80, width: 800, height: 600))
        overlay.beginPresentation()
        let still = overlay.pointer.position
        let speech = Step(say: "The answer is forty two", cue: nil, focus: [100, 900],
                          annotations: nil, keep: false)
        overlay.startStep(speech, stepIndex: 0)
        XCTAssertTrue(overlay.pointer.isHidden)
        XCTAssertEqual(overlay.pointer.position, still)
        let box = Step(say: "Settings is here", cue: nil, focus: nil, annotations: nil,
                       keep: false, drawings: [DrawingElement(kind: .rect, geometry: .rect(r(200, 200, 100, 50)))])
        overlay.startStep(box, stepIndex: 1)
        XCTAssertTrue(overlay.pointer.isHidden)
        let arrow = Step(say: "Click here", cue: nil, focus: nil, annotations: nil,
                         keep: false, drawings: [DrawingElement(kind: .arrow,
                            geometry: .segment(p(100, 100), p(300, 250)))])
        XCTAssertEqual(arrow.pointerTarget, p(300, 250))
        overlay.startStep(arrow, stepIndex: 2)
        XCTAssertFalse(overlay.pointer.isHidden)
        XCTAssertEqual(overlay.pointer.position, mapper.point(p(300, 250)))
        overlay.cancel()
    }

    func testVisualRequestAndActualLayerCount() {
        XCTAssertTrue(VisualRequest.requiresGuidance("Show me where to click"))
        XCTAssertTrue(VisualRequest.requiresGuidance("Explain this paragraph"))
        XCTAssertFalse(VisualRequest.requiresGuidance("What is photosynthesis?"))
        _ = NSApplication.shared
        let overlay = Overlay(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        overlay.beginPresentation()
        let empty = Step(say: "I cannot see that target", cue: nil, focus: nil,
                         annotations: nil, keep: false, drawings: [])
        overlay.showAnnotations(for: empty, stepIndex: 0)
        XCTAssertEqual(overlay.presentedDrawingCount, 0)
        let valid = Step(say: "Here it is", cue: nil, focus: nil, annotations: nil,
                         keep: false, drawings: [DrawingElement(kind: .rect,
                            geometry: .rect(r(200, 200, 100, 50)))])
        overlay.showAnnotations(for: valid, stepIndex: 1)
        XCTAssertEqual(overlay.presentedDrawingCount, 1)
        overlay.beginPresentation()
        XCTAssertEqual(overlay.presentedDrawingCount, 0)
        overlay.cancel()
    }
}
