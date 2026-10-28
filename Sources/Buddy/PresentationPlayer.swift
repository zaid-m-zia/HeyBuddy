// PresentationPlayer.swift
// Stage 5 – Speech-driven timeline player for multi-step AI presentations.
//
// Uses AVSpeechSynthesizer as the master clock. Utterances are queued sequentially
// for gapless speech. Delegate callbacks drive pointer flight, cue-synced annotations,
// and step lifecycle transitions. Fallback timer (160 wpm) guarantees forward progress
// if speech is disabled or hardware fails.

import AppKit
import AVFoundation

@MainActor
final class PresentationPlayer: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private weak var overlay: Overlay?

    // Generation counter prevents stale callbacks from firing after cancellation/restart
    private var generation: Int = 0

    private var steps: [Step] = []
    private var stepIndicesByUtterance: [AVSpeechUtterance: Int] = [:]
    private var cueOffsetsByStep: [Int: Int] = [:] // stepIndex -> character offset of cue in say
    private var triggeredCues: Set<Int> = []
    private var completionHandler: (() -> Void)?

    // Fallback timer for silent or failed speech playback
    private var fallbackTimer: DispatchWorkItem?

    init(overlay: Overlay) {
        self.overlay = overlay
        super.init()
        synth.delegate = self
    }

    // -------------------------------------------------------------------------
    // MARK: Playback Controls
    // -------------------------------------------------------------------------

    func play(steps: [Step], onComplete: @escaping () -> Void) {
        cancel()
        generation += 1
        let currentGen = generation

        guard !steps.isEmpty else {
            onComplete()
            return
        }

        self.steps = steps
        self.completionHandler = onComplete
        self.stepIndicesByUtterance.removeAll()
        self.cueOffsetsByStep.removeAll()
        self.triggeredCues.removeAll()

        overlay?.beginPresentation()

        var utterances: [AVSpeechUtterance] = []
        for (idx, step) in steps.enumerated() {
            let text = step.say.trimmingCharacters(in: .whitespacesAndNewlines)
            let utteranceText = text.isEmpty ? " " : text
            let u = AVSpeechUtterance(string: utteranceText)
            u.rate = 0.50
            u.preUtteranceDelay = 0.0
            u.postUtteranceDelay = 0.08

            stepIndicesByUtterance[u] = idx

            // Compute cue offset
            if let cue = step.cue, !cue.isEmpty,
               text.range(of: cue, options: .caseInsensitive) != nil {
                cueOffsetsByStep[idx] = (text as NSString).range(of: cue, options: .caseInsensitive).location
            }

            utterances.append(u)
        }

        // Start fallback watchdog: if no speech starts within 1.0s, advance automatically
        armFallbackWatchdog(gen: currentGen, stepIndex: 0)

        // Queue all utterances on synthesizer
        for u in utterances {
            synth.speak(u)
        }
    }

    func cancel() {
        generation += 1
        fallbackTimer?.cancel()
        fallbackTimer = nil
        synth.stopSpeaking(at: .immediate)
        stepIndicesByUtterance.removeAll()
        cueOffsetsByStep.removeAll()
        triggeredCues.removeAll()
        completionHandler = nil
        overlay?.cancel()
    }

    // -------------------------------------------------------------------------
    // MARK: AVSpeechSynthesizerDelegate (The speech is the clock)
    // -------------------------------------------------------------------------

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, let idx = self.stepIndicesByUtterance[utterance] else { return }
            self.handleStepStart(idx)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self, let idx = self.stepIndicesByUtterance[utterance] else { return }
            self.handleSpeechRange(characterRange, stepIndex: idx)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, let idx = self.stepIndicesByUtterance[utterance] else { return }
            self.handleStepFinish(idx)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.stepIndicesByUtterance[utterance] != nil else { return }
            self.cancel()
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Step Event Handlers
    // -------------------------------------------------------------------------

    private func handleStepStart(_ idx: Int) {
        fallbackTimer?.cancel()
        guard idx < steps.count else { return }
        let step = steps[idx]
        blogInfo("[PLAYER] didStart step \(idx + 1)/\(steps.count): '\(step.say.prefix(50))'")

        // Pointer flight starts immediately on step start
        overlay?.startStep(step, stepIndex: idx)

        // If no cue is set, display annotations right away; otherwise wait for cue
        if cueOffsetsByStep[idx] == nil {
            overlay?.showAnnotations(for: step, stepIndex: idx)
        }
    }

    private func handleSpeechRange(_ range: NSRange, stepIndex: Int) {
        guard let cueOffset = cueOffsetsByStep[stepIndex], !triggeredCues.contains(stepIndex) else { return }
        if range.location >= cueOffset {
            triggeredCues.insert(stepIndex)
            guard stepIndex < steps.count else { return }
            blogInfo("[PLAYER] cue fired at offset \(range.location) for step \(stepIndex + 1)")
            overlay?.showAnnotations(for: steps[stepIndex], stepIndex: stepIndex)
        }
    }

    private func handleStepFinish(_ idx: Int) {
        guard idx < steps.count else { return }
        let step = steps[idx]
        blogInfo("[PLAYER] didFinish step \(idx + 1)/\(steps.count)")

        // Ensure annotations were shown even if cue was never reached
        if !triggeredCues.contains(idx) {
            overlay?.showAnnotations(for: step, stepIndex: idx)
        }

        let isLast = (idx == steps.count - 1)
        if !isLast {
            overlay?.finishStep(step, stepIndex: idx)
        } else {
            // Last step: hold final annotations for 2.5s before cleanup
            overlay?.finishStep(step, stepIndex: idx, preserveAnnotations: true)
            let gen = self.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.overlay?.finishPresentation { [weak self] in
                    guard let self, self.generation == gen else { return }
                    let cb = self.completionHandler
                    self.completionHandler = nil
                    cb?()
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Fallback Timer (Words-per-minute fallback if speech engine stalls)
    // -------------------------------------------------------------------------

    private func armFallbackWatchdog(gen: Int, stepIndex: Int) {
        fallbackTimer?.cancel()
        guard stepIndex < steps.count else { return }
        let step = steps[stepIndex]
        let wordCount = max(1, step.say.split(separator: " ").count)
        // 160 words per minute = ~375ms per word + 500ms baseline buffer
        let duration = Double(wordCount) * 0.375 + 0.6

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen else { return }
            blogWarn("[PLAYER] Fallback timer fired for step \(stepIndex + 1)")
            self.handleStepStart(stepIndex)
            self.handleSpeechRange(NSRange(location: 0, length: 1), stepIndex: stepIndex)

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.handleStepFinish(stepIndex)
                if stepIndex + 1 < self.steps.count {
                    self.armFallbackWatchdog(gen: gen, stepIndex: stepIndex + 1)
                }
            }
        }
        fallbackTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }
}
