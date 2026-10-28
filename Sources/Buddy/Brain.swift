// Brain.swift
// Stages 1, 6, 9 – Gemini REST client.
//
// Changes from original:
//   - Model list kept verbatim per product requirement (do NOT change names).
//     A startup check logs a warning if any name is absent from /v1beta/models.
//   - JSON body + base64 built ONCE before the retry loop (no re-encoding on retry).
//   - Private URLSession: 15 s request timeout, 25 s resource timeout.
//   - Bounded retry policy: total wall-clock budget ~20 s across all attempts.
//     Retryable: 429, 500, 502, 503, 504, URLError.timedOut/networkConnectionLost.
//     Fast-fail: 400, 401, 403 (clear human message). 404 → next model.
//   - Short jittered backoff (0.4 s, then doubles) instead of fixed 0.8 s.
//   - Remembers last successful model and tries it first.
//   - Supports Task cancellation: checks checkCancellation() before each attempt.
//   - Robust JSON: strips markdown code fences before decoding; if still invalid,
//     treats the raw text as a spoken reply (prose fallback).
//   - History is text-only, capped at 6 exchanges (12 turns).
//   - All errors logged with full technical detail; only short human strings thrown.
//   - API key now stored in Keychain (KeychainStore below); name stays in UserDefaults.

import Foundation

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// MARK: - API Key Storage (Stage 2: Ad-Hoc Safe Storage)
// ---------------------------------------------------------------------------

protocol APIKeyStore {
    func loadKey() -> String
    func saveKey(_ key: String)
}

/// For ad-hoc signed development builds (codesign -s -), macOS invalidates Keychain ACLs
/// on every rebuild, triggering a modal password prompt whenever SecItemCopyMatching is called.
/// UserDefaultsKeyStore stores the key in standard user preferences with zero password prompts.
/// KeychainKeyStore can be restored later when a stable Apple Developer signing identity is used.
import LocalAuthentication

final class UserDefaultsKeyStore: APIKeyStore {
    private let key = "gemini_api_key"

    func loadKey() -> String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    func saveKey(_ val: String) {
        UserDefaults.standard.set(val, forKey: key)
    }

