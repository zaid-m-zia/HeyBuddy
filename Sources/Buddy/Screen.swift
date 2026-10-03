import AppKit
import ApplicationServices

enum Screen {
    static func capture() throws -> Data {
        let path = NSTemporaryDirectory() + "buddy.jpg"
        try? FileManager.default.removeItem(atPath: path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-m", "-t", "jpg", path]
        try p.run(); p.waitUntilExit()
        let s = Process()
        s.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        s.arguments = ["-Z", "1400", path]
        try s.run(); s.waitUntilExit()
        guard let d = FileManager.default.contents(atPath: path) else {
            throw NSError(domain: "Buddy", code: 2, userInfo: [NSLocalizedDescriptionKey: "Screenshot failed. Check Screen Recording permission."])
        }
        return d
    }

    static func elementUnder(_ p: CGPoint, screenH: CGFloat) -> String {
        guard AXIsProcessTrusted() else { return "" }
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(screenH - p.y), &el) == .success,
              let e = el else { return "" }
        func attr(_ k: String) -> String {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(e, k as CFString, &v)
            return (v as? String) ?? ""
        }
        return "element under cursor: role=\(attr("AXRole")) title=\(attr("AXTitle")) desc=\(attr("AXDescription")) value=\(attr("AXValue"))"
    }
}
