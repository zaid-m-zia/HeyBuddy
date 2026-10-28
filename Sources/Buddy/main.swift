import AppKit

// AppDelegate is @MainActor. We run the entire entry on the main actor
// to satisfy Swift Concurrency's isolation requirements.
let app = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
}
app.setActivationPolicy(.accessory)
app.run()
