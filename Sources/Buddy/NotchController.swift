import AppKit
import CoreGraphics
import QuartzCore

/// Window geometry is in AppKit screen points. The physical camera cutout uses
/// the top safe-area depth; visible content lives in the short band below it.
struct NotchGeometry {
    let screenFrame: NSRect
    let centerX: CGFloat
    let notchWidth: CGFloat?
    let safeAreaTop: CGFloat

    var notchDepth: CGFloat {
        guard let notchWidth, notchWidth > 0 else { return 0 }
        return max(0, safeAreaTop)
    }

    var compactSize: NSSize {
        let width = min(screenFrame.width - 40, max(180, min(260, (notchWidth ?? 0) + 28)))
        return NSSize(width: width, height: notchDepth + (notchDepth > 0 ? 24 : 31))
    }

    var expandedSize: NSSize {
        let width = min(600, screenFrame.width * 0.60, screenFrame.width - 48,
                        max(490, compactSize.width * 2.45))
        return NSSize(width: width, height: notchDepth + (notchDepth > 0 ? 32 : 42))
    }

    func frame(expanded: Bool) -> NSRect {
        let size = expanded ? expandedSize : compactSize
        return NSRect(x: centerX - size.width / 2,
                      y: screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }
}

@MainActor
final class NotchController: NSObject {
    private var visibility = NotchVisibility()
    private var panel: NSPanel?
    private var content: NotchContentView?
    private var screenObserver: NSObjectProtocol?
    private var hideWork: DispatchWorkItem?
    private var dismissalWork: DispatchWorkItem?
    private var hoverExitWork: DispatchWorkItem?
    private var stateText = "Listening"
    private var errorText: String?

    var onStop: (() -> Void)?
    var onReplay: (() -> Void)?
    var onSettings: (() -> Void)?
    var history: (() -> [String])?

