import Foundation
import ImageIO

@MainActor
extension Brain {
    func buildPayload(prompt: String, image: Data, id: String) throws -> (Data, Int, Int) {
        guard image.count >= 4, image.count <= 5_000_000,
              image[0] == 0xFF, image[1] == 0xD8,
              image[image.count - 2] == 0xFF, image[image.count - 1] == 0xD9,
              let source = CGImageSourceCreateWithData(image as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 3000, height <= 3000 else {
            throw GeminiFailure.local(.invalidJSONRequest, stage: "image-validation", id: id)
        }
        let userTurn: [String: Any] = ["role": "user", "parts": [
            ["text": prompt],
            ["inline_data": ["mime_type": "image/jpeg", "data": image.base64EncodedString()]]
        ]]
        // Gemini 3.8 Flash rejects thinkingLevel=minimal. Use each model's default.
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt()]]],
            "contents": Array(history.suffix(12)) + [userTurn],
            "generationConfig": ["responseMimeType": "application/json"]
        ]
        guard JSONSerialization.isValidJSONObject(body) else {
            throw GeminiFailure.local(.invalidJSONRequest, stage: "request-build", id: id)
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= 8_000_000 else {
            throw GeminiFailure.local(.invalidJSONRequest, stage: "request-build", id: id)
        }
        return (data, width, height)
    }

    func ask(text: String, image: Data, gesture: String) async throws -> Plan {
        let id = String(UUID().uuidString.prefix(8))
        let started = Date()
        try Task.checkCancellation()
        let prompt = gesture.isEmpty ? "User said: \(text)" : "User said: \(text)\nCursor gesture while speaking: \(gesture)"
        do {
            let (payload, width, height) = try buildPayload(prompt: prompt, image: image, id: id)
            client.record("id=\(id) stage=request image=\(width)x\(height) imageBytes=\(image.count) payloadBytes=\(payload.count)")
            let (data, model) = try await client.generate(payload: payload, id: id)
            try Task.checkCancellation()
            let plan = try decodeResponse(data, model: model, id: id)
            try Task.checkCancellation()
            client.markSuccessful(model: model)
            let spoken = plan.steps?.map(\.say).joined(separator: " ") ?? plan.say ?? ""
            history.append(["role": "user", "parts": [["text": prompt]]])
            history.append(["role": "model", "parts": [["text": spoken]]])
            if history.count > 12 { history.removeFirst(history.count - 12) }
            client.record("id=\(id) stage=complete model=\(model) outcome=success elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
            return plan
        } catch is CancellationError {
            client.record("id=\(id) stage=complete outcome=cancelled elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
            throw CancellationError()
        } catch {
            let failure = (error as? GeminiFailure) ?? GeminiFailure.local(.unknown, stage: "request", id: id)
            client.record("id=\(id) stage=complete outcome=failed category=\(failure.category.rawValue) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
            throw failure
        }
    }

    func decodeResponse(_ data: Data, model: String, id: String) throws -> Plan {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiFailure.local(.invalidResponse, stage: "response-decode", model: model, id: id)
        }
        if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
            throw GeminiFailure.local(.blockedResponse, stage: "response-decode", model: model, id: id)
        }
        if let first = (json["candidates"] as? [[String: Any]])?.first,
           ["SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT"].contains(first["finishReason"] as? String ?? "") {
            throw GeminiFailure.local(.blockedResponse, stage: "response-decode", model: model, id: id)
        }
        guard let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let raw = parts.compactMap({ $0["text"] as? String }).first(where: { !$0.isEmpty }) else {
            throw GeminiFailure.local(.emptyResponse, stage: "response-decode", model: model, id: id)
        }
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let bytes = cleaned.data(using: .utf8),
           let plan = try? JSONDecoder().decode(Plan.self, from: bytes),
           !plan.normalizedSteps().allSatisfy({ $0.say.isEmpty }) { return plan }
        if let open = cleaned.firstIndex(of: "{"), let close = cleaned.lastIndex(of: "}"), open < close,
           let bytes = String(cleaned[open...close]).data(using: .utf8),
           let plan = try? JSONDecoder().decode(Plan.self, from: bytes),
           !plan.normalizedSteps().allSatisfy({ $0.say.isEmpty }) { return plan }
        // Legacy prose stays speech-only; malformed actions are never executed.
        if !cleaned.isEmpty && !cleaned.contains("{") {
            return Plan(steps: [Step(say: cleaned, cue: nil, focus: nil, annotations: nil, keep: false)],
                        actions: nil, say: cleaned, points: nil)
        }
        throw GeminiFailure.local(.invalidResponse, stage: "response-decode", model: model, id: id)
    }

    var diagnostics: String { client.diagnostics }

    func healthCheck() async throws -> String {
        let id = String(UUID().uuidString.prefix(8))
        let models: [GeminiModel]
        do { models = try await client.discover(force: true, id: id) }
        catch {
            client.record("id=\(id) stage=health-check outcome=failed")
            throw error
        }
        var vision = "Screenshot preparation unavailable"
        do {
            let capture = try await Screen.capture()
            let (_, width, height) = try buildPayload(prompt: "Health check", image: capture.jpeg, id: id)
            vision = "JPEG ready: \(width)x\(height), \(capture.jpeg.count) bytes (not sent)"
            client.record("id=\(id) stage=vision-check outcome=ready image=\(width)x\(height) imageBytes=\(capture.jpeg.count)")
        } catch {
            vision = "Screenshot preparation failed: \(error.localizedDescription)"
            client.record("id=\(id) stage=vision-check outcome=failed")
        }
        return "Request \(id)\nModel list accepted the key.\nCompatible models: \(models.map(\.id).joined(separator: ", "))\n\(vision)\nGeneration has not been tested."
    }

    func testGeneration() async throws -> String {
        let id = String(UUID().uuidString.prefix(8))
        do {
            let model = try await client.testGeneration(id: id)
            return "Request \(id): generation succeeded with \(model). Image and JSON output were not tested."
        } catch {
            let failure = (error as? GeminiFailure) ?? GeminiFailure.network(error, stage: "generation-test", model: nil, id: id)
            client.record(failure.diagnostic)
            throw failure
        }
    }
}