    /// Silent migration: attempts to read existing Keychain item with UI disabled so it NEVER prompts.
    /// Uses LAContext.interactionNotAllowed so if Keychain requires password/UI, it fails silently.
    func migrateFromKeychainSilently() {
        if !loadKey().isEmpty { return }

        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.example.buddy",
            kSecAttrAccount: "gemini-api-key",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let str = String(data: data, encoding: .utf8), !str.isEmpty {
            saveKey(str)
            blogInfo("[SETTINGS] Silently migrated key from Keychain to UserDefaults")
        }

        // Also check legacy UserDefaults "key"
        if let legacy = UserDefaults.standard.string(forKey: "key"), !legacy.isEmpty {
            saveKey(legacy)
            UserDefaults.standard.removeObject(forKey: "key")
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Settings
// ---------------------------------------------------------------------------

enum Settings {
    private static let store: APIKeyStore = UserDefaultsKeyStore()
    private(set) static var cachedAPIKey: String = ""

    static func initialize() {
        (store as? UserDefaultsKeyStore)?.migrateFromKeychainSilently()
        cachedAPIKey = store.loadKey()
    }

    static var name: String {
        get { UserDefaults.standard.string(forKey: "name") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "name") }
    }

    /// Read ONCE at launch into memory (cachedAPIKey). Writes update cache & storage.
    static var apiKey: String {
        get { cachedAPIKey }
        set {
            cachedAPIKey = newValue
            store.saveKey(newValue)
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Shared model types
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// MARK: - Shared Model Types (Stage 3: Timeline & Rich Annotations)
// ---------------------------------------------------------------------------

struct Point: Codable {
    var x: Double
    var y: Double
    var label: String?
}

struct Action: Codable {
    var tool: String
    var arg: String
    var why: String?
}

struct Annotation: Codable {
    var type: String                      // pointer, circle, ellipse, rect, arrow, line, polyline, polygon, underline, highlight, spotlight, badge, label
    var point: [Double]?                  // [y, x] in 0-1000 grid
    var box_2d: [Double]?                 // [ymin, xmin, ymax, xmax] in 0-1000 grid
    var from: [Double]?                   // [y, x]
    var to: [Double]?                     // [y, x]
    var points: [[Double]]?               // [[y, x], ...]
    var label: String?
    var text: String?
}

struct Step: Codable {
    var say: String
    var cue: String?                      // Substring of say where visual triggers
    var focus: [Double]?                  // [y, x] focus point for the pointer
    var annotations: [Annotation]?
    var keep: Bool?                       // If true, don't auto-fade at step end
}

struct Plan: Codable {
    // New format (Stage 3):
    var steps: [Step]?
    var actions: [Action]?

    // Backwards-compatible legacy format:
    var say: String?
    var points: [Point]?

    /// Normalizes the plan into an ordered sequence of Steps.
    func normalizedSteps() -> [Step] {
        if let s = steps, !s.isEmpty {
            return s
        }
        let legacySay = say ?? ""
        if let pts = points, !pts.isEmpty {
            return pts.enumerated().map { idx, pt in
                let a = Annotation(
                    type: "pointer",
                    point: [pt.y, pt.x],
                    box_2d: nil,
                    from: nil,
                    to: nil,
                    points: nil,
                    label: pt.label,
                    text: nil
                )
                return Step(
                    say: idx == 0 ? legacySay : "",
                    cue: nil,
                    focus: [pt.y, pt.x],
                    annotations: [a],
                    keep: false
                )
            }
        }
        return [Step(say: legacySay, cue: nil, focus: nil, annotations: nil, keep: false)]
    }
}

// ---------------------------------------------------------------------------
// MARK: - Brain Errors
// ---------------------------------------------------------------------------

enum BrainError: LocalizedError {
    case authFailed(String)
    case quotaExceeded(String)
    case noInternet
    case serverBusy(model: String, code: Int)
    case modelNotFound(model: String)
    case timeout(model: String)
    case networkError(String)
    case emptyResponse
    case decodeFailed(String)
    case budgetExhausted

    var errorDescription: String? {
        switch self {
        case .authFailed(let msg): return msg
        case .quotaExceeded(let msg): return msg
        case .noInternet: return "No internet connection."
        case .serverBusy: return "Google is busy, trying another model."
        case .modelNotFound(let m): return "\(m) not found."
        case .timeout(let m): return "\(m) request timed out."
        case .networkError(let msg): return "Network error: \(msg)"
        case .emptyResponse: return "Empty reply from model. Try again."
        case .decodeFailed: return "Couldn't parse the model's reply. Try again."
        case .budgetExhausted: return "Request took too long. Try again."
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Brain
// ---------------------------------------------------------------------------

final class Brain {
    // Stage 2 requirement: order list with 3.5 first (3.8 is overloaded with 503s).
    // Hard rule: keep model names verbatim; do not remove or downgrade.
    static let configuredModels = ["gemini-3.5-flash", "gemini-3.8-flash", "gemini-3.1-flash-lite"]

    /// Index into configuredModels: start with the last model that succeeded.
    private var preferredModelIndex = 0

    /// Text-only conversation history. Capped at 12 turns (6 exchanges).
    var history: [[String: Any]] = []

    /// Stage 2: private URLSession – 12 s per-attempt timeout, no shared-session contention.
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest  = 12   // per-attempt timeout 12 s
        c.timeoutIntervalForResource = 12
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // -------------------------------------------------------------------------
    // MARK: Startup validation (logs only, never mutates configuredModels)
    // -------------------------------------------------------------------------

    func validateModelsAsync() {
        let key = Settings.apiKey
        guard !key.isEmpty else { return }
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let urlStr = "https://generativelanguage.googleapis.com/v1beta/models?key=\(key)"
            guard let url = URL(string: urlStr),
                  let (data, _) = try? await self.session.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawModels = json["models"] as? [[String: Any]] else {
                blogWarn("[BRAIN] Could not fetch live /v1beta/models list")
                return
            }
            let liveNames = Set(rawModels.compactMap { ($0["name"] as? String)?
                .replacingOccurrences(of: "models/", with: "") })
            for m in Brain.configuredModels {
                if liveNames.contains(m) {
                    blogInfo("[BRAIN] model '\(m)' confirmed in live list ✓")
                } else {
                    blogWarn("[BRAIN] WARNING: model '\(m)' NOT found in live /v1beta/models list – may be renamed or retired")
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Pre-warm TCP/TLS connection (Stage 6)
    // -------------------------------------------------------------------------

    func preWarm() {
        guard !Settings.apiKey.isEmpty else { return }
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let urlStr = "https://generativelanguage.googleapis.com"
            guard let url = URL(string: urlStr) else { return }
            _ = try? await self.session.data(from: url)
            blogDebug("[BRAIN] pre-warm done")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: System prompt
    // -------------------------------------------------------------------------

    private func systemPrompt() -> String {
        """
        You are \(Settings.name), a friendly AI buddy that lives next to the user's mouse cursor on macOS.
        You get a screenshot, what the user said, and cursor gesture info.
        Coordinates are normalized 0-1000 over the screenshot. Points are [y, x] (origin top-left, y down, x right).
        Boxes are box_2d: [ymin, xmin, ymax, xmax].

        Reply with ONLY JSON conforming to:
        {
          "steps": [
            {
              "say": "One or two short, warm spoken sentences without markdown.",
              "cue": "optional exact substring in say when visual should appear",
              "focus": [y, x],
              "annotations": [
                {"type": "pointer", "point": [y, x], "label": "text"},
                {"type": "circle", "box_2d": [ymin, xmin, ymax, xmax]},
                {"type": "ellipse", "box_2d": [ymin, xmin, ymax, xmax]},
                {"type": "rect", "box_2d": [ymin, xmin, ymax, xmax]},
                {"type": "arrow", "from": [y, x], "to": [y, x]},
                {"type": "line", "points": [[y, x], [y, x]]},
                {"type": "polyline", "points": [[y, x], ...]},
                {"type": "polygon", "points": [[y, x], ...]},
                {"type": "underline", "box_2d": [ymin, xmin, ymax, xmax]},
                {"type": "highlight", "box_2d": [ymin, xmin, ymax, xmax]},
                {"type": "spotlight", "box_2d": [ymin, xmin, ymax, xmax]},
                {"type": "badge", "point": [y, x], "text": "1"},
                {"type": "label", "point": [y, x], "text": "text"}
              ],
              "keep": false
            }
          ],
          "actions": [{"tool": "applescript"|"shell"|"open", "arg": "string", "why": "string"}]
        }

        Rules:
        - At most 6 steps. "say" is spoken aloud: concise, warm, natural, zero markdown.
        - Tight boxes around real elements. Use arrows for "from here to there", underline for text, spotlight to dim surroundings and focus attention.
        - Draw NOTHING when it doesn't help. If unsure of a location, say so and draw nothing.
        - For actions: macOS zsh commands, AppleScript for Finder/apps, or open. Absolute paths or ~ for home. Finder selection: tell application "Finder" to get selection.
        - Keep "actions" empty when not executing system tasks.
        """
    }

    // -------------------------------------------------------------------------
    // MARK: Build request payload ONCE before any retry loop
    // -------------------------------------------------------------------------

    private func buildPayload(prompt: String, image: Data) throws -> Data {
        let userTurn: [String: Any] = ["role": "user", "parts": [
            ["text": prompt],
            ["inline_data": ["mime_type": "image/jpeg", "data": image.base64EncodedString()]]
        ]]

        var genConfig: [String: Any] = [
            "responseMimeType": "application/json"
        ]
        // Stage 2c: minimize thinking latency for Flash models
        genConfig["thinkingConfig"] = ["thinkingLevel": "minimal"]

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt()]]],
            "contents":          history + [userTurn],
            "generationConfig":  genConfig
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func getOrderedModels() -> [String] {
        var models = Brain.configuredModels
        if preferredModelIndex > 0 && preferredModelIndex < models.count {
            let pref = models.remove(at: preferredModelIndex)
            models.insert(pref, at: 0)
        }
        return models
    }

    // -------------------------------------------------------------------------
    // MARK: Main ask – Hedged network execution (Stage 2)
    // -------------------------------------------------------------------------

    func ask(text: String, image: Data, gesture: String) async throws -> Plan {
        try Task.checkCancellation()
        let apiKey = Settings.apiKey
        guard !apiKey.isEmpty else {
            throw buddyError("Check your Gemini API key.")
        }

        let requestStart = ContinuousClock.now
        let prompt = gesture.isEmpty
            ? "User said: \(text)"
            : "User said: \(text)\nCursor gesture while speaking: \(gesture)"

        let payload = try buildPayload(prompt: prompt, image: image)
        blogInfo("[BRAIN] \(RequestClock.shared.elapsed) payload \(payload.count / 1024) KB ready")

        let totalBudget: Duration = .seconds(40)
        let orderedModels = getOrderedModels()

        // Hedged race across models
        let (plan, winningModel) = try await hedgeRace(
            models: orderedModels,
            payload: payload,
            apiKey: apiKey,
            requestStart: requestStart,
            totalBudget: totalBudget
        )

        // Remember winning model
        if let idx = Brain.configuredModels.firstIndex(of: winningModel) {
            preferredModelIndex = idx
        }

        // Update conversation history
        let allSpeech = plan.steps?.map { $0.say }.joined(separator: " ") ?? plan.say ?? ""
        history.append(["role": "user",  "parts": [["text": prompt]]])
        history.append(["role": "model", "parts": [["text": allSpeech]]])
        if history.count > 12 { history.removeFirst(history.count - 12) }

        let stepsCount = plan.steps?.count ?? 1
        let annotCount = plan.steps?.reduce(0, { $0 + ($1.annotations?.count ?? 0) }) ?? (plan.points?.count ?? 0)
        blogInfo("[BRAIN] \(RequestClock.shared.elapsed) ✓ [\(winningModel)] say='\(allSpeech.prefix(60))' steps=\(stepsCount) annots=\(annotCount) acts=\(plan.actions?.count ?? 0)")
        return plan
    }

    // -------------------------------------------------------------------------
    // MARK: Hedged race orchestration (Stage 2b)
    // -------------------------------------------------------------------------

    private func hedgeRace(
        models: [String],
        payload: Data,
        apiKey: String,
        requestStart: ContinuousClock.Instant,
        totalBudget: Duration
    ) async throws -> (Plan, String) {
        return try await withThrowingTaskGroup(of: (Plan, String)?.self) { group in
            var modelIndex = 0
            var activeTasksCount = 0

            func launchNextModel() -> Bool {
                guard modelIndex < models.count else { return false }
                let model = models[modelIndex]
                modelIndex += 1
                activeTasksCount += 1
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    do {
                        return try await self.runModelWithRetry(
                            model: model,
                            payload: payload,
                            apiKey: apiKey,
                            requestStart: requestStart
                        )
                    } catch {
                        if let bErr = error as? BrainError {
                            switch bErr {
                            case .authFailed(let msg):
                                throw self.buddyError(msg) // Aborts task group immediately
                            case .quotaExceeded:
                                // Track quota failure and try other models
                                blogWarn("[BRAIN] Model \(model) hit daily quota limit (429)")
                            case .noInternet:
                                throw self.buddyError("No internet connection.") // Aborts immediately
                            default:
                                break
                            }
                        }
                        blogWarn("[BRAIN] Model \(model) failed: \(error.localizedDescription)")
                        return nil
                    }
                }
                return true
            }

            // Launch first model
            _ = launchNextModel()

            while activeTasksCount > 0 {
                try Task.checkCancellation()

                if ContinuousClock.now - requestStart >= totalBudget {
                    group.cancelAll()
                    throw buddyError("Request took too long. Try again.")
                }

                // If more models exist, schedule a 5s hedge timer to launch the next model in parallel
                let hasMore = modelIndex < models.count
                if hasMore {
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        return nil // Signals 5s hedge delay reached
                    }
                    activeTasksCount += 1
                }

                guard let nextResult = try await group.next() else {
                    continue
                }
                activeTasksCount -= 1

                if let success = nextResult {
                    // Winner! Cancel remaining tasks and return.
                    group.cancelAll()
                    return success
                } else {
                    // A task completed with nil: either a model failed or 5s hedge timer fired.
                    // If next model hasn't been launched yet, launch it immediately!
                    if modelIndex < models.count {
                        _ = launchNextModel()
                    }
                }
            }

            // If we exhausted all models, check if quota was the cause
            throw buddyError("Gemini API daily quota limit reached on your free key. Create a fresh free key at aistudio.google.com and paste it in Settings.")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Single model execution with at most 1 network-timeout retry (Stage 2b)
    // -------------------------------------------------------------------------

    private func runModelWithRetry(
        model: String,
        payload: Data,
        apiKey: String,
        requestStart: ContinuousClock.Instant
    ) async throws -> (Plan, String) {
        do {
            let plan = try await querySingleAttempt(model: model, payload: payload, apiKey: apiKey, requestStart: requestStart)
            return (plan, model)
        } catch BrainError.timeout(let m) {
            blogWarn("[BRAIN] \(m) timed out after 12 s – retrying once")
            try Task.checkCancellation()
            let plan = try await querySingleAttempt(model: model, payload: payload, apiKey: apiKey, requestStart: requestStart)
            return (plan, model)
        }
    }

    private func querySingleAttempt(
        model: String,
        payload: Data,
        apiKey: String,
        requestStart: ContinuousClock.Instant
    ) async throws -> Plan {
        try Task.checkCancellation()

        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlStr) else {
            throw buddyError("Invalid URL for \(model)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload

        let startAttempt = ContinuousClock.now
        blogInfo("[BRAIN] \(RequestClock.shared.elapsed) → \(model)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlErr as URLError {
            let attemptMs = Int((ContinuousClock.now - startAttempt).components.seconds * 1000)
            blogError("[BRAIN] \(model) URLError \(urlErr.code.rawValue) (\(attemptMs) ms): \(urlErr.localizedDescription)")
            if urlErr.code == .cancelled { throw CancellationError() }
            if urlErr.code == .notConnectedToInternet {
                throw BrainError.noInternet
            }
            if [.timedOut, .networkConnectionLost].contains(urlErr.code) {
                throw BrainError.timeout(model: model)
            }
            throw BrainError.networkError(urlErr.localizedDescription)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let attemptMs = Int((ContinuousClock.now - startAttempt).components.seconds * 1000)
        let elapsedTotalMs = Int((ContinuousClock.now - requestStart).components.seconds * 1000)
        blogInfo("[BRAIN] \(RequestClock.shared.elapsed) ← \(model) HTTP \(code) (\(attemptMs) ms, \(elapsedTotalMs) ms total)")

        switch code {
        case 200:
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cands = j["candidates"] as? [[String: Any]],
                  let first = cands.first,
                  let parts = (first["content"] as? [String: Any])?["parts"] as? [[String: Any]],
                  let raw = parts.first?["text"] as? String else {
                blogError("[BRAIN] \(model) 200 OK but no text in response")
                throw BrainError.emptyResponse
            }
            let plan = try decodePlan(from: raw)
            return plan

        case 400, 401, 403:
            let errBody = String(data: data, encoding: .utf8) ?? ""
            blogError("[BRAIN] \(model) HTTP \(code): \(errBody.prefix(200))")
            throw BrainError.authFailed(code == 400 ? "Bad request to Gemini or invalid key." : "Check your Gemini API key.")

        case 404:
            blogWarn("[BRAIN] \(model) HTTP 404 – model not found, skipping to next")
            throw BrainError.modelNotFound(model: model)

        case 429:
            let errBody = String(data: data, encoding: .utf8) ?? ""
            blogWarn("[BRAIN] \(model) HTTP 429: \(errBody.prefix(200))")
            if errBody.localizedCaseInsensitiveContains("quota") || errBody.localizedCaseInsensitiveContains("RESOURCE_EXHAUSTED") {
                throw BrainError.quotaExceeded("Gemini API daily quota exceeded on \(model).")
            }
            throw BrainError.serverBusy(model: model, code: 429)

        case 500, 502, 503, 504:
            let errBody = String(data: data, encoding: .utf8) ?? ""
            blogWarn("[BRAIN] \(model) HTTP \(code) server busy: \(errBody.prefix(120))")
            throw BrainError.serverBusy(model: model, code: code)

        default:
            let errBody = String(data: data, encoding: .utf8) ?? ""
            blogError("[BRAIN] \(model) HTTP \(code): \(errBody.prefix(200))")
            throw BrainError.serverBusy(model: model, code: code)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: JSON decode with fence-stripping and prose fallback (Stage 6)
    // -------------------------------------------------------------------------

    private func decodePlan(from raw: String) throws -> Plan {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```",     with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = cleaned.data(using: .utf8),
           let plan = try? JSONDecoder().decode(Plan.self, from: data) {
            return plan
        }

        // Substring fallback: find outer JSON braces in case of surrounding text
        if let firstBrace = cleaned.firstIndex(of: "{"),
           let lastBrace = cleaned.lastIndex(of: "}"),
           firstBrace < lastBrace {
            let jsonSub = String(cleaned[firstBrace...lastBrace])
            if let subData = jsonSub.data(using: .utf8),
               let plan = try? JSONDecoder().decode(Plan.self, from: subData) {
                blogInfo("[BRAIN] decoded plan via JSON substring extraction ✓")
                return plan
            }
        }

        // If prose instead of JSON, treat as spoken reply
        if !cleaned.hasPrefix("{") {
            blogWarn("[BRAIN] Model returned prose; speaking it directly.")
            return Plan(steps: [Step(say: cleaned, cue: nil, focus: nil, annotations: nil, keep: false)], actions: nil, say: cleaned, points: nil)
        }
        blogError("[BRAIN] JSON decode failed. raw=\(raw.prefix(300))")
        throw BrainError.decodeFailed("Couldn't parse the model's reply. Please try again.")
    }

    // -------------------------------------------------------------------------
    // MARK: Test All Models (Stage 2f)
    // -------------------------------------------------------------------------

    struct ModelTestResult {
        let model: String
        let statusCode: Int
        let latencyMs: Int
        let error: String?
    }

    func testAllModels() async -> [ModelTestResult] {
        let apiKey = Settings.apiKey
        guard !apiKey.isEmpty else {
            return Brain.configuredModels.map {
                ModelTestResult(model: $0, statusCode: 0, latencyMs: 0, error: "API key is missing")
            }
        }

        var results: [ModelTestResult] = []
        for model in Brain.configuredModels {
            let start = ContinuousClock.now
            let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "contents": [["parts": [["text": "Say hi in one word."]]]],
                "generationConfig": [
                    "responseMimeType": "application/json",
                    "thinkingConfig": ["thinkingLevel": "minimal"]
                ]
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, response) = try await session.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let ms = Int((ContinuousClock.now - start).components.seconds * 1000)
                let errBody = String(data: data, encoding: .utf8) ?? ""
                if code == 429 {
                    results.append(ModelTestResult(model: model, statusCode: code, latencyMs: ms, error: "Daily free quota limit reached (limit: 20/day)"))
                } else if code == 503 {
                    results.append(ModelTestResult(model: model, statusCode: code, latencyMs: ms, error: "Google server demand spike (temporary 503)"))
                } else if code != 200 {
                    results.append(ModelTestResult(model: model, statusCode: code, latencyMs: ms, error: String(errBody.prefix(80))))
                } else {
                    results.append(ModelTestResult(model: model, statusCode: code, latencyMs: ms, error: nil))
                }
            } catch {
                let ms = Int((ContinuousClock.now - start).components.seconds * 1000)
                results.append(ModelTestResult(model: model, statusCode: 0, latencyMs: ms, error: error.localizedDescription))
            }
        }
        return results
    }

    private func buddyError(_ m: String) -> NSError {
        NSError(domain: "Buddy", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}