    override init() {
        super.init()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reposition() }
        }
    }

    func activate() {
        cancelPendingHide()
        cancelPendingHoverExit()
        visibility.activate()
        errorText = nil
        stateText = "Listening"
        guard let screen = builtinScreen() else {
            hidePanel()
            return
        }
        ensurePanel(on: screen)
        guard let panel, let content else { return }
        let geometry = geometry(on: screen)
        let startFrame = geometry.frame(expanded: false)
        panel.setFrame(startFrame, display: true)
        content.notchDepth = geometry.notchDepth
        content.update(state: stateText, error: nil, expanded: false, clickable: true)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        content.revealFace(reduceMotion: reduceMotion)
    }

    func update(_ state: AppState, error: String? = nil) {
        guard visibility.phase == .active else { return }
        switch state {
        case .listening: stateText = "Listening"
        case .processing: stateText = "Thinking"
        case .presenting: stateText = "Speaking"
        case .confirming: stateText = "Waiting for approval"
        case .idle: return
        }
        errorText = error.map { String($0.prefix(110)) }
        content?.update(state: stateText, error: errorText,
                        expanded: visibility.expanded, clickable: visibility.clickable)
    }

    func complete(error: String? = nil, status: String? = nil) {
        guard visibility.phase == .active else { return }
        stateText = status ?? (error == nil ? "Done" : "Error")
        errorText = error.map { String($0.prefix(110)) }
        content?.update(state: stateText, error: errorText,
                        expanded: visibility.expanded, clickable: true)
        let token = visibility.complete()
        scheduleHide(token: token)
    }

    func extendGrace(by seconds: TimeInterval = 2.5) {
        guard visibility.phase == .grace else { return }
        hideWork?.cancel()
        scheduleHide(token: visibility.generation, delay: seconds)
    }

    func shutdown() {
        cancelPendingHide()
        cancelPendingHoverExit()
        visibility.shutdown()
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
        screenObserver = nil
        hidePanel()
        panel?.close()
        panel = nil
        content = nil
    }

    /// A deterministic preview; hover the compact notch to test expansion. No network call.
    func preview() {
        activate()
        let token = visibility.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.visibility.generation == token else { return }
            self.update(.processing)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.visibility.generation == token else { return }
            self.update(.presenting)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, self.visibility.generation == token else { return }
            self.complete()
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func builtinScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
    }

    private func geometry(on screen: NSScreen) -> NotchGeometry {
        let centerX: CGFloat
        var notchWidth: CGFloat?
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           !left.isEmpty, !right.isEmpty,
           right.minX > left.maxX {
            centerX = (left.maxX + right.minX) / 2
            notchWidth = right.minX - left.maxX
        } else {
            centerX = screen.frame.midX
        }
        return NotchGeometry(screenFrame: screen.frame, centerX: centerX,
                             notchWidth: notchWidth, safeAreaTop: screen.safeAreaInsets.top)
    }

    private func ensurePanel(on screen: NSScreen) {
        if panel != nil { return }
        let geometry = geometry(on: screen)
        let frame = geometry.frame(expanded: false)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false, screen: screen)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let view = NotchContentView(frame: NSRect(origin: .zero, size: frame.size))
        view.notchDepth = geometry.notchDepth
        view.onHoverChanged = { [weak self] inside in self?.hoverChanged(inside) }
        view.onStop = { [weak self] in self?.onStop?() }
        view.onReplay = { [weak self] in self?.onReplay?() }
        view.onSettings = { [weak self] in self?.showSettings() }
        view.onStatus = { [weak self] in self?.showStatus() }
        view.onHistory = { [weak self] in self?.showHistory() }
        window.contentView = view
        panel = window
        content = view
    }

    private func resize(expanded: Bool, on screen: NSScreen, duration: TimeInterval) {
        guard let panel else { return }
        let frame = geometry(on: screen).frame(expanded: expanded)
        if reduceMotion { panel.setFrame(frame, display: true); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func reposition() {
        guard let panel else { return }
        guard let screen = builtinScreen() else { hidePanel(); return }
        if visibility.visible {
            let geometry = geometry(on: screen)
            content?.notchDepth = geometry.notchDepth
            panel.setFrame(geometry.frame(expanded: visibility.expanded), display: true)
            panel.ignoresMouseEvents = !visibility.clickable
            panel.orderFrontRegardless()
        }
    }

    private func hoverChanged(_ isInside: Bool) {
        guard visibility.clickable else { return }
        if isInside {
            cancelPendingHoverExit()
            setHovered(true)
        } else if visibility.expanded {
            // AppKit may report a transient exit while the panel's animated frame
            // and its in-visible-rect tracking area are changing size.
            hoverExitWork?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hoverExitWork = nil
                guard let screen = self.builtinScreen() else { return }
                let expandedFrame = self.geometry(on: screen).frame(expanded: true)
                guard !expandedFrame.contains(NSEvent.mouseLocation) else { return }
                self.setHovered(false)
            }
            hoverExitWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: item)
        }
    }

    private func setHovered(_ isHovered: Bool) {
        guard visibility.setHovered(isHovered), let screen = builtinScreen() else { return }
        content?.update(state: stateText, error: errorText,
                        expanded: visibility.expanded, clickable: visibility.clickable)
        resize(expanded: visibility.expanded, on: screen, duration: 0.28)
    }

    private func scheduleHide(token: Int, delay: TimeInterval = 2.5) {
        hideWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.visibility.beginDismissal(ifGeneration: token) else { return }
            self.panel?.ignoresMouseEvents = true
            self.content?.update(state: self.stateText, error: self.errorText,
                                 expanded: false, clickable: false)
            self.content?.hideFace(reduceMotion: self.reduceMotion)
            if let screen = self.builtinScreen() {
                self.resize(expanded: false, on: screen, duration: 0.2)
            }
            let end = DispatchWorkItem { [weak self] in
                guard let self, self.visibility.finishDismissal(ifGeneration: token) else { return }
                self.hidePanel()
            }
            self.dismissalWork = end
            DispatchQueue.main.asyncAfter(deadline: .now() + (self.reduceMotion ? 0 : 0.25), execute: end)
        }
        hideWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelPendingHide() {
        hideWork?.cancel()
        hideWork = nil
        dismissalWork?.cancel()
        dismissalWork = nil
    }

    private func cancelPendingHoverExit() {
        hoverExitWork?.cancel()
        hoverExitWork = nil
    }

    private func hidePanel() {
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
    }

    private func showStatus() {
        guard visibility.clickable else { return }
        hideWork?.cancel()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "HeyBuddy status: \(stateText)"
        alert.informativeText = errorText ?? "The assistant is \(stateText.lowercased())."
        alert.runModal()
        if visibility.phase == .grace { scheduleHide(token: visibility.generation) }
    }

    private func showHistory() {
        guard visibility.clickable else { return }
        hideWork?.cancel()
        NSApp.activate(ignoringOtherApps: true)
        let items = history?() ?? []
        let alert = NSAlert()
        alert.messageText = "Recent responses"
        alert.informativeText = items.isEmpty ? "No recent responses yet." : items.joined(separator: "\n\n")
        alert.runModal()
        if visibility.phase == .grace { scheduleHide(token: visibility.generation) }
    }

    private func showSettings() {
        guard visibility.clickable else { return }
        hideWork?.cancel()
        onSettings?()
        if visibility.phase == .grace { scheduleHide(token: visibility.generation) }
    }
}

