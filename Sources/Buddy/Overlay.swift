// Overlay.swift
// Stages 1, 4, 8 – High-performance Core Animation annotation engine.
//
// Draws synchronized visual annotations (circles, boxes, arrows, lines, polygons,
// underlines, highlights, spotlights, badges, labels) onto a click-through,
// multi-display-aware transparent NSPanel.

import AppKit
import QuartzCore

@MainActor
final class Overlay {
    let win: NSPanel
    let root = NSView()
    let pointer = CALayer()
    let pointerTri = CAShapeLayer()
    let pointerLabel = CATextLayer()

    var followTimer: Timer?
    var follow = false

    // Track active annotation layers per step so they can be selectively faded
    private var activeStepLayers: [Int: [CALayer]] = [:]
    private var activeStepSpotlights: [Int: [CALayer]] = [:]
    private var allActiveLayers: [CALayer] = []
    private var shownSteps: Set<Int> = []
    private var presentationGeneration = 0
    private let drawingRenderer = DrawingRenderer()

    // Stored display frame from the last capture (used for coordinate mapping)
    private var displayFrame: CGRect

    // Maximum simultaneous active annotation layers to prevent runaway GPU load
    private let maxSimultaneousLayers = 24

    init(frame: CGRect? = nil) {
        let f = frame ?? NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        displayFrame = f

        win = NSPanel(
            contentRect: f,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        root.frame = CGRect(origin: .zero, size: f.size)
        root.wantsLayer = true
        win.contentView = root

        setupPointer()
    }

    private func setupPointer() {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 4, y: -22))
        path.addLine(to: CGPoint(x: 16, y: -13))
        path.closeSubpath()
        pointerTri.path = path
        pointerTri.fillColor   = NSColor.systemBlue.cgColor
        pointerTri.strokeColor = NSColor.white.cgColor
        pointerTri.lineWidth   = 1.5
        pointerTri.shadowColor   = NSColor.systemBlue.cgColor
        pointerTri.shadowOpacity = 0.9
        pointerTri.shadowRadius  = 6
        pointerTri.shadowOffset  = .zero
        pointerTri.contentsScale = win.backingScaleFactor

        pointerLabel.fontSize        = 13
        pointerLabel.foregroundColor = NSColor.white.cgColor
        pointerLabel.backgroundColor = NSColor.black.withAlphaComponent(0.80).cgColor
        pointerLabel.cornerRadius    = 6
        pointerLabel.alignmentMode   = .center
        pointerLabel.truncationMode  = .end
        pointerLabel.contentsScale   = win.backingScaleFactor
        pointerLabel.isHidden        = true

