import AppKit
import AVFoundation
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    let overlay = Overlay()
    let ears = Ears()
    let brain = Brain()
    let voice = AVSpeechSynthesizer()
    var statusItem: NSStatusItem!
    var holding = false
    var busy = false
    var path: [CGPoint] = []
    var pathTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◎"
        let menu = NSMenu()
        let s = menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: "")
        s.target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        if Settings.name.isEmpty || Settings.apiKey.isEmpty { onboard() }
        requestPermissions()
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.flags(e) }
    }

    // MARK: onboarding & permissions
    @objc func settings() { onboard() }

    func onboard() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Set up your buddy"
        a.informativeText = "Name your assistant, and paste a free Gemini API key from aistudio.google.com/apikey"
        let n = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        n.placeholderString = "Assistant name (e.g. Nova)"
        n.stringValue = Settings.name
        let k = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        k.placeholderString = "Gemini API key"
        k.stringValue = Settings.apiKey
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        v.addSubview(n); v.addSubview(k)
        a.accessoryView = v
        a.addButton(withTitle: "Save")
        if a.runModal() == .alertFirstButtonReturn {
            Settings.name = n.stringValue.trimmingCharacters(in: .whitespaces)
            Settings.apiKey = k.stringValue.trimmingCharacters(in: .whitespaces)
        }
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        _ = CGRequestScreenCaptureAccess()
        _ = CGRequestListenEventAccess()
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    // MARK: hold ⌃⌥ to talk
    func flags(_ e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let combo = f.contains(.control) && f.contains(.option) && !f.contains(.command) && !f.contains(.shift)
        if combo && !holding && !busy { start() }
        else if !combo && holding { stop() }
    }

    func start() {
        holding = true
        voice.stopSpeaking(at: .immediate)
        path = []
        overlay.show("listening…")
        ears.start()
        pathTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.path.append(NSEvent.mouseLocation)
        }
    }

    func stop() {
        holding = false
        pathTimer?.invalidate()
        busy = true
        overlay.setLabel("thinking…")
        ears.stop { [weak self] text in self?.handle(text) }
    }

    func handle(_ raw: String) {
        var text = raw
        let prefix = "hey \(Settings.name.lowercased())"
        if text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,.!"))
        }
        guard !text.isEmpty else { overlay.hide(); busy = false; return }
        let gesture = describeGesture()
        Task {
            do {
                let img = try Screen.capture()
                let plan = try await brain.ask(text: text, image: img, gesture: gesture)
                DispatchQueue.main.async { self.perform(plan) }
            } catch {
                DispatchQueue.main.async {
                    self.say("Sorry, \(error.localizedDescription)")
                    self.overlay.hide()
                    self.busy = false
                }
            }
        }
    }

    // MARK: gesture detection (circle / move / point)
    func describeGesture() -> String {
        let s = NSScreen.main!.frame
        guard path.count > 5, let last = path.last, let first = path.first else { return "" }
        let xs = path.map { $0.x }, ys = path.map { $0.y }
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let w = maxX - minX, h = maxY - minY
        func nx(_ v: CGFloat) -> Int { Int((v - s.minX) / s.width * 1000) }
        func ny(_ v: CGFloat) -> Int { Int((s.maxY - v) / s.height * 1000) }
        var len: CGFloat = 0
        for i in 1..<path.count { len += hypot(path[i].x - path[i-1].x, path[i].y - path[i-1].y) }
        let closed = hypot(first.x - last.x, first.y - last.y) < max(w, h) * 0.4
        let box = "x \(nx(minX))-\(nx(maxX)), y \(ny(maxY))-\(ny(minY))"
        let under = Screen.elementUnder(last, screenH: s.height)
        if max(w, h) > 60 && closed && len > (w + h) * 1.5 {
            return "user CIRCLED a region (\(box)). \(under)"
        } else if max(w, h) > 60 {
            return "user moved cursor over region (\(box)), ending at (\(nx(last.x)), \(ny(last.y))). \(under)"
        }
        return "user is POINTING at (\(nx(last.x)), \(ny(last.y))). \(under)"
    }

    // MARK: act on the plan
    func perform(_ plan: Plan) {
        say(plan.say)
        overlay.point(plan.points ?? []) { [weak self] in
            guard let self else { return }
            if let acts = plan.actions, !acts.isEmpty { self.confirm(acts) }
            self.busy = false
        }
    }

    func say(_ t: String) {
        let u = AVSpeechUtterance(string: t)
        u.rate = 0.5
        voice.speak(u)
    }

    func confirm(_ actions: [Action]) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(Settings.name) wants to run \(actions.count) step(s)"
        a.informativeText = actions.map { "• \($0.why ?? $0.tool)\n    \($0.arg)" }.joined(separator: "\n")
        a.addButton(withTitle: "Run")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var out = ""
        for x in actions { out += run(x) }
        say(out.lowercased().contains("error") ? "One of the steps hit an error." : "Done.")
    }

    func run(_ a: Action) -> String {
        let p = Process(), pipe = Pipe()
        switch a.tool {
        case "applescript": p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", a.arg]
        case "open": p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [a.arg]
        default: p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", a.arg]
        }
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
