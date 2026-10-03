import AVFoundation
import Speech

final class Ears {
    let engine = AVAudioEngine()
    let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    var req: SFSpeechAudioBufferRecognitionRequest?
    var task: SFSpeechRecognitionTask?
    var latest = ""

    func start() {
        latest = ""
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        req = r
        task = rec.recognitionTask(with: r) { [weak self] res, _ in
            if let res { self?.latest = res.bestTranscription.formattedString }
        }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] b, _ in
            self?.req?.append(b)
        }
        engine.prepare()
        try? engine.start()
    }

    func stop(_ done: @escaping (String) -> Void) {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        req?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.task?.cancel()
            done(self?.latest ?? "")
        }
    }
}
