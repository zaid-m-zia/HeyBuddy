import AppKit

/// A deterministic sample window. Its overlay is confined to the sample content;
/// no Gemini call, API key, or desktop screenshot is involved.
@MainActor
final class DrawingDemoController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let overlay: Overlay
    private let player: PresentationPlayer

    override init() {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let content = CGRect(x: screen.midX - 425, y: screen.midY - 280, width: 850, height: 560)
        let sample = NSWindow(contentRect: content, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        sample.title = "HeyBuddy Drawing Lab"
        sample.isReleasedWhenClosed = false
        sample.minSize = sample.frame.size
        sample.maxSize = sample.frame.size
        window = sample
        let sampleOverlay = Overlay(frame: sample.contentRect(forFrameRect: sample.frame))
        overlay = sampleOverlay
        player = PresentationPlayer(overlay: sampleOverlay)
        super.init()
        sample.delegate = self
        buildSampleContent()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        syncOverlay()
        replay()
    }

    func stop() {
        player.cancel()
        overlay.hide()
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { stop() }
    func windowDidMove(_ notification: Notification) { syncOverlay() }

    private func syncOverlay() {
        overlay.setDisplayFrame(window.contentRect(forFrameRect: window.frame))
    }

    private func buildSampleContent() {
        guard let root = window.contentView else { return }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1).cgColor

        func label(_ text: String, frame: CGRect, size: CGFloat, bold: Bool = false) {
            let field = NSTextField(labelWithString: text)
            field.frame = frame
            field.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            field.textColor = NSColor(srgbRed: 0.13, green: 0.18, blue: 0.26, alpha: 1)
            root.addSubview(field)
        }
        func card(_ frame: CGRect, title: String, detail: String) {
            let view = NSView(frame: frame)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.white.cgColor
            view.layer?.cornerRadius = 14
            view.layer?.borderColor = NSColor.systemGray.withAlphaComponent(0.25).cgColor
            view.layer?.borderWidth = 1
            root.addSubview(view)
            let titleField = NSTextField(labelWithString: title)
            titleField.font = NSFont.boldSystemFont(ofSize: 20)
            titleField.frame = CGRect(x: 22, y: 73, width: frame.width - 44, height: 30)
            view.addSubview(titleField)
            let detailField = NSTextField(labelWithString: detail)
            detailField.font = NSFont.systemFont(ofSize: 14)
            detailField.frame = CGRect(x: 22, y: 35, width: frame.width - 44, height: 44)
            detailField.maximumNumberOfLines = 2
            view.addSubview(detailField)
        }

        label("Learn by seeing", frame: CGRect(x: 80, y: 470, width: 650, height: 44), size: 32, bold: true)
        label("A sample screen for precise, readable annotations", frame: CGRect(x: 82, y: 424, width: 680, height: 28), size: 16)
        card(CGRect(x: 78, y: 248, width: 320, height: 142), title: "1  Identify the goal", detail: "Read the heading and choose the next step.")
        card(CGRect(x: 452, y: 248, width: 320, height: 142), title: "2  Connect the ideas", detail: "Use arrows to show how steps relate.")
        label("Review the sequence, then ask a follow-up question.",
              frame: CGRect(x: 82, y: 158, width: 680, height: 32), size: 17)
        label("Annotations appear only where they help explain this sample.",
              frame: CGRect(x: 82, y: 115, width: 680, height: 28), size: 14)

        let replayButton = NSButton(title: "Replay drawings", target: self, action: #selector(replayAction))
        replayButton.frame = CGRect(x: 80, y: 25, width: 145, height: 32)
        root.addSubview(replayButton)
    }

    @objc private func replayAction() { replay() }

    private func replay() {
        player.cancel()
        overlay.hide()
        syncOverlay()
        let steps = Self.demoSteps()
        player.play(steps: steps) { [weak self] in self?.overlay.hide() }
    }

    private static func demoSteps() -> [Step] {
        func p(_ x: Double, _ y: Double) -> DrawingPoint { DrawingPoint(x: x, y: y) }
        func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DrawingRect {
            DrawingRect(x: x, y: y, width: w, height: h)
        }
        func d(_ kind: DrawingKind, _ geometry: DrawingGeometry, text: String? = nil, order: Int? = nil) -> DrawingElement {
            DrawingElement(kind: kind, geometry: geometry, text: text, order: order)
        }
        return [
            Step(say: "First, underline the heading and highlight a key phrase.", cue: "underline",
                 focus: [135, 260], annotations: nil, keep: false, drawings: [
                    d(.underline, .rect(r(95, 82, 335, 82)), order: 0),
                    d(.highlight, .rect(r(95, 188, 435, 42)), order: 1),
                    d(.explanatoryLabel, .point(p(555, 175)), text: "Start with the title", order: 2)
                 ]),
            Step(say: "A straight arrow shows the flow. A curved arrow shows another route around it.", cue: "arrow",
                 focus: [440, 490], annotations: nil, keep: false, drawings: [
                    d(.circle, .rect(r(95, 300, 350, 260)), order: 0),
                    d(.ellipse, .rect(r(530, 300, 360, 260)), order: 1),
                    d(.arrow, .segment(p(425, 418), p(530, 418)), order: 2),
                    d(.curvedArrow, .cubic(p(400, 500), p(470, 270), p(560, 265), p(625, 330)), order: 3)
                 ]),
            Step(say: "Polygons, braces, brackets, and smooth strokes group ideas without covering the words.", cue: "group ideas",
                 focus: [620, 360], annotations: nil, keep: false, drawings: [
                    d(.polygon, .path([p(105, 580), p(335, 570), p(365, 680), p(120, 700)]), order: 0),
                    d(.regularPolygon, .regularPolygon(r(560, 560, 110, 110), 5), order: 1),
                    d(.brace, .rect(r(65, 300, 28, 300)), order: 2),
                    d(.bracket, .rect(r(900, 300, 28, 300)), order: 3),
                    d(.freehand, .path([p(180, 740), p(260, 720), p(360, 750), p(470, 725), p(560, 750)]), order: 4),
                    d(.curve, .cubic(p(600, 740), p(675, 680), p(740, 790), p(830, 735)), order: 5)
                 ]),
            Step(say: "The spotlight reveals the important area. Numbered markers show a real sequence, while labels avoid each other.", cue: "spotlight",
                 focus: [470, 500], annotations: nil, keep: false, drawings: [
                    d(.spotlight, .rect(r(80, 290, 830, 430)), order: 0),
                    d(.badge, .point(p(120, 330)), text: "1", order: 1),
                    d(.badge, .point(p(520, 330)), text: "2", order: 2),
                    d(.badge, .point(p(760, 330)), text: "3", order: 3),
                    d(.label, .point(p(500, 610)), text: "Read the goal", order: 4),
                    d(.label, .point(p(505, 612)), text: "Follow the connection", order: 5)
                 ])
        ]
    }
}
