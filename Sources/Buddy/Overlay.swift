import AppKit

final class Overlay {
    let win: NSPanel
    let root = NSView()
    let pointer = CALayer()
    let label = CATextLayer()
    var follow = false
    var timer: Timer?
    var hideItem: DispatchWorkItem?

    init() {
        let f = NSScreen.main!.frame
        win = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        root.frame = NSRect(origin: .zero, size: f.size)
        root.wantsLayer = true
        win.contentView = root

        let tri = CAShapeLayer()
        let p = CGMutablePath()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: 4, y: -22))
        p.addLine(to: CGPoint(x: 16, y: -13))
        p.closeSubpath()
        tri.path = p
        tri.fillColor = NSColor.systemBlue.cgColor
        tri.strokeColor = NSColor.white.cgColor
        tri.lineWidth = 1.5
        tri.shadowColor = NSColor.systemBlue.cgColor
        tri.shadowOpacity = 0.9
        tri.shadowRadius = 6
        tri.shadowOffset = .zero

        label.fontSize = 13
        label.foregroundColor = NSColor.white.cgColor
        label.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        label.cornerRadius = 6
        label.alignmentMode = .center
        label.truncationMode = .end
        label.contentsScale = 2
        pointer.addSublayer(tri)
        pointer.addSublayer(label)
        root.layer!.addSublayer(pointer)
    }

    func setLabel(_ s: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.isHidden = s.isEmpty
        label.string = s
        label.frame = CGRect(x: 18, y: -46, width: min(CGFloat(s.count) * 8 + 18, 360), height: 22)
        CATransaction.commit()
    }

    /// Animated cursor follows the real cursor.
    func show(_ s: String) {
        hideItem?.cancel()
        follow = true
        setLabel(s)
        win.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, self.follow else { return }
            let m = NSEvent.mouseLocation
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.pointer.position = CGPoint(x: m.x + 16, y: m.y - 4)
            CATransaction.commit()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func hide() {
        follow = false
        timer?.invalidate()
        win.orderOut(nil)
    }

    /// Fly to each point in order, ring it, show its label, then return to following the cursor.
    func point(_ pts: [Point], done: @escaping () -> Void) {
        follow = false
        step(pts, 0, done)
    }

    private func step(_ pts: [Point], _ i: Int, _ done: @escaping () -> Void) {
        guard i < pts.count else { finish(done); return }
        let s = NSScreen.main!.frame.size
        let p = pts[i]
        let target = CGPoint(x: min(max(p.x, 0), 1000) / 1000 * s.width,
                             y: s.height - min(max(p.y, 0), 1000) / 1000 * s.height)
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
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideItem = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }

    private func ring(at p: CGPoint) {
        let r = CAShapeLayer()
        r.path = CGPath(ellipseIn: CGRect(x: -28, y: -28, width: 56, height: 56), transform: nil)
        r.position = p
        r.fillColor = nil
        r.strokeColor = NSColor.systemBlue.cgColor
        r.lineWidth = 3
        root.layer!.insertSublayer(r, below: pointer)
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 0.3; a.toValue = 1; a.duration = 0.35
        r.add(a, forKey: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { r.removeFromSuperlayer() }
    }
}
