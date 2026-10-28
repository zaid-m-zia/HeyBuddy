// BuddyLogger.swift
// Stage 1 – Centralised logging.
// All log calls go through os.Logger (visible in Console.app under subsystem
// "com.example.buddy") and are also printed to stdout so they appear in the
// Xcode console without any extra Console.app filter.

import Foundation
import os.log
import AVFoundation
import Speech
import ApplicationServices   // AXIsProcessTrusted, CGPreflightScreenCaptureAccess

// ---------------------------------------------------------------------------
// MARK: - Shared logger
// ---------------------------------------------------------------------------

let log = Logger(subsystem: "com.example.buddy", category: "flow")

// ---------------------------------------------------------------------------
// MARK: - Request-scoped timer
// ---------------------------------------------------------------------------

/// Monotonic clock reference set at key-release so every subsequent log can
/// show "+123 ms" relative to that moment.
final class RequestClock {
    static var shared = RequestClock()
    private var start: ContinuousClock.Instant = .now

    func reset() { start = .now }

    /// Returns "+NNN ms" since last reset().
    var elapsed: String {
        let d = ContinuousClock.now - start
        let seconds = d.components.seconds
        let attos   = d.components.attoseconds
        let ms = Int(seconds * 1000) + Int(attos / 1_000_000_000_000_000)
        return "+\(ms) ms"
    }
}

// Convenience top-level helpers so call sites stay terse.
func blogInfo(_ msg: String)  { log.info("\(msg, privacy: .public)");  print("[BUDDY] \(msg)") }
func blogDebug(_ msg: String) { log.debug("\(msg, privacy: .public)"); print("[BUDDY:dbg] \(msg)") }
func blogWarn(_ msg: String)  { log.warning("\(msg, privacy: .public)"); print("[BUDDY:WARN] \(msg)") }
func blogError(_ msg: String) { log.error("\(msg, privacy: .public)"); print("[BUDDY:ERR] \(msg)") }

// ---------------------------------------------------------------------------
// MARK: - Permission snapshot (Stage 1 + Stage 9)
// ---------------------------------------------------------------------------

struct PermissionSnapshot: CustomStringConvertible {
    let mic: String
    let speech: String
    let screen: Bool
    let inputMonitor: Bool
    let accessibility: Bool

    var description: String {
        "mic=\(mic) speech=\(speech) screen=\(screen) input=\(inputMonitor) ax=\(accessibility)"
    }
}

func currentPermissions() -> PermissionSnapshot {
    let micStatus: String
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:    micStatus = "authorized"
    case .denied:        micStatus = "denied"
    case .restricted:    micStatus = "restricted"
    case .notDetermined: micStatus = "notDetermined"
    @unknown default:    micStatus = "unknown"
    }

    let speechStatus: String
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:    speechStatus = "authorized"
    case .denied:        speechStatus = "denied"
    case .restricted:    speechStatus = "restricted"
    case .notDetermined: speechStatus = "notDetermined"
    @unknown default:    speechStatus = "unknown"
    }

    return PermissionSnapshot(
        mic: micStatus,
        speech: speechStatus,
        screen: CGPreflightScreenCaptureAccess(),
        inputMonitor: CGPreflightListenEventAccess(),
        accessibility: AXIsProcessTrusted()
    )
}
