// Screen.swift
// Stage 5 – Screenshot capture and Accessibility element lookup.
//
// Changes from original:
//   - capture() now runs screencapture + sips on a background DispatchQueue
//     inside a CheckedContinuation, so it NEVER blocks the main thread or a
//     Swift Concurrency cooperative thread (which is forbidden by the runtime).
//   - A 3 s per-step timeout wraps each process; the overall call also has a
//     ceiling enforced by the Task deadline upstream.
//   - Captures the display the cursor is currently on (not always .main), and
//     returns that display's frame for coordinate mapping by the overlay.
//   - CGPreflightScreenCaptureAccess() is checked up-front; missing permission
//     produces a clear error rather than a silent empty file.
//   - Output file size is validated (> 1 KB) to catch silent failures.
//   - Force-unwraps on NSScreen.main removed.
//   - elementUnder uses the passed-in screenH (no internal screen lookup).

import AppKit
import ApplicationServices

// ---------------------------------------------------------------------------
// MARK: - Capture result
// ---------------------------------------------------------------------------

/// Bundles the screenshot data with the display frame used, so
/// the overlay can map model coordinates to the same display.
struct CaptureResult {
    let jpeg: Data
    let displayFrame: CGRect  // AppKit coords (bottom-left origin)
}

// ---------------------------------------------------------------------------
// MARK: - Screen
// ---------------------------------------------------------------------------

enum Screen {

    // -------------------------------------------------------------------------
    // MARK: Capture
    // -------------------------------------------------------------------------

    /// Captures a JPEG screenshot of the display the cursor is on.
    /// Runs synchronous Process work on a background DispatchQueue to avoid
    /// blocking cooperative threads (Swift Concurrency requirement).
    /// Throws a human-readable error if Screen Recording is denied or capture fails.
    static func capture() async throws -> CaptureResult {
        // Permission gate.
        guard CGPreflightScreenCaptureAccess() else {
            throw screenError("I can't see the screen. Please enable Screen Recording for Buddy in System Settings → Privacy & Security.")
        }

        // Find which display the cursor is on.
        let cursorPos = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(cursorPos) })
            ?? NSScreen.screens.first
        guard let screen = targetScreen else {
            throw screenError("No display found.")
        }

        // Extract value-type properties from NSScreen before crossing into the background queue,
        // since NSScreen itself is not Sendable.
        let screenFrame = screen.frame
        let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

        // Run the blocking subprocess work on a background serial queue.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runCapture(displayID: screenID, displayFrame: screenFrame)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Internal blocking capture (runs on background queue only)
    // -------------------------------------------------------------------------

    private static func runCapture(displayID: CGDirectDisplayID?, displayFrame: CGRect) throws -> CaptureResult {
        let filePath = NSTemporaryDirectory() + "buddy_capture.jpg"
        try? FileManager.default.removeItem(atPath: filePath)

        // screencapture: -x = no sounds; -D <id> targets a specific display.
        var scArgs = ["-x", "-t", "jpg"]
        if let sid = displayID {
            scArgs += ["-D", "\(sid)"]
        } else {
            scArgs += ["-m"]   // fallback: main display
        }
        scArgs.append(filePath)

        try runProcess("/usr/sbin/screencapture", args: scArgs, timeout: 5)

        // sips: resize to max 1280 px long edge, JPEG quality 60%.
        // Smaller image → faster base64 encode, upload, and model processing.
        try runProcess("/usr/bin/sips",
                       args: ["-Z", "1280", "--setProperty", "formatOptions", "60", filePath],
                       timeout: 5)

        guard let data = FileManager.default.contents(atPath: filePath), data.count > 1024 else {
            throw screenError("Screenshot failed or was empty. Check Screen Recording permission in System Settings → Privacy & Security.")
        }

        blogInfo("[SCREEN] \(RequestClock.shared.elapsed) captured \(data.count / 1024) KB")
        return CaptureResult(jpeg: data, displayFrame: displayFrame)
    }

    // -------------------------------------------------------------------------
    // MARK: Process runner with timeout (blocks – must run on background queue)
    // -------------------------------------------------------------------------

    private static func runProcess(_ exec: String, args: [String], timeout: Double) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exec)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        try p.run()

        // Manual timeout via a DispatchSemaphore so we don't hang forever.
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw screenError("Screenshot process timed out.")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Accessibility element under cursor (Stage 8)
    // -------------------------------------------------------------------------

    /// Returns a human-readable description of the UI element at the given
    /// AppKit-coord point (origin bottom-left). screenH is the height of the
    /// display the point lives on.
    static func elementUnder(_ point: CGPoint, screenH: CGFloat) -> String {
        guard AXIsProcessTrusted() else { return "" }
        // AX uses CG coordinates (top-left origin): flip Y.
        let axY = Float(screenH - point.y)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
                AXUIElementCreateSystemWide(), Float(point.x), axY, &el) == .success,
              let element = el else { return "" }

        func attr(_ key: String) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, key as CFString, &value)
            return (value as? String) ?? ""
        }
        let role  = attr("AXRole")
        let title = attr("AXTitle")
        let desc  = attr("AXDescription")
        let val   = attr("AXValue")
        return "element under cursor: role=\(role) title=\(title) desc=\(desc) value=\(val)"
    }

    // -------------------------------------------------------------------------
    // MARK: Helpers
    // -------------------------------------------------------------------------

    private static func screenError(_ msg: String) -> NSError {
        NSError(domain: "Buddy", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
