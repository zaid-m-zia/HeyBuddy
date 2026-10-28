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
    private var allActiveLayers: [CALayer] = []

    // Stored display frame from the last capture (used for coordinate mapping)
    private var displayFrame: CGRect

    // Maximum simultaneous active annotation layers to prevent runaway GPU load
    private let maxSimultaneousLayers = 24

    init() {
        let f = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
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

        pointerLabel.fontSize        = 13
        pointerLabel.foregroundColor = NSColor.white.cgColor
        pointerLabel.backgroundColor = NSColor.black.withAlphaComponent(0.80).cgColor
        pointerLabel.cornerRadius    = 6
        pointerLabel.alignmentMode   = .center
        pointerLabel.truncationMode  = .end
        pointerLabel.contentsScale   = 2
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
        let w = displayFrame.width
        let h = displayFrame.height
        let clampedX = max(0.0, min(1000.0, xNorm))
        let clampedY = max(0.0, min(1000.0, yNorm))
        return CGPoint(
            x: (clampedX / 1000.0) * w,
            y: h - (clampedY / 1000.0) * h
        )
    }

    func mapBox(_ box: [Double]) -> CGRect {
        guard box.count >= 4 else { return .zero }
        let ymin = box[0], xmin = box[1], ymax = box[2], xmax = box[3]
        let pTopLeft = mapPoint(yNorm: ymin, xNorm: xmin)
        let pBottomRight = mapPoint(yNorm: ymax, xNorm: xmax)
        return CGRect(
            x: min(pTopLeft.x, pBottomRight.x),
            y: min(pTopLeft.y, pBottomRight.y),
            width: max(8, abs(pBottomRight.x - pTopLeft.x)),
            height: max(8, abs(pTopLeft.y - pBottomRight.y))
        )
    }

    // -------------------------------------------------------------------------
    // MARK: Display & Mode Management
    // -------------------------------------------------------------------------

    func setDisplayFrame(_ frame: CGRect) {
        displayFrame = frame
        win.setFrame(frame, display: false)
        root.frame = CGRect(origin: .zero, size: frame.size)
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
                self.pointer.position = CGPoint(x: localX + 16, y: localY - 4)
                CATransaction.commit()
            }
        }
        followTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func hide() {
        follow = false
        followTimer?.invalidate()
        followTimer = nil
        removeAllLayers()
        setLabel("")
        win.orderOut(nil)
        blogDebug("[OVERLAY] hidden")
    }

    func cancel() {
        removeAllLayers()
        hide()
    }

    func beginPresentation() {
        follow = false
        followTimer?.invalidate()
        followTimer = nil
        setLabel("")
        win.orderFrontRegardless()
    }

    // -------------------------------------------------------------------------
    // MARK: Presentation Step Lifecycle
    // -------------------------------------------------------------------------

    func startStep(_ step: Step, stepIndex: Int) {
        // Fly pointer to focus
        let targetPoint: CGPoint
        if let f = step.focus, f.count >= 2 {
            targetPoint = mapPoint(yNorm: f[0], xNorm: f[1])
        } else if let firstAnnot = step.annotations?.first {
            targetPoint = anchorForAnnotation(firstAnnot)
        } else {
            targetPoint = pointer.position
        }

        flyPointer(to: targetPoint, label: step.annotations?.first?.label)
    }

    func showAnnotations(for step: Step, stepIndex: Int) {
        guard let annotations = step.annotations, !annotations.isEmpty else { return }
        var stepLayers: [CALayer] = []

        for annot in annotations {
            if let layer = createAnnotationLayer(annot) {
                enforceLayerCap()
                root.layer?.insertSublayer(layer, below: pointer)
                stepLayers.append(layer)
                allActiveLayers.append(layer)
            }
        }

        activeStepLayers[stepIndex] = (activeStepLayers[stepIndex] ?? []) + stepLayers
    }

    func finishStep(_ step: Step, stepIndex: Int) {
        guard step.keep != true else { return }
        // Fade out annotations 0.4s after step speech finishes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let layers = self.activeStepLayers.removeValue(forKey: stepIndex) else { return }
            self.fadeAndRemoveLayers(layers)
        }
    }

    func finishPresentation(done: @escaping () -> Void) {
        fadeAndRemoveLayers(allActiveLayers)
        allActiveLayers.removeAll()
        activeStepLayers.removeAll()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
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

        if let lbl = label, !lbl.isEmpty {
            setLabel(lbl)
        }
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

    private func createAnnotationLayer(_ a: Annotation) -> CALayer? {
        let pink = NSColor.systemPink.cgColor
        let blue = NSColor.systemBlue.cgColor

        switch a.type.lowercased() {
        case "circle", "ellipse":
            guard let b = a.box_2d, b.count >= 4 else { return nil }
            let rect = mapBox(b)
            let layer = CAShapeLayer()
            layer.path = CGPath(ellipseIn: rect, transform: nil)
            styleStrokeLayer(layer, color: pink)
            animateStroke(layer)
            return layer

        case "rect":
            guard let b = a.box_2d, b.count >= 4 else { return nil }
            let rect = mapBox(b)
            let layer = CAShapeLayer()
            layer.path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
            styleStrokeLayer(layer, color: pink)
            animateStroke(layer)
            return layer

        case "arrow":
            guard let from = a.from, let to = a.to, from.count >= 2, to.count >= 2 else { return nil }
            let p1 = mapPoint(yNorm: from[0], xNorm: from[1])
            let p2 = mapPoint(yNorm: to[0], xNorm: to[1])
            let path = CGMutablePath()
            path.move(to: p1)
            path.addLine(to: p2)

            // Add arrowhead at p2
            let angle = atan2(p2.y - p1.y, p2.x - p1.x)
            let arrowLength: CGFloat = 16
            let arrowAngle: CGFloat = .pi / 6
            let left = CGPoint(x: p2.x - arrowLength * cos(angle - arrowAngle),
                               y: p2.y - arrowLength * sin(angle - arrowAngle))
            let right = CGPoint(x: p2.x - arrowLength * cos(angle + arrowAngle),
                                y: p2.y - arrowLength * sin(angle + arrowAngle))
            path.move(to: left)
            path.addLine(to: p2)
            path.addLine(to: right)

            let layer = CAShapeLayer()
            layer.path = path
            styleStrokeLayer(layer, color: pink)
            animateStroke(layer)
            return layer

        case "line", "polyline":
            guard let pts = a.points, pts.count >= 2 else { return nil }
            let path = CGMutablePath()
            for (i, p) in pts.enumerated() {
                guard p.count >= 2 else { continue }
                let pt = mapPoint(yNorm: p[0], xNorm: p[1])
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            let layer = CAShapeLayer()
            layer.path = path
            styleStrokeLayer(layer, color: pink)
            animateStroke(layer)
            return layer

        case "polygon":
            guard let pts = a.points, pts.count >= 3 else { return nil }
            let path = CGMutablePath()
            for (i, p) in pts.enumerated() {
                guard p.count >= 2 else { continue }
                let pt = mapPoint(yNorm: p[0], xNorm: p[1])
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            path.closeSubpath()
            let layer = CAShapeLayer()
            layer.path = path
            layer.fillColor = NSColor.systemPink.withAlphaComponent(0.12).cgColor
            styleStrokeLayer(layer, color: pink)
            animateStroke(layer)
            return layer

        case "underline":
            guard let b = a.box_2d, b.count >= 4 else { return nil }
            let rect = mapBox(b)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY - 2))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY - 2))
            let layer = CAShapeLayer()
            layer.path = path
            styleStrokeLayer(layer, color: pink)
            animateStroke(layer)
            return layer

        case "highlight":
            guard let b = a.box_2d, b.count >= 4 else { return nil }
            let rect = mapBox(b)
            let layer = CALayer()
            layer.frame = rect
            layer.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.30).cgColor
            layer.cornerRadius = 6
            animateFadeIn(layer)
            return layer

        case "spotlight":
            guard let b = a.box_2d, b.count >= 4 else { return nil }
            let rect = mapBox(b)
            let fullRect = CGRect(origin: .zero, size: displayFrame.size)

            let maskPath = CGMutablePath()
            maskPath.addRect(fullRect)
            maskPath.addRoundedRect(in: rect, cornerWidth: 10, cornerHeight: 10)

            let layer = CAShapeLayer()
            layer.frame = fullRect
            layer.path = maskPath
            layer.fillRule = .evenOdd
            layer.fillColor = NSColor.black.withAlphaComponent(0.65).cgColor
            animateFadeIn(layer)
            return layer

        case "badge":
            guard let p = a.point, p.count >= 2 else { return nil }
            let pt = mapPoint(yNorm: p[0], xNorm: p[1])
            let text = a.text ?? a.label ?? "•"

            let container = CALayer()
            container.frame = CGRect(x: pt.x - 14, y: pt.y - 14, width: 28, height: 28)
            container.backgroundColor = pink
            container.cornerRadius = 14
            container.shadowColor = pink
            container.shadowOpacity = 0.8
            container.shadowRadius = 4
            container.shadowOffset = .zero

            let textLayer = CATextLayer()
            textLayer.string = text
            textLayer.fontSize = 14
            textLayer.alignmentMode = .center
            textLayer.foregroundColor = NSColor.white.cgColor
            textLayer.contentsScale = 2
            textLayer.frame = CGRect(x: 0, y: 4, width: 28, height: 20)
            container.addSublayer(textLayer)

            animatePop(container)
            return container

        case "label":
            guard let p = a.point, p.count >= 2 else { return nil }
            let pt = mapPoint(yNorm: p[0], xNorm: p[1])
            let text = a.text ?? a.label ?? ""
            let w = min(CGFloat(text.count) * 8.5 + 24, 320)
            let h: CGFloat = 26

            // Clamp bubble inside screen
            let clampedX = min(max(pt.x - w / 2, 10), displayFrame.width - w - 10)
            let clampedY = min(max(pt.y + 12, 10), displayFrame.height - h - 10)

            let container = CALayer()
            container.frame = CGRect(x: clampedX, y: clampedY, width: w, height: h)
            container.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
            container.cornerRadius = 8
            container.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
            container.borderWidth = 1

            let textLayer = CATextLayer()
            textLayer.string = text
            textLayer.fontSize = 12
            textLayer.alignmentMode = .center
            textLayer.foregroundColor = NSColor.white.cgColor
            textLayer.contentsScale = 2
            textLayer.frame = CGRect(x: 4, y: 5, width: w - 8, height: 16)
            container.addSublayer(textLayer)

            animatePop(container)
            return container

        case "pointer":
            // Standard pointer target circle
            guard let p = a.point, p.count >= 2 else { return nil }
            let pt = mapPoint(yNorm: p[0], xNorm: p[1])
            let layer = CAShapeLayer()
            layer.path = CGPath(ellipseIn: CGRect(x: pt.x - 24, y: pt.y - 24, width: 48, height: 48), transform: nil)
            styleStrokeLayer(layer, color: blue)
            animateStroke(layer)
            return layer

        default:
            return nil
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Styling & Animations
    // -------------------------------------------------------------------------

    private func styleStrokeLayer(_ layer: CAShapeLayer, color: CGColor) {
        layer.fillColor = layer.fillColor ?? nil
        layer.strokeColor = color
        layer.lineWidth = 4
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.shadowColor = color
        layer.shadowRadius = 4
        layer.shadowOpacity = 0.8
        layer.shadowOffset = .zero
    }

    private func animateStroke(_ layer: CAShapeLayer) {
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 0.0
        anim.toValue = 1.0
        anim.duration = 0.35
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "stroke")
    }

    private func animateFadeIn(_ layer: CALayer) {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.0
        anim.toValue = 1.0
        anim.duration = 0.35
        layer.add(anim, forKey: "fade")
    }

    private func animatePop(_ layer: CALayer) {
        let anim = CASpringAnimation(keyPath: "transform.scale")
        anim.fromValue = 0.4
        anim.toValue = 1.0
        anim.damping = 12
        anim.initialVelocity = 4
        anim.duration = anim.settlingDuration
        layer.add(anim, forKey: "pop")
    }

    private func fadeAndRemoveLayers(_ layers: [CALayer]) {
        for l in layers {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setCompletionBlock {
                l.removeFromSuperlayer()
            }
            l.opacity = 0.0
            CATransaction.commit()
        }
    }

    private func removeAllLayers() {
        for l in allActiveLayers {
            l.removeFromSuperlayer()
        }
        allActiveLayers.removeAll()
        activeStepLayers.removeAll()
    }

    private func enforceLayerCap() {
        while allActiveLayers.count >= maxSimultaneousLayers {
            let oldest = allActiveLayers.removeFirst()
            oldest.removeFromSuperlayer()
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Legacy Point Compatibility (Backward Compatibility)
    // -------------------------------------------------------------------------

    func point(_ pts: [Point], done: @escaping () -> Void) {
        let plan = Plan(say: "", points: pts)
        let steps = plan.normalizedSteps()
        startStep(steps[0], stepIndex: 0)
        showAnnotations(for: steps[0], stepIndex: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.finishPresentation(done: done)
        }
    }
}