        pointer.addSublayer(pointerTri)
        pointer.addSublayer(pointerLabel)
        pointer.zPosition = 1000 // Always render pointer above annotations
        root.layer?.addSublayer(pointer)
    }

    // -------------------------------------------------------------------------
    // MARK: Coordinate Mapping
    // -------------------------------------------------------------------------

    /// Gemini model convention: (0,0) is top-left, (1000,1000) is bottom-right.
    /// AppKit window local convention: (0,0) is bottom-left, y increases upwards.
    /// Mapping:
    ///   x_local = (xNorm / 1000.0) * width
    ///   y_local = height - (yNorm / 1000.0) * height
    func mapPoint(yNorm: Double, xNorm: Double) -> CGPoint {
        let point = DrawingPoint(x: xNorm, y: yNorm)
        guard point.isValid else { return pointer.position }
        return CanvasMapper(size: displayFrame.size).point(point)
    }

    func mapBox(_ box: [Double]) -> CGRect {
        guard box.count == 4 else { return .zero }
        let rect = DrawingRect(x: box[1], y: box[0], width: box[3] - box[1], height: box[2] - box[0])
        guard rect.isValid else { return .zero }
        return CanvasMapper(size: displayFrame.size).rect(rect)
    }

    // -------------------------------------------------------------------------
    // MARK: Display & Mode Management
    // -------------------------------------------------------------------------

    func setDisplayFrame(_ frame: CGRect) {
        displayFrame = frame
        if ProcessInfo.processInfo.environment["BUDDY_DRAW_DEBUG"] == "1" {
            blogDebug("[DRAWING] overlayFrame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) points backingScale=\(win.backingScaleFactor)")
        }
        win.setFrame(frame, display: false)
        root.frame = CGRect(origin: .zero, size: frame.size)
        let mouse = NSEvent.mouseLocation
        if frame.contains(mouse) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pointer.position = CGPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
            CATransaction.commit()
        }
    }

    func setLabel(_ s: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointerLabel.isHidden = s.isEmpty
        pointerLabel.string   = s
        pointerLabel.frame    = CGRect(x: 18, y: -46, width: min(CGFloat(s.count) * 8 + 18, 360), height: 22)
        CATransaction.commit()
    }

    func show(_ s: String) {
        follow = true
        setLabel(s)
        win.orderFrontRegardless()
        followTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.follow else { return }
                let m = NSEvent.mouseLocation
                // Convert mouse global coordinates to window local coordinates
                let localX = m.x - self.displayFrame.minX
                let localY = m.y - self.displayFrame.minY
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.pointer.position = CGPoint(x: localX, y: localY)
                CATransaction.commit()
            }
        }
        followTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func hide() {
        presentationGeneration += 1
        follow = false
        followTimer?.invalidate()
        followTimer = nil
        removeAllLayers()
        setLabel("")
        win.orderOut(nil)
        blogDebug("[OVERLAY] hidden")
    }

    func cancel() {
        hide()
    }

    func beginPresentation() {
        presentationGeneration += 1
        removeAllLayers()
        follow = false
        followTimer?.invalidate()
        followTimer = nil
        setLabel("")
        win.orderFrontRegardless()
        if ProcessInfo.processInfo.environment["BUDDY_DRAW_DEBUG"] == "1" {
            blogDebug("[DRAWING] presentation began; previous layers cleared")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Presentation Step Lifecycle
    // -------------------------------------------------------------------------

    func startStep(_ step: Step, stepIndex: Int) {
        // Fly pointer to focus
        let targetPoint: CGPoint
        if let f = step.focus, f.count == 2,
           DrawingPoint(x: f[1], y: f[0]).isValid {
            targetPoint = mapPoint(yNorm: f[0], xNorm: f[1])
        } else if let drawing = step.drawings?.first(where: { $0.isValid }), let anchor = drawing.anchor {
            targetPoint = CanvasMapper(size: displayFrame.size).point(anchor)
        } else if let firstAnnot = step.annotations?.first {
            targetPoint = anchorForAnnotation(firstAnnot)
        } else {
            targetPoint = pointer.position
        }

        flyPointer(to: targetPoint, label: step.annotations?.first?.label)
    }

    func showAnnotations(for step: Step, stepIndex: Int) {
        guard shownSteps.insert(stepIndex).inserted else { return }
        let planned = step.drawings ?? []
        let elements = planned.contains(where: \.isValid) ? planned :
            (step.annotations ?? []).compactMap(DrawingElement.legacy)
        guard !elements.isEmpty else { return }
        var stepLayers: [CALayer] = []
        let rendered = drawingRenderer.render(elements, mapper: CanvasMapper(size: displayFrame.size),
                                              backingScale: win.backingScaleFactor)
        for item in rendered {
            enforceLayerCap()
            root.layer?.insertSublayer(item.layer, below: pointer)
            stepLayers.append(item.layer)
            allActiveLayers.append(item.layer)
            if item.isSpotlight {
                activeStepSpotlights[stepIndex, default: []].append(item.layer)
            }
        }

        activeStepLayers[stepIndex] = (activeStepLayers[stepIndex] ?? []) + stepLayers
    }

    func finishStep(_ step: Step, stepIndex: Int, preserveAnnotations: Bool = false) {
        // Spotlights must never dim the next step, even when other annotations are kept.
        let spotlights = activeStepSpotlights.removeValue(forKey: stepIndex) ?? []
        for spotlight in spotlights {
            spotlight.removeFromSuperlayer()
            allActiveLayers.removeAll { $0 === spotlight }
        }
        if !spotlights.isEmpty {
            activeStepLayers[stepIndex]?.removeAll { layer in spotlights.contains { $0 === layer } }
        }
        guard !preserveAnnotations, step.keep != true else { return }
        // Fade out annotations 0.4s after step speech finishes
        let generation = presentationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.presentationGeneration == generation,
                  let layers = self.activeStepLayers.removeValue(forKey: stepIndex) else { return }
            self.allActiveLayers.removeAll { candidate in layers.contains { $0 === candidate } }
            self.fadeAndRemoveLayers(layers)
        }
    }

    func finishPresentation(done: @escaping () -> Void) {
        let generation = presentationGeneration
        fadeAndRemoveLayers(allActiveLayers)
        allActiveLayers.removeAll()
        activeStepLayers.removeAll()
        activeStepSpotlights.removeAll()
        if ProcessInfo.processInfo.environment["BUDDY_DRAW_DEBUG"] == "1" {
            blogDebug("[DRAWING] presentation finishing; layers cleared")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.hide()
            done()
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Pointer Flight
    // -------------------------------------------------------------------------

    private func flyPointer(to target: CGPoint, label: String?) {
        let current = pointer.position
        let dist = hypot(target.x - current.x, target.y - current.y)
        let duration = min(max(Double(dist) / 2500.0, 0.25), 0.60)

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        pointer.position = target
        CATransaction.commit()

        let cleanedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        setLabel(cleanedLabel)
    }

    private func anchorForAnnotation(_ a: Annotation) -> CGPoint {
        if let p = a.point, p.count >= 2 {
            return mapPoint(yNorm: p[0], xNorm: p[1])
        }
        if let b = a.box_2d, b.count >= 4 {
            let r = mapBox(b)
            return CGPoint(x: r.midX, y: r.midY)
        }
        if let pts = a.points, let first = pts.first, first.count >= 2 {
            return mapPoint(yNorm: first[0], xNorm: first[1])
        }
        return pointer.position
    }

    // -------------------------------------------------------------------------
    // MARK: Annotation Layer Factory
    // -------------------------------------------------------------------------

    private func fadeAndRemoveLayers(_ layers: [CALayer]) {
        for layer in layers {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.30)
            CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
            layer.opacity = 0
            CATransaction.commit()
        }
    }

    private func removeAllLayers() {
        for layer in allActiveLayers {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        allActiveLayers.removeAll()
        activeStepLayers.removeAll()
        activeStepSpotlights.removeAll()
        shownSteps.removeAll()
    }

    var activeDrawingCount: Int { allActiveLayers.count }
    var activeSpotlightCount: Int { activeStepSpotlights.values.reduce(0) { $0 + $1.count } }

    private func enforceLayerCap() {
        while allActiveLayers.count >= maxSimultaneousLayers {
            let oldest = allActiveLayers.removeFirst()
            oldest.removeAllAnimations()
            oldest.removeFromSuperlayer()
            for index in activeStepLayers.keys {
                activeStepLayers[index]?.removeAll { $0 === oldest }
            }
            for index in activeStepSpotlights.keys {
                activeStepSpotlights[index]?.removeAll { $0 === oldest }
            }
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Legacy Point Compatibility (Backward Compatibility)
    // -------------------------------------------------------------------------

    func point(_ pts: [Point], done: @escaping () -> Void) {
        let plan = Plan(steps: nil, actions: nil, say: "", points: pts)
        let steps = plan.normalizedSteps()
        let generation = presentationGeneration
        startStep(steps[0], stepIndex: 0)
        showAnnotations(for: steps[0], stepIndex: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.finishPresentation(done: done)
        }
    }
}
