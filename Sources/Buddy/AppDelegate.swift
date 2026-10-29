// AppDelegate.swift
// Stages 0, 1, 2, 3, 5, 7, 9 – Menu-bar app orchestration.
//
// Key changes from original:
//   STAGE 0:  Fixed missing closing brace that nested requestPermissions inside onboard().
//             requestPermissions() is now a proper top-level method called on every launch.
//   STAGE 1:  All state transitions and entry points logged.
//   STAGE 2:  holding+busy Booleans replaced by a single @MainActor State enum.
//             One central finish() that every exit path calls (via defer).
//             30-second watchdog timer cancels stuck processing/presenting.
//             Control+Option during processing/presenting interrupts and restarts.
//   STAGE 3:  Both global AND local .flagsChanged monitors registered and stored.
//             Monitors removed on applicationWillTerminate.
//             Start when Ctrl+Opt both down; stop when EITHER is released.
//             Path timer created in .common run-loop mode.
//   STAGE 5:  Screenshot task starts at key PRESS (parallel with speech).
//             Overlay updates to use the capture display frame.
//   STAGE 7:  Shell/AppleScript actions run on a background queue (never main thread).
//             Exit status checked; stderr captured separately.
//             Per-action 30 s timeout.
//   STAGE 9:  Permissions checked at launch AND before each listen session.
//             Clear spoken+overlay message for any missing permission,
//             with a button that opens System Settings.

import AppKit
import AVFoundation
import Speech
import ApplicationServices

// ---------------------------------------------------------------------------
// MARK: - State machine (Stage 2)
// ---------------------------------------------------------------------------

/// Every valid app state. Only AppDelegate mutates this, always on the main actor.
@MainActor
enum AppState: Equatable {
    case idle
    case listening   // engine running, path being sampled
    case processing  // transcript ready, screenshot + network in flight
    case presenting  // overlay flying to points / TTS speaking
    case confirming  // action confirmation dialog visible
}

