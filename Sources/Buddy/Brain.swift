import Foundation

struct Point: Codable { var x: Double; var y: Double; var label: String? }
struct Action: Codable { var tool: String; var arg: String; var why: String? }
struct Plan: Codable { var say: String; var points: [Point]?; var actions: [Action]? }

enum Settings {
    static var name: String {
        get { UserDefaults.standard.string(forKey: "name") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "name") }
    }
    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: "key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "key") }
    }
}

final class Brain {
    var history: [[String: Any]] = []
    let models = ["gemini-3.8-flash", "gemini-3.5-flash", "gemini-3.1-flash-lite"]
    
    func system() -> String {
        """
        You are \(Settings.name), a friendly AI buddy that lives next to the user's mouse cursor on macOS.
        You get a screenshot, what the user said, and info about their cursor gesture. Coordinates are on a
        0-1000 grid over the screenshot, origin top-left, x right, y down.
        Reply with ONLY JSON: {"say": string, "points": [{"x":number,"y":number,"label":string}], "actions": [{"tool":"applescript"|"shell"|"open","arg":string,"why":string}]}
        Rules:
        - "say" is spoken aloud: warm, short, conversational, no markdown.
        - If the user wants to learn or understand something on screen, put points in the order you explain them (label = 1-4 words) and narrate them in "say".
        - If the user circled or pointed at something, that is what they mean by "this" / "these".
        - If the user wants something DONE, put the steps in "actions" (macOS: zsh commands, AppleScript for Finder/apps, or open). Use absolute paths, ~ for home. Finder selection: tell application "Finder" to get selection. Make the "why" a plain-English summary. The user confirms before anything runs.
        - Never invent things you can't see. If unsure, ask a short clarifying question in "say" with empty points/actions.
        - Leave "points" and "actions" empty when not needed.
        """
    }

    func ask(text: String, image: Data, gesture: String) async throws -> Plan {
        var prompt = "User said: \(text)"
        if !gesture.isEmpty { prompt += "\nCursor gesture while speaking: \(gesture)" }
        let user: [String: Any] = ["role": "user", "parts": [
            ["text": prompt],
            ["inline_data": ["mime_type": "image/jpeg", "data": image.base64EncodedString()]]
        ]]
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system()]]],
            "contents": history + [user],
            "generationConfig": ["responseMimeType": "application/json"]
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        var lastError = "Unknown error"

        for model in models {
            for attempt in 0..<2 {
                let url = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(Settings.apiKey)"
                var req = URLRequest(url: URL(string: url)!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = payload
                req.timeoutInterval = 60
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0

                if code == 200 {
                    guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let c = (j["candidates"] as? [[String: Any]])?.first,
                          let parts = (c["content"] as? [String: Any])?["parts"] as? [[String: Any]],
                          let t = parts.first?["text"] as? String else { throw err("Empty reply from model") }
                    let plan = try JSONDecoder().decode(Plan.self, from: Data(t.utf8))
                    history.append(["role": "user", "parts": [["text": prompt]]])
                    history.append(["role": "model", "parts": [["text": t]]])
                    if history.count > 12 { history.removeFirst(history.count - 12) }
                    print("Used model:", model)
                    return plan
                }

                lastError = "\(model) → \(code): " + String((String(data: data, encoding: .utf8) ?? "").prefix(150))
                print(lastError)
                if [400, 401, 403].contains(code) { throw err(lastError) }   // bad key / bad request: don't retry
                if code == 404 { break }                                     // model not found: next model
                try await Task.sleep(nanoseconds: 800_000_000)               // 429/500/503: retry, then next model
            }
        }
        throw err(lastError)
    }

    func err(_ m: String) -> NSError {
        NSError(domain: "Buddy", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}
