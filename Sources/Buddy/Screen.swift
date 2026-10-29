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
import ImageIO

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
        // screencapture -D uses a 1-based screen number, not NSScreenNumber's
        // Core Graphics display ID. NSScreen.screens lists the main display first.
        let displayNumber = (NSScreen.screens.firstIndex(of: screen) ?? 0) + 1

        // Run the blocking subprocess work on a background serial queue.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runCapture(displayNumber: displayNumber, displayFrame: screenFrame)
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

    private static func runCapture(displayNumber: Int, displayFrame: CGRect) throws -> CaptureResult {
        let filePath = NSTemporaryDirectory() + "buddy_capture_\(UUID().uuidString).jpg"
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        // -D 1 is main; -D 2 is the first secondary display.
        var scArgs = ["-x", "-t", "jpg", "-D", "\(displayNumber)"]
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

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              captureMatchesDisplay(pixelSize: CGSize(width: CGFloat(width), height: CGFloat(height)), displayFrame: displayFrame) else {
            throw screenError("The captured image does not match the selected display. Try again after checking display settings.")
        }

        blogInfo("[SCREEN] \(RequestClock.shared.elapsed) display=\(displayNumber) image=\(width)x\(height) frame=\(Int(displayFrame.width))x\(Int(displayFrame.height)) points, \(data.count / 1024) KB")
        return CaptureResult(jpeg: data, displayFrame: displayFrame)
    }

    /// sips only scales the full image, so aspect ratios must agree. A mismatch
    /// means the screenshot and overlay cannot share normalized coordinates.
    static func captureMatchesDisplay(pixelSize: CGSize, displayFrame: CGRect) -> Bool {
        guard pixelSize.width > 0, pixelSize.height > 0,
              displayFrame.width > 0, displayFrame.height > 0 else { return false }
        return abs(pixelSize.width / pixelSize.height - displayFrame.width / displayFrame.height) < 0.02
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
        guard p.terminationStatus == 0 else {
            throw screenError("Screenshot preparation failed (\(URL(fileURLWithPath: exec).lastPathComponent) exit \(p.terminationStatus)).")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Accessibility element under cursor (Stage 8)
    // -------------------------------------------------------------------------

    /// Returns a human-readable description of the UI element at the given
    /// AppKit-coord point (origin bottom-left). AX uses the primary display's
    /// top-left origin, including for points on a secondary display.
    static func elementUnder(_ point: CGPoint, primaryDisplayTop: CGFloat) -> String {
        guard AXIsProcessTrusted() else { return "" }
        let axPoint = accessibilityPoint(point, primaryDisplayTop: primaryDisplayTop)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
                AXUIElementCreateSystemWide(), Float(axPoint.x), Float(axPoint.y), &el) == .success,
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

    static func accessibilityPoint(_ point: CGPoint, primaryDisplayTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayTop - point.y)
    }

    // -------------------------------------------------------------------------
    // MARK: Helpers
    // -------------------------------------------------------------------------

    private static func screenError(_ msg: String) -> NSError {
        NSError(domain: "Buddy", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