// ---------------------------------------------------------------------------
// MARK: - AppDelegate
// ---------------------------------------------------------------------------

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Subsystems
    let overlay = Overlay()
    let ears    = Ears()
    let brain   = Brain()
    let voice   = AVSpeechSynthesizer()
    lazy var player = PresentationPlayer(overlay: overlay)
    private var drawingDemo: DrawingDemoController?
    private var notch: NotchController?
    private var lastSpokenResponse: String?
    private var lastPresentationSteps: [Step]?
    private var notchError: String?

    // MARK: UI
    var statusItem: NSStatusItem!

    // MARK: State (Stage 2)
    private var state: AppState = .idle {
        didSet {
            guard oldValue != state else { return }
            blogInfo("[STATE] \(oldValue) → \(state)")
            notch?.update(state)
        }
    }

    // MARK: Hotkey monitors (Stage 3)
    private var globalMonitor: Any?
    private var localMonitor:  Any?

    // MARK: In-flight request (Stage 2)
    private var requestTask: Task<Void, Never>?
    private var interactionGeneration = 0

    // MARK: Concurrent screenshot task (Stage 5)
    private var screenshotTask: Task<CaptureResult, Error>?

    // MARK: Watchdog (Stage 2)
    private var watchdog: DispatchWorkItem?

    // MARK: Cursor path (Stage 3)
    private var path: [CGPoint] = []
    private var pathTimer: Timer?

    // -------------------------------------------------------------------------
    // MARK: - Application lifecycle
    // -------------------------------------------------------------------------

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        let notch = NotchController()
        notch.onStop = { [weak self] in self?.stopFromNotch() }
        notch.onReplay = { [weak self] in self?.replayFromNotch() }
        notch.onSettings = { [weak self] in self?.openSettings() }
        notch.history = { [weak self] in self?.recentResponses() ?? [] }
        self.notch = notch

        // Stage 2: Initialize settings from memory/UserDefaults (silently migrate Keychain without prompting).
        Settings.initialize()

        // Prompting permission calls happen once at first launch/onboarding or via "Fix permissions" menu item.
        let initialPerms = currentPermissions()
        if initialPerms.mic == "notDetermined" || initialPerms.speech == "notDetermined" {
            requestPermissions()
        }

        // Onboard if name or API key is missing.
        if Settings.name.isEmpty || Settings.apiKey.isEmpty { onboard() }

        // Log permission state at launch (Stage 1).
        let perms = currentPermissions()
        blogInfo("[LAUNCH] permissions: \(perms)")

        // Stage 3: register BOTH monitors and store them to prevent ARC release.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            Task { @MainActor [weak self] in self?.flags(e) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            Task { @MainActor [weak self] in self?.flags(e) }
            return e
        }

        // Discovery runs on the first request or an explicit health check.
    }

    func applicationWillTerminate(_ notification: Notification) {
        notch?.shutdown()
        drawingDemo?.stop()
        // Stage 3: always remove monitors to prevent stale callbacks after relaunch.
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor  { NSEvent.removeMonitor(m) }
    }

    // -------------------------------------------------------------------------
    // MARK: - Menu bar
    // -------------------------------------------------------------------------

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◎"
        let menu = NSMenu()

        let t = menu.addItem(withTitle: "Health Check…", action: #selector(testAPI), keyEquivalent: "t")
        t.target = self

        let c = menu.addItem(withTitle: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        c.target = self

        let d = menu.addItem(withTitle: "Drawing Demo…", action: #selector(demoAnnotations), keyEquivalent: "d")
        d.target = self

        let n = menu.addItem(withTitle: "Notch Preview…", action: #selector(previewNotch), keyEquivalent: "")
        n.target = self

        let p = menu.addItem(withTitle: "Fix Permissions…", action: #selector(fixPermissions), keyEquivalent: "")
        p.target = self

        menu.addItem(NSMenuItem.separator())

        let s = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        s.target = self

        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func openSettings() { onboard() }

    @objc func fixPermissions() {
        requestPermissions()
        let perms = currentPermissions()
        blogInfo("[PERMS] manual fix triggered: \(perms)")
    }

    @objc func testAPI() {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let report = try await self.brain.healthCheck()
                let alert = NSAlert()
                alert.messageText = "Gemini Health Check"
                alert.informativeText = report
                alert.addButton(withTitle: "Done")
                alert.addButton(withTitle: "Test one generation")
                if alert.runModal() == .alertSecondButtonReturn {
                    let result = try await self.brain.testGeneration()
                    let resultAlert = NSAlert()
                    resultAlert.messageText = "Generation Test"
                    resultAlert.informativeText = result
                    resultAlert.runModal()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Gemini Health Check Failed"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(brain.diagnostics, forType: .string)
    }

    @objc func demoAnnotations() {
        guard state == .idle else { return }
        drawingDemo?.stop()
        let demo = DrawingDemoController()
        drawingDemo = demo
        demo.show()
    }

    @objc private func previewNotch() {
        guard state == .idle else { return }
        notch?.preview()
    }

    // -------------------------------------------------------------------------
    // MARK: - Onboarding (Stage 0 – brace fix applied here)
    // -------------------------------------------------------------------------

    func onboard() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText    = "Set up your buddy"
        alert.informativeText = "Name your assistant, and paste a free Gemini API key from aistudio.google.com/apikey"

        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        nameField.placeholderString = "Assistant name (e.g. Nova)"
        nameField.stringValue = Settings.name

        let keyField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        keyField.placeholderString = "Gemini API key"
        keyField.stringValue = Settings.apiKey

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        container.addSubview(nameField)
        container.addSubview(keyField)
        alert.accessoryView = container
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Save & Test Connection")

        let choice = alert.runModal()
        if choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn {
            do {
                try Settings.saveAPIKey(keyField.stringValue)
                Settings.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
                blogInfo("[SETTINGS] updated name; API key saved")
                if choice == .alertSecondButtonReturn { testAPI() }
            } catch {
                let badKey = NSAlert()
                badKey.messageText = "Check the Gemini API key"
                badKey.informativeText = "Paste the key from Google AI Studio without spaces or extra text."
                badKey.runModal()
            }
        }
    }   // ← This brace was MISSING in the original (BUG-01 fix).

    // -------------------------------------------------------------------------
    // MARK: - Permissions (Stage 0 fix, Stage 9)
    // -------------------------------------------------------------------------

    /// Request permissions on every launch (Stage 0 fix – was nested inside onboard()).
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        _ = CGRequestScreenCaptureAccess()
        _ = CGRequestListenEventAccess()
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// Check permissions before each listen session; speak + show a message if denied.
    /// Returns true if everything is OK to proceed.
    private func permissionsReady() -> Bool {
        let perms = currentPermissions()
        blogInfo("[PERMS] pre-listen check: \(perms)")

        if perms.mic != "authorized" {
            failWith("I need microphone access. Enable it for Buddy in System Settings → Privacy → Microphone.")
            return false
        }
        if perms.speech != "authorized" {
            failWith("I need Speech Recognition access. Enable it for Buddy in System Settings → Privacy → Speech Recognition.")
            return false
        }
        if !perms.screen {
            failWith("I can't see the screen. Enable Screen Recording for Buddy in System Settings → Privacy & Security.")
            return false
        }
        return true
    }

    // -------------------------------------------------------------------------
    // MARK: - Hotkey handling (Stage 3)
    // -------------------------------------------------------------------------

    private func flags(_ e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ctrlDown = f.contains(.control)
        let optDown  = f.contains(.option)

        switch state {
        case .idle:
            // Start when both Ctrl and Opt are pressed together.
            if ctrlDown && optDown { beginListening() }

        case .listening:
            // Stop when EITHER Ctrl or Opt is released (not requiring all modifiers gone).
            if !ctrlDown || !optDown { stopListening() }

        case .processing, .presenting:
            // Interrupt: cancel in-flight work and start fresh if keys are pressed.
            if ctrlDown && optDown {
                blogInfo("[HOTKEY] Interrupted \(state) by new key press")
                interruptAndStartListening()
            }

        case .confirming:
            break  // Don't start a new session while a modal is up.
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - Listen session (Stages 2, 3, 5)
    // -------------------------------------------------------------------------

    private func beginListening() {
        guard state == .idle else {
            blogWarn("[HOTKEY] beginListening called from \(state) – ignoring")
            return
        }
        guard permissionsReady() else { return }

        RequestClock.shared.reset()
        interactionGeneration += 1
        blogInfo("[KEY] \(RequestClock.shared.elapsed) Control+Option pressed → listening")

        voice.stopSpeaking(at: .immediate)
        path = []
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            overlay.setDisplayFrame(screen.frame)
        }
        overlay.show("listening…")

        // Stage 4: start ears; handle engine failures gracefully.
        do { try ears.start() } catch {
            failWith(error.localizedDescription)
            return
        }
        // Stage 3: path timer in .common run-loop mode so it fires during menus/tracking.
        // The closure captures self weakly and hops to MainActor to mutate path.
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.path.append(NSEvent.mouseLocation) }
        }
        pathTimer = t
        RunLoop.main.add(t, forMode: .common)

        transition(to: .listening)
        notch?.activate()
    }

    private func stopListening() {
        guard state == .listening else {
            blogWarn("[HOTKEY] stopListening called from \(state) – ignoring")
            return
        }
        blogInfo("[KEY] \(RequestClock.shared.elapsed) Control+Option released → processing")

        pathTimer?.invalidate()
        pathTimer = nil
        // The image must reflect the screen at release, after the user has
        // finished pointing or opening a menu. Keep our overlay out of it.
        overlay.hide()
        transition(to: .processing)

        screenshotTask = Task.detached(priority: .userInitiated) {
            blogInfo("[SCREEN] \(RequestClock.shared.elapsed) capture started at key-release")
            return try await Screen.capture()
        }

        let generation = interactionGeneration
        let captureTask = screenshotTask

        // Stage 2: the request runs in a stored Task so it can be cancelled.
        requestTask = Task { [weak self] in
            await self?.runRequest(generation: generation, captureTask: captureTask)
        }

        // Stage 2: watchdog – if processing/presenting exceeds 30 s, abort.
        armWatchdog()
    }

    private func interruptAndStartListening() {
        disarmWatchdog()
        requestTask?.cancel()
        requestTask = nil
        screenshotTask?.cancel()
        screenshotTask = nil
        player.cancel()
        voice.stopSpeaking(at: .immediate)
        overlay.cancel()
        transition(to: .idle)
        beginListening()
    }

    // -------------------------------------------------------------------------
    // MARK: - Request pipeline (Stages 1, 2, 5)
    // -------------------------------------------------------------------------

    private func runRequest(generation: Int, captureTask: Task<CaptureResult, Error>?) async {
        // Stage 4: await the final transcript.
        let rawText = await ears.stop()
        guard !Task.isCancelled, generation == interactionGeneration else { return }
        blogInfo("[EARS] \(RequestClock.shared.elapsed) transcript ready")

        var text = rawText
        let prefix = "hey \(Settings.name.lowercased())"
        if text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!"))
        }

        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            blogInfo("[EARS] empty transcript – giving feedback")
            await MainActor.run { [weak self] in
                guard let self, generation == self.interactionGeneration else { return }
                self.say("I didn't catch that. Hold Control and Option, then speak.")
                self.overlay.setLabel("didn't catch that")
                self.notchError = "No speech detected"
                self.finish()
            }
            return
        }

        // Await the screenshot started at key release, in parallel with Ears.stop().
        var capture: CaptureResult
        do {
            if let st = captureTask {
                capture = try await st.value
                guard !Task.isCancelled, generation == interactionGeneration else { return }
                screenshotTask = nil
            } else {
                // Fallback: capture now (shouldn't normally happen).
                blogWarn("[SCREEN] no pre-started screenshot task, capturing now")
                capture = try await Screen.capture()
            }
            // The pre-started capture may be from another display if the user
            // moved the cursor across monitors while speaking.
            if let last = path.last, !capture.displayFrame.contains(last) {
                blogInfo("[SCREEN] cursor changed displays; capturing its final display")
                capture = try await Screen.capture()
            }
            // Update overlay to use same display as screenshot.
            await MainActor.run { [weak self] in
                guard let self, generation == self.interactionGeneration else { return }
                self.overlay.setDisplayFrame(capture.displayFrame)
            }
        } catch {
            // Screenshot failure: proceed with a clear spoken message.
            blogError("[SCREEN] capture failed: \(error.localizedDescription)")
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard generation == self.interactionGeneration, !Task.isCancelled else { return }
                self.say("I can't see the screen. Check Screen Recording permission and try again.")
                self.overlay.setLabel("screen capture failed")
                self.notchError = "Screen capture failed"
                self.finish()
            }
            return
        }
        blogInfo("[SCREEN] \(RequestClock.shared.elapsed) \(capture.jpeg.count / 1024) KB ready")
        let gesture = describeGesture(displayFrame: capture.displayFrame)

        // Call Gemini.
        let plan: Plan
        do {
            try Task.checkCancellation()
            guard generation == interactionGeneration else { return }
            let modelPlan = try await brain.ask(text: text, image: capture.jpeg, gesture: gesture)
            let targets = capture.ocr.available ?? []
            plan = DrawingTargetResolver.refine(modelPlan, targets: targets)
            if ProcessInfo.processInfo.environment["BUDDY_DRAW_DEBUG"] == "1" {
                blogDebug("[DRAWING] localOCR=\(targets.count) ready=\(capture.ocr.available != nil)")
            }
        } catch is CancellationError {
            blogInfo("[BRAIN] request cancelled")
            return
        } catch {
            blogError("[BRAIN] error: \(error.localizedDescription)")
            await MainActor.run { [weak self] in
                guard let self, generation == self.interactionGeneration, !Task.isCancelled else { return }
                self.say(error.localizedDescription)
                self.overlay.setLabel("error")
                self.notchError = "Request failed. Try again."
                self.finish()
            }
            return
        }

        // Hand off to the presentation phase on the main actor.
        // finish() will be called when presentation finishes (speech + animations).
        await MainActor.run { [weak self] in
            guard let self, generation == self.interactionGeneration, !Task.isCancelled else { return }
            self.present(plan, visualRequested: VisualRequest.requiresGuidance(text) || plan.visual == true)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - Presentation (Stage 2, 4, 5)
    // -------------------------------------------------------------------------

    private func present(_ plan: Plan, visualRequested: Bool) {
        disarmWatchdog()  // Watchdog suspended while presenting
        transition(to: .presenting)

        var steps = plan.normalizedSteps()
        let preparedCount = steps.reduce(0) { $0 + $1.effectiveDrawings.filter(\.isValid).count }
        if visualRequested && preparedCount == 0 {
            blogWarn("[DRAWING] Explicit visual request has no valid target or drawing")
            if let last = steps.indices.last {
                steps[last].say += " I couldn't place a reliable marker on this screen."
            }
            notchError = "Visual target unavailable"
        }
        let spoken = steps.map(\.say).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !spoken.isEmpty {
            lastSpokenResponse = spoken
            lastPresentationSteps = steps
        }
        player.play(steps: steps) { [weak self] in
            guard let self else { return }
            if visualRequested && preparedCount > 0 && self.overlay.presentedDrawingCount == 0 {
                blogError("[DRAWING] Visual request completed without displaying a drawing")
                self.notchError = "Drawing could not be displayed"
                self.say("I couldn't display the marker. Please try again.")
            }
            if let acts = plan.actions, !acts.isEmpty {
                self.showConfirmation(acts)
            } else {
                self.finish()
            }
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - Central finish (Stage 2) – called by exit paths
    // -------------------------------------------------------------------------

    private func finish() {
        notch?.complete(error: notchError)
        notchError = nil
        interactionGeneration += 1
        disarmWatchdog()
        requestTask = nil
        screenshotTask?.cancel()
        screenshotTask = nil
        player.cancel()
        overlay.hide()
        transition(to: .idle)
        blogInfo("[STATE] \(RequestClock.shared.elapsed) → idle (finish)")
    }

    /// Convenience: speak an error and go idle immediately.
    private func failWith(_ message: String) {
        blogError("[FAIL] \(message)")
        notchError = message
        say(message)
        overlay.setLabel("error")
        finish()
    }

    // -------------------------------------------------------------------------
    // MARK: - Watchdog (Stage 2)
    // -------------------------------------------------------------------------

    private func armWatchdog() {
        disarmWatchdog()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                blogError("[WATCHDOG] 45 s limit hit in state \(self.state). Aborting.")
                self.requestTask?.cancel()
                self.requestTask = nil
                self.say("Sorry, that took too long. Please try again.")
                self.finish()
            }
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: item)
    }

    private func disarmWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func stopFromNotch() {
        if state == .idle {
            notch?.complete(status: "Stopped")
            return
        }
        guard state != .confirming else { return }
        interactionGeneration += 1
        requestTask?.cancel()
        screenshotTask?.cancel()
        pathTimer?.invalidate()
        pathTimer = nil
        if state == .listening { Task { _ = await ears.stop() } }
        voice.stopSpeaking(at: .immediate)
        notch?.complete(status: "Stopped")
        finish()
    }

    private func replayFromNotch() {
        guard state == .idle, let text = lastSpokenResponse, !text.isEmpty,
              let steps = lastPresentationSteps, !steps.isEmpty else { return }
        voice.stopSpeaking(at: .immediate)
        notch?.extendGrace(by: max(2.5, Double(text.split(separator: " ").count) * 0.45 + 2.5))
        transition(to: .presenting)
        player.play(steps: steps) { [weak self] in self?.finish() }
    }

    private func recentResponses() -> [String] {
        brain.history.compactMap { turn in
            guard turn["role"] as? String == "model",
                  let parts = turn["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else { return nil }
            return String(text.prefix(180))
        }.suffix(4).reversed().map { $0 }
    }

    // -------------------------------------------------------------------------
    // MARK: - State transition (Stage 2) – all transitions through one function
    // -------------------------------------------------------------------------

    private func transition(to new: AppState) {
        // Warn on unexpected transitions (they are no-ops in practice).
        let valid: Bool
        switch (state, new) {
        case (.idle,       .listening):   valid = true
        case (.idle,       .presenting):  valid = true // Replay saved presentation.
        case (.listening,  .processing):  valid = true
        case (.processing, .presenting):  valid = true
        case (.processing, .idle):        valid = true
        case (.presenting, .confirming):  valid = true
        case (.presenting, .idle):        valid = true
        case (.confirming, .idle):        valid = true
        // Cancel/interrupt paths (any → idle).
        case (_, .idle):                  valid = true
        default:                          valid = false
        }
        if !valid {
            blogWarn("[STATE] unexpected transition \(state) → \(new)")
        }
        state = new
    }

    // -------------------------------------------------------------------------
    // MARK: - Gesture detection (Stage 1 – logs added; Stage 8 – display-aware)
    // -------------------------------------------------------------------------

    private func describeGesture(displayFrame s: CGRect) -> String {
        let capturedPath = path.filter { s.contains($0) }
        guard capturedPath.count > 5, let last = capturedPath.last,
              let first = capturedPath.first else { return "" }

        let xs = capturedPath.map { $0.x }, ys = capturedPath.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return "" }

        let w = maxX - minX, h = maxY - minY

        // Convert AppKit bottom-left coords to model's top-left grid (0-1000).
        let mapper = CanvasMapper(size: s.size)
        func nx(_ v: CGFloat) -> Int { Int(mapper.normalized(CGPoint(x: v, y: s.midY), displayFrame: s).x) }
        func ny(_ v: CGFloat) -> Int { Int(mapper.normalized(CGPoint(x: s.midX, y: v), displayFrame: s).y) }

        var len: CGFloat = 0
        for i in 1..<capturedPath.count { len += hypot(capturedPath[i].x - capturedPath[i-1].x, capturedPath[i].y - capturedPath[i-1].y) }
        let closed = hypot(first.x - last.x, first.y - last.y) < max(w, h) * 0.4
        let box = "x \(nx(minX))-\(nx(maxX)), y \(ny(maxY))-\(ny(minY))"
        let under = Screen.elementUnder(last, primaryDisplayTop: NSScreen.screens.first?.frame.maxY ?? s.maxY)

        let gesture: String
        let gestureKind: String
        if max(w, h) > 60 && closed && len > (w + h) * 1.5 {
            gestureKind = "circle"
            gesture = "user CIRCLED a region (\(box)). \(under)"
        } else if max(w, h) > 60 {
            gestureKind = "sweep"
            gesture = "user moved cursor over region (\(box)), ending at (\(nx(last.x)), \(ny(last.y))). \(under)"
        } else {
            gestureKind = "point"
            gesture = "user is POINTING at (\(nx(last.x)), \(ny(last.y))). \(under)"
        }
        blogDebug("[GESTURE] type=\(gestureKind) region=(\(box))")
        return gesture
    }

    // -------------------------------------------------------------------------
    // MARK: - Action confirmation (Stages 2, 7)
    // -------------------------------------------------------------------------

    private func showConfirmation(_ actions: [Action]) {
        disarmWatchdog()
        transition(to: .confirming)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText     = "\(Settings.name) wants to run \(actions.count) step(s)"
        alert.informativeText = actions.map { "• \($0.why ?? $0.tool)\n    \($0.arg)" }.joined(separator: "\n")
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            // Stage 7: run on background queue – never block main thread.
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let results = await self.executeActions(actions)
                await MainActor.run { [weak self] in
                    self?.say(results.allSucceeded ? "Done." : "One of the steps hit an error. Check the console for details.")
                    self?.finish()
                }
            }
        } else {
            finish()
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - Action execution (Stage 7)
    // -------------------------------------------------------------------------

    struct ActionResults {
        var allSucceeded: Bool
    }

    private func executeActions(_ actions: [Action]) async -> ActionResults {
        var allOK = true
        for action in actions {
            let ok = await runAction(action)
            if !ok { allOK = false }
        }
        return ActionResults(allSucceeded: allOK)
    }

    /// Run a single action on a background queue with a 30 s timeout.
    private func runAction(_ a: Action) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                let outPipe  = Pipe()
                let errPipe  = Pipe()

                switch a.tool {
                case "applescript":
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    p.arguments = ["-e", a.arg]
                case "open":
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    p.arguments = [a.arg]
                default:   // "shell"
                    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    p.arguments = ["-c", a.arg]
                }

                p.standardOutput = outPipe
                p.standardError  = errPipe

                do { try p.run() } catch {
                    blogError("[ACTION] launch failed: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                    return
                }

                // Per-action 30 s timeout.
                let sem = DispatchSemaphore(value: 0)
                p.terminationHandler = { _ in sem.signal() }
                guard sem.wait(timeout: .now() + 30) == .success else {
                    p.terminate()
                    blogError("[ACTION] '\(a.tool)' timed out after 30 s")
                    continuation.resume(returning: false)
                    return
                }

                let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let exitCode = p.terminationStatus

                blogInfo("[ACTION] '\(a.tool)' exit=\(exitCode) stdout='\(stdout.prefix(120))' stderr='\(stderr.prefix(120))'")
                continuation.resume(returning: exitCode == 0)
            }
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - TTS
    // -------------------------------------------------------------------------

    func say(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.5
        voice.speak(u)
    }
}