@MainActor
private final class NotchContentView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onStop: (() -> Void)?
    var onReplay: (() -> Void)?
    var onStatus: (() -> Void)?
    var onSettings: (() -> Void)?
    var onHistory: (() -> Void)?

    private let face = NotchFaceView(frame: NSRect(x: 10, y: 8, width: 25, height: 25))
    private let stateLabel = NSTextField(labelWithString: "Listening")
    private var controls: [NSButton] = []
    private var expanded = false
    private var clickable = false
    var notchDepth: CGFloat = 0 { didSet { needsLayout = true } }
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.025, green: 0.03, blue: 0.045, alpha: 0.98).cgColor
        layer?.cornerCurve = .continuous
        addSubview(face)
        stateLabel.textColor = .white
        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.lineBreakMode = .byTruncatingTail
        addSubview(stateLabel)
        for (title, action) in [("Stop", #selector(stopAction)), ("Replay", #selector(replayAction)),
                                ("Status", #selector(statusAction)), ("Settings", #selector(settingsAction)),
                                ("Recent", #selector(historyAction))] {
            let button = NSButton(title: title, target: self, action: action)
            button.isBordered = false
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.contentTintColor = .white
            addSubview(button)
            controls.append(button)
        }
        update(state: "Listening", error: nil, expanded: false, clickable: false)
    }

    required init?(coder: NSCoder) { return nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverTrackingArea == nil else { return }
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTrackingArea = tracking
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func layout() {
        super.layout()
        let visibleHeight = max(24, bounds.height - notchDepth)
        // A smaller radius closes the visible gaps at the camera notch's shoulders.
        layer?.cornerRadius = min(7, bounds.height / 2)
        layer?.masksToBounds = true
        face.frame = NSRect(x: 12, y: (visibleHeight - 24) / 2, width: 24, height: 24)
        stateLabel.frame = NSRect(x: 44, y: (visibleHeight - 16) / 2,
                                  width: expanded ? 105 : max(0, bounds.width - 52), height: 16)
        var x: CGFloat = 155
        for (button, width) in zip(controls, [50.0, 58.0, 53.0, 63.0, 55.0]) {
            button.frame = NSRect(x: x, y: (visibleHeight - 26) / 2, width: width, height: 26)
            x += width + 8
        }
    }

    func update(state: String, error: String?, expanded: Bool, clickable: Bool) {
        self.expanded = expanded
        self.clickable = clickable
        stateLabel.stringValue = state
        stateLabel.toolTip = error
        face.expression = state
        controls.forEach { $0.isHidden = !expanded || !clickable }
        needsLayout = true
    }

    func revealFace(reduceMotion: Bool) {
        face.layer?.removeAllAnimations()
        face.alphaValue = 1
        guard !reduceMotion else { return }
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = -15
        move.toValue = 0
        move.duration = 0.30
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        face.layer?.add(move, forKey: "rise")
    }

    func hideFace(reduceMotion: Bool) {
        face.layer?.removeAllAnimations()
        if reduceMotion { face.alphaValue = 0; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            face.animator().alphaValue = 0
        }
    }

    @objc private func stopAction() { if clickable { onStop?() } }
    @objc private func replayAction() { if clickable { onReplay?() } }
    @objc private func statusAction() { if clickable { onStatus?() } }
    @objc private func settingsAction() { if clickable { onSettings?() } }
    @objc private func historyAction() { if clickable { onHistory?() } }
}

@MainActor
private final class NotchFaceView: NSView {
    var expression = "Listening" { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let blue = NSColor(srgbRed: 0.14, green: 0.68, blue: 1, alpha: 1)
        blue.setStroke()
        let rim = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        rim.lineWidth = 1.8
        rim.stroke()
        for x in [bounds.midX - 4.5, bounds.midX + 4.5] {
            let eye = NSBezierPath(ovalIn: NSRect(x: x - 1.2, y: bounds.midY + 2, width: 2.4, height: 2.4))
            blue.setFill()
            eye.fill()
        }
        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: bounds.midX - 5, y: bounds.midY - 3))
        if expression == "Thinking" {
            mouth.line(to: NSPoint(x: bounds.midX + 5, y: bounds.midY - 3))
        } else {
            mouth.curve(to: NSPoint(x: bounds.midX + 5, y: bounds.midY - 3),
                        controlPoint1: NSPoint(x: bounds.midX - 2, y: bounds.midY - 7),
                        controlPoint2: NSPoint(x: bounds.midX + 2, y: bounds.midY - 7))
        }
        mouth.lineWidth = 1.7
        mouth.lineCapStyle = .round
        mouth.stroke()
    }
}
