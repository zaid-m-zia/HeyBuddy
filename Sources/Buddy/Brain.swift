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
// MARK: - Keychain-backed API key storage (Stage 9)
// ---------------------------------------------------------------------------

enum KeychainStore {
    private static let service = "com.example.buddy"
    private static let account = "gemini-api-key"

    static var apiKey: String {
        get { load() ?? "" }
        set { save(newValue) }
    }

    private static func load() -> String? {
        let q: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  service,
            kSecAttrAccount:  account,
            kSecReturnData:   true,
            kSecMatchLimit:   kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        if SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// One-time migration: move any existing value from UserDefaults "key" → Keychain.
    static func migrateFromUserDefaults() {
        guard let old = UserDefaults.standard.string(forKey: "key"), !old.isEmpty else { return }
        if (load() ?? "").isEmpty { save(old) }
        UserDefaults.standard.removeObject(forKey: "key")
        blogInfo("[SETTINGS] Migrated API key UserDefaults → Keychain")
    }
}

// ---------------------------------------------------------------------------
// MARK: - Settings
// ---------------------------------------------------------------------------

enum Settings {
    static var name: String {
        get { UserDefaults.standard.string(forKey: "name") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "name") }
    }
    static var apiKey: String {
        get  { KeychainStore.apiKey }
        set  { KeychainStore.apiKey = newValue }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Shared model types
// ---------------------------------------------------------------------------

struct Point:  Codable { var x: Double; var y: Double; var label: String? }
struct Action: Codable { var tool: String; var arg: String; var why: String? }
struct Plan:   Codable { var say: String; var points: [Point]?; var actions: [Action]? }

// ---------------------------------------------------------------------------
// MARK: - Brain
// ---------------------------------------------------------------------------

final class Brain {
    // Product requirement: do NOT change these names. They are validated at startup.
    static let configuredModels = ["gemini-3.8-flash", "gemini-3.5-flash", "gemini-3.1-flash-lite"]

    /// Index into configuredModels: start with the last model that succeeded.
    private var preferredModelIndex = 0

    /// Text-only conversation history. Images are NOT stored (they are huge).
    /// Capped at 12 turns (6 exchanges).
    var history: [[String: Any]] = []

    /// Stage 6: private session – tight timeouts, no shared-session contention.
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest  = 15   // per-request limit
        c.timeoutIntervalForResource = 25   // total resource limit
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
        You get a screenshot, what the user said, and info about their cursor gesture. Coordinates are on a
        0-1000 grid over the screenshot, origin top-left, x right, y down.
        Reply with ONLY JSON: {"say": string, "points": [{"x":number,"y":number,"label":string}], "actions": [{"tool":"applescript"|"shell"|"open","arg":string,"why":string}]}
        Rules:
        - "say" is spoken aloud: warm, short, conversational, no markdown.
        - If the user wants to learn or understand something on screen, put points in the order you explain them (label = 1-4 words) and narrate them in "say".
        - If the user circled or pointed at something, that is what they mean by "this" / "these".
        - If the user wants something DONE, put the steps in "actions" (macOS: zsh commands, AppleScript for Finder/apps, or open). Absolute paths, ~ for home. Finder selection: tell application "Finder" to get selection. Make "why" plain English. The user confirms before anything runs.
        - Never invent things you can't see. If unsure, ask a short clarifying question in "say" with empty points/actions.
        - Leave "points" and "actions" empty when not needed.
        """
    }

    // -------------------------------------------------------------------------
    // MARK: Main ask – called from AppDelegate inside a Task (Stages 1, 6)
    // -------------------------------------------------------------------------

    func ask(text: String, image: Data, gesture: String) async throws -> Plan {
        try Task.checkCancellation()

        let requestStart = ContinuousClock.now
        let prompt = gesture.isEmpty
            ? "User said: \(text)"
            : "User said: \(text)\nCursor gesture while speaking: \(gesture)"

        // Build JSON body ONCE before any retry (Stage 6 – avoids re-encoding base64).
        let userTurn: [String: Any] = ["role": "user", "parts": [
            ["text": prompt],
            ["inline_data": ["mime_type": "image/jpeg", "data": image.base64EncodedString()]]
        ]]
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt()]]],
            "contents":          history + [userTurn],
            "generationConfig":  ["responseMimeType": "application/json"]
        ]
        let payload: Data
        do { payload = try JSONSerialization.data(withJSONObject: body) } catch {
            throw buddyError("Failed to build request: \(error.localizedDescription)")
        }
        blogDebug("[BRAIN] payload \(payload.count / 1024) KB")

        // Try preferred model first, then the others.
        let orderedIndices: [Int] = {
            var idx = Array(Brain.configuredModels.indices)
            if preferredModelIndex < idx.count {
                idx.remove(at: preferredModelIndex)
                idx.insert(preferredModelIndex, at: 0)
            }
            return idx
        }()

        let totalBudget: Duration = .seconds(20)
        var lastError = "Unknown error"
        var backoffNs: UInt64 = 400_000_000   // starts at 0.4 s, doubles on each use

        for modelIdx in orderedIndices {
            let model = Brain.configuredModels[modelIdx]

            for attempt in 0..<2 {
                try Task.checkCancellation()

                // Hard wall-clock budget guard.
                if ContinuousClock.now - requestStart >= totalBudget {
                    blogError("[BRAIN] Budget exceeded after \(Int((ContinuousClock.now - requestStart).components.seconds))s")
                    throw buddyError("Request took too long. Try again.")
                }

                let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(Settings.apiKey)"
                guard let url = URL(string: urlStr) else { continue }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = payload

                blogInfo("[BRAIN] \(RequestClock.shared.elapsed) → \(model) attempt \(attempt + 1)")

                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: req)
                } catch let urlErr as URLError {
                    blogError("[BRAIN] URLError \(urlErr.code.rawValue): \(urlErr.localizedDescription)")
                    if urlErr.code == .cancelled { throw CancellationError() }
                    if urlErr.code == .notConnectedToInternet {
                        throw buddyError("No internet connection.")
                    }
                    if [.timedOut, .networkConnectionLost].contains(urlErr.code) {
                        lastError = "Request timed out. Try again."
                        try await jitteredSleep(&backoffNs)
                        continue
                    }
                    throw buddyError("Network error. Try again.")
                }

                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let elapsedMs = Int((ContinuousClock.now - requestStart).components.seconds * 1000)
                blogInfo("[BRAIN] \(RequestClock.shared.elapsed) ← \(model) HTTP \(code) (\(elapsedMs) ms total)")

                switch code {
                case 200:
                    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let cands = j["candidates"] as? [[String: Any]],
                          let first = cands.first,
                          let parts = (first["content"] as? [String: Any])?["parts"] as? [[String: Any]],
                          let raw = parts.first?["text"] as? String else {
                        blogError("[BRAIN] \(model) 200 OK but no text in response body")
                        throw buddyError("Empty reply from model. Try again.")
                    }
                    let plan = try decodePlan(from: raw)
                    // Text-only history entry (Stage 6).
                    history.append(["role": "user",  "parts": [["text": prompt]]])
                    history.append(["role": "model", "parts": [["text": raw]]])
                    if history.count > 12 { history.removeFirst(history.count - 12) }
                    preferredModelIndex = modelIdx
                    blogInfo("[BRAIN] \(RequestClock.shared.elapsed) ✓ say='\(plan.say.prefix(60))' pts=\(plan.points?.count ?? 0) acts=\(plan.actions?.count ?? 0)")
                    return plan

                case 400, 401, 403:
                    let errBody = String(data: data, encoding: .utf8) ?? ""
                    blogError("[BRAIN] \(model) HTTP \(code): \(errBody.prefix(200))")
                    throw buddyError(code == 400
                        ? "Bad request to Gemini. Check your prompt."
                        : "Check your Gemini API key.")

                case 404:
                    blogWarn("[BRAIN] \(model) HTTP 404 – model not found, skipping to next")
                    lastError = "\(model) returned 404"
                    // Break inner loop to move to next model.
                    break

                case 429, 500, 502, 503, 504:
                    let errBody = String(data: data, encoding: .utf8) ?? ""
                    blogWarn("[BRAIN] \(model) HTTP \(code) retryable. \(errBody.prefix(120))")
                    lastError = "Google's servers are busy. Try again."
                    try await jitteredSleep(&backoffNs)
                    continue

                default:
                    let errBody = String(data: data, encoding: .utf8) ?? ""
                    blogError("[BRAIN] \(model) HTTP \(code): \(errBody.prefix(200))")
                    lastError = "Unexpected error (\(code)) from Gemini."
                    break
                }
                break   // 404/default: stop inner loop, try next model
            }
        }

        blogError("[BRAIN] All models exhausted. Last: \(lastError)")
        throw buddyError(lastError)
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
        // If it looks like prose (not JSON), speak it directly.
        if !cleaned.hasPrefix("{") {
            blogWarn("[BRAIN] Model returned prose; speaking it directly.")
            return Plan(say: cleaned, points: nil, actions: nil)
        }
        blogError("[BRAIN] JSON decode failed. raw=\(raw.prefix(300))")
        throw buddyError("Couldn't parse the model's reply. Please try again.")
    }

    // -------------------------------------------------------------------------
    // MARK: Helpers
    // -------------------------------------------------------------------------

    private func jitteredSleep(_ ns: inout UInt64) async throws {
        try Task.checkCancellation()
        let jitter = UInt64.random(in: 0..<100_000_000)
        try await Task.sleep(nanoseconds: ns + jitter)
        ns = min(ns * 2, 2_000_000_000)   // cap at 2 s
    }

    private func buddyError(_ m: String) -> NSError {
        NSError(domain: "Buddy", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}
