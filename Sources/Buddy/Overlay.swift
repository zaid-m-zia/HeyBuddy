// Overlay.swift
// Stages 1, 8 – Full-screen transparent panel with animated cursor, rings, labels.
//
// Changes from original:
//   - NSScreen.main! force-unwraps removed. Overlay now accepts a display frame
//     from Screen.capture() so it maps to the same display the screenshot used.
//   - Coordinate mapping documented: model uses (0-1000, 0-1000) top-left origin;
//     AppKit uses bottom-left origin. Conversion: x_ak = x/1000*w, y_ak = h - y/1000*h.
//   - Ring layers are tracked and removed when the next point starts or hide() fires,
//     so they never accumulate.
//   - hide() explicitly removes all ring sublayers and stops the follow timer.
//   - cancel() stops any in-flight point animation immediately and calls hide().

import AppKit

@MainActor
final class Overlay {
    let win: NSPanel
    let root = NSView()
    let pointer = CALayer()
    let label = CATextLayer()
    var followTimer: Timer?
    var follow = false
    var hideWorkItem: DispatchWorkItem?

    // Track active ring layers so we can remove them on demand.
    private var activeRings: [CAShapeLayer] = []

    // Stored display frame from the last capture (used for coordinate mapping).
    // Defaults to main screen so the overlay is never nil-sized before first capture.
    private var displayFrame: CGRect

    init() {
        let f = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        displayFrame = f

        win = NSPanel(contentRect: f,
                      styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered,
                      defer: false)
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        root.frame = CGRect(origin: .zero, size: f.size)
        root.wantsLayer = true
        win.contentView = root

        // Cursor triangle.
        let tri = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 4, y: -22))
        path.addLine(to: CGPoint(x: 16, y: -13))
        path.closeSubpath()
        tri.path = path
        tri.fillColor   = NSColor.systemBlue.cgColor
        tri.strokeColor = NSColor.white.cgColor
        tri.lineWidth   = 1.5
        tri.shadowColor   = NSColor.systemBlue.cgColor
        tri.shadowOpacity = 0.9
        tri.shadowRadius  = 6
        tri.shadowOffset  = .zero

        label.fontSize        = 13
        label.foregroundColor = NSColor.white.cgColor
        label.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        label.cornerRadius    = 6
        label.alignmentMode   = .center
        label.truncationMode  = .end
        label.contentsScale   = 2

        pointer.addSublayer(tri)
        pointer.addSublayer(label)
        root.layer?.addSublayer(pointer)
    }

    // -------------------------------------------------------------------------
    // MARK: Update the capture-display frame (called by AppDelegate on each capture)
    // -------------------------------------------------------------------------

    func setDisplayFrame(_ frame: CGRect) {
        displayFrame = frame
        // Resize the window to match this display.
        win.setFrame(frame, display: false)
        root.frame = CGRect(origin: .zero, size: frame.size)
    }

    // -------------------------------------------------------------------------
    // MARK: Label
    // -------------------------------------------------------------------------

    func setLabel(_ s: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.isHidden = s.isEmpty
        label.string   = s
        label.frame    = CGRect(x: 18, y: -46, width: min(CGFloat(s.count) * 8 + 18, 360), height: 22)
        CATransaction.commit()
    }

    // -------------------------------------------------------------------------
    // MARK: Show – cursor follows the real mouse
    // -------------------------------------------------------------------------

    func show(_ s: String) {
        hideWorkItem?.cancel()
        follow = true
        setLabel(s)
        win.orderFrontRegardless()
        followTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.follow else { return }
                let m = NSEvent.mouseLocation
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.pointer.position = CGPoint(x: m.x + 16, y: m.y - 4)
                CATransaction.commit()
            }
        }
        followTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    // -------------------------------------------------------------------------
    // MARK: Hide
    // -------------------------------------------------------------------------

    func hide() {
        follow = false
        followTimer?.invalidate()
        followTimer = nil
        removeAllRings()
        setLabel("")
        win.orderOut(nil)
        blogDebug("[OVERLAY] hidden")
    }

    // -------------------------------------------------------------------------
    // MARK: Cancel in-flight animation
    // -------------------------------------------------------------------------

    /// Immediately stops any point animation and hides the overlay.
    func cancel() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        hide()
    }

    // -------------------------------------------------------------------------
    // MARK: Fly to points
    // -------------------------------------------------------------------------

    func point(_ pts: [Point], done: @escaping () -> Void) {
        follow = false
        step(pts, 0, done)
    }

    private func step(_ pts: [Point], _ i: Int, _ done: @escaping () -> Void) {
        guard i < pts.count else { finish(done); return }

        // Remove rings from the previous stop before flying to the next.
        removeAllRings()

        let s = displayFrame.size
        let p = pts[i]
        // Coordinate mapping:
        // Model grid: (0,0)=top-left, (1000,1000)=bottom-right.
        // AppKit: origin = bottom-left of screen, y increases upward.
        // So: x_appkit = (x/1000) * width
        //     y_appkit = height - (y/1000) * height
        let target = CGPoint(
            x: min(max(p.x, 0), 1000) / 1000.0 * s.width,
            y: s.height - min(max(p.y, 0), 1000) / 1000.0 * s.height
        )
        setLabel(p.label ?? "")

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        pointer.position = target
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.ring(at: target) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in self?.step(pts, i + 1, done) }
    }

    private func finish(_ done: @escaping () -> Void) {
        setLabel("")
        follow = true
        done()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: item)
    }

    // -------------------------------------------------------------------------
    // MARK: Ring animation
    // -------------------------------------------------------------------------

    private func ring(at p: CGPoint) {
        let r = CAShapeLayer()
        r.path = CGPath(ellipseIn: CGRect(x: -28, y: -28, width: 56, height: 56), transform: nil)
        r.position    = p
        r.fillColor   = nil
        r.strokeColor = NSColor.systemBlue.cgColor
        r.lineWidth   = 3
        root.layer?.insertSublayer(r, below: pointer)
        activeRings.append(r)

        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 0.3
        anim.toValue   = 1
        anim.duration  = 0.35
        r.add(anim, forKey: nil)
    }

    private func removeAllRings() {
        activeRings.forEach { $0.removeFromSuperlayer() }
        activeRings.removeAll()
    }
}
