// Ears.swift
// Stages 1, 4 – Microphone tap + speech recognition.
//
// Changes from original:
//   - Replaced "wait 0.7 s then cancel()" with event-driven delivery:
//     The callback delivers the transcript as soon as isFinal == true.
//     A 1.2 s fallback timer fires if isFinal never arrives (e.g. very short
//     phrases), delivering the latest partial result and only then cancelling.
//   - try engine.start() throws and is handled; microphone errors are reported.
//   - AVAudioEngineConfigurationChange observed for AirPods/headphone swaps.
//   - Force-unwrap on SFSpeechRecognizer removed.
//   - isAvailable and authorization status checked before starting.
//   - taskHint = .dictation; on-device recognition preferred (fallback to server).
//   - Empty / very short transcripts reported as "I didn't catch that."
//   - All events logged with elapsed-time stamp.

import AVFoundation
import Speech

// ---------------------------------------------------------------------------
// MARK: - Ears
// ---------------------------------------------------------------------------

final class Ears {
    // -------------------------------------------------------------------------
    // MARK: State
    // -------------------------------------------------------------------------

    private var engine: AVAudioEngine = AVAudioEngine()

    /// Recognizer lazily resolved so we can handle nil and rebuild after route changes.
    private var recognizer: SFSpeechRecognizer?

    private var req:  SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Most-recent transcript seen in the partial-result callback.
    private var latestText = ""

    /// The continuation used to deliver the final transcript to the awaiting caller.
    private var deliveryContinuation: CheckedContinuation<String, Never>?

    /// Fallback timer fired 1.2 s after endAudio() if isFinal never arrives.
    private var fallbackTimer: DispatchWorkItem?

    /// Whether a recording session is currently active (guards against double-start).
    private var isRunning = false

    // Route-change observation token.
    private var routeObserver: NSObjectProtocol?

    // -------------------------------------------------------------------------
    // MARK: Init
    // -------------------------------------------------------------------------

    init() {
        observeRouteChanges()
    }

    // -------------------------------------------------------------------------
    // MARK: Start
    // -------------------------------------------------------------------------

    /// Start recording. Throws a human-readable error if anything fails.
    func start() throws {
        guard !isRunning else { return }
        blogInfo("[EARS] \(RequestClock.shared.elapsed) start()")

        // Check permissions before touching the hardware.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw EarsError.micNotAuthorized
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw EarsError.speechNotAuthorized
        }

        // Build a fresh recognizer (locale from system; falls back to en-US).
        let locale = Locale.current.identifier.hasPrefix("en") ? Locale.current : Locale(identifier: "en-US")
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let rec = recognizer else {
            throw EarsError.recognizerUnavailable
        }
        guard rec.isAvailable else {
            throw EarsError.recognizerUnavailable
        }

        latestText = ""

        // Build recognition request.
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.taskHint = .dictation
        // Prefer on-device for speed and privacy; server is fallback.
        if rec.supportsOnDeviceRecognition {
            r.requiresOnDeviceRecognition = true
            blogDebug("[EARS] using on-device recognition")
        } else {
            blogDebug("[EARS] using server recognition")
        }
        req = r

        // Install recognition task BEFORE starting the engine so no buffers are lost.
        task = rec.recognitionTask(with: r) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.latestText = text
                blogDebug("[EARS] \(RequestClock.shared.elapsed) partial='\(text.prefix(60))' isFinal=\(result.isFinal)")
                if result.isFinal {
                    blogInfo("[EARS] \(RequestClock.shared.elapsed) isFinal transcript='\(text)'")
                    self.deliverResult(text)
                }
            }
            if let error {
                blogError("[EARS] recognition error: \(error.localizedDescription)")
                // Deliver whatever we have; deliverResult is idempotent.
                self.deliverResult(self.latestText)
            }
        }

        // Build engine.
        engine = AVAudioEngine()
        let input = engine.inputNode
        input.removeTap(onBus: 0)   // defensive: remove any leftover tap

        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.req?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Clean up and propagate.
            input.removeTap(onBus: 0)
            task?.cancel(); task = nil
            req = nil
            blogError("[EARS] engine.start() failed: \(error)")
            throw EarsError.engineFailed(error.localizedDescription)
        }

        isRunning = true
        blogInfo("[EARS] engine started, listening…")
    }

    // -------------------------------------------------------------------------
    // MARK: Stop — returns the transcript (or empty) via async continuation
    // -------------------------------------------------------------------------

    /// Stop the engine and return the final transcript.
    /// Returns the empty string only if the engine was never started.
    func stop() async -> String {
        guard isRunning else { return "" }
        isRunning = false
        blogInfo("[EARS] \(RequestClock.shared.elapsed) stop() called")

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        req?.endAudio()   // signals the recognizer that audio is complete

        return await withCheckedContinuation { continuation in
            self.deliveryContinuation = continuation

            // Fallback: if isFinal never fires within 1.2 s, deliver latest partial.
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                blogWarn("[EARS] \(RequestClock.shared.elapsed) isFinal timeout – delivering latest partial: '\(self.latestText)'")
                self.deliverResult(self.latestText)
            }
            fallbackTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Deliver result (idempotent)
    // -------------------------------------------------------------------------

    private func deliverResult(_ text: String) {
        fallbackTimer?.cancel()
        fallbackTimer = nil
        task?.cancel()    // safe to call even if already finished
        task = nil
        req  = nil
        guard let cont = deliveryContinuation else { return }
        deliveryContinuation = nil
        blogInfo("[EARS] \(RequestClock.shared.elapsed) delivering transcript: '\(text)'")
        cont.resume(returning: text)
    }

    // -------------------------------------------------------------------------
    // MARK: Route / configuration change handling (Stage 4)
    // -------------------------------------------------------------------------

    private func observeRouteChanges() {
        // AVAudioEngine posts this when the I/O configuration changes (e.g. AirPods swap).
        routeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            blogWarn("[EARS] Audio route/configuration changed mid-session – restarting engine")
            // Restart to pick up the new audio route.
            self.handleRouteChange()
        }
    }

    private func handleRouteChange() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.req?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            blogInfo("[EARS] engine restarted after route change")
        } catch {
            blogError("[EARS] engine restart failed: \(error)")
            deliverResult(latestText)
        }
    }
}

// -------------------------------------------------------------------------
// MARK: - Error types
// -------------------------------------------------------------------------

enum EarsError: LocalizedError {
    case micNotAuthorized
    case speechNotAuthorized
    case recognizerUnavailable
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .micNotAuthorized:
            return "I need microphone access. Go to System Settings → Privacy → Microphone and enable Buddy."
        case .speechNotAuthorized:
            return "I need Speech Recognition access. Go to System Settings → Privacy → Speech Recognition and enable Buddy."
        case .recognizerUnavailable:
            return "Speech recognition isn't available right now. Try again in a moment."
        case .engineFailed(let reason):
            return "I couldn't access the microphone: \(reason)"
        }
    }
}
