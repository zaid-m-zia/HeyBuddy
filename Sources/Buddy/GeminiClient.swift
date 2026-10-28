import Foundation

enum GeminiFailureCategory: String {
    case missingKey, malformedKey, invalidKey, permission, invalidJSONRequest
    case unsupportedParameter, unsupportedFormat, modelNotFound, quota, rateLimit
    case overload, timeout, offline, connectionLost, cancelled
    case emptyResponse, blockedResponse, invalidResponse, noCompatibleModel, unknown
}

struct GeminiFailure: LocalizedError {
    let category: GeminiFailureCategory
    let stage: String
    let model: String?
    let requestID: String
    let httpStatus: Int?
    let googleStatus: String?
    let googleMessage: String?
    let retryAfter: TimeInterval?

    var retryable: Bool {
        [.overload, .timeout, .connectionLost, .rateLimit].contains(category)
    }

    var errorDescription: String? {
        let prefix = "Request \(requestID): "
        switch category {
        case .missingKey, .malformedKey: return prefix + "Set a valid Gemini API key in Settings."
        case .invalidKey: return prefix + "Your Gemini API key was rejected. Check or replace it in Settings."
        case .permission: return prefix + "The key is accepted, but this Gemini resource is not permitted."
        case .invalidJSONRequest, .unsupportedParameter, .unsupportedFormat:
            return prefix + "Gemini rejected the request format. Check diagnostics for the reason."
        case .modelNotFound, .noCompatibleModel: return prefix + "No compatible Gemini model is available for this key."
        case .quota: return prefix + "The available Gemini quota has been reached. Try again after it resets."
        case .rateLimit: return prefix + "Gemini is rate limiting requests. Try again shortly."
        case .overload: return prefix + "Gemini is temporarily unavailable. Try again shortly."
        case .timeout: return prefix + "Gemini took too long to respond. Try again."
        case .offline: return prefix + "There is no internet connection."
        case .connectionLost: return prefix + "The network connection was lost. Try again."
        case .cancelled: return prefix + "Request cancelled."
        case .emptyResponse: return prefix + "Gemini returned an empty response."
        case .blockedResponse: return prefix + "Gemini blocked the response. Try a different question."
        case .invalidResponse: return prefix + "Gemini returned an invalid plan. Try again."
        case .unknown: return prefix + "Gemini failed. Check diagnostics for details."
        }
    }

    var diagnostic: String {
        "id=\(requestID) stage=\(stage) model=\(model ?? "-") category=\(category.rawValue) http=\(httpStatus.map { String($0) } ?? "-") googleStatus=\(googleStatus ?? "-") message=\(googleMessage ?? "-") retryable=\(retryable)"
    }

    static func local(_ category: GeminiFailureCategory, stage: String, model: String? = nil, id: String, message: String? = nil) -> GeminiFailure {
        GeminiFailure(category: category, stage: stage, model: model, requestID: id,
                      httpStatus: nil, googleStatus: nil, googleMessage: message, retryAfter: nil)
    }

    static func network(_ error: Error, stage: String, model: String?, id: String) -> GeminiFailure {
        if error is CancellationError { return local(.cancelled, stage: stage, model: model, id: id) }
        let code = (error as? URLError)?.code
        let category: GeminiFailureCategory
        switch code {
        case .cancelled: category = .cancelled
        case .timedOut: category = .timeout
        case .notConnectedToInternet: category = .offline
        case .networkConnectionLost: category = .connectionLost
        default: category = .unknown
        }
        return local(category, stage: stage, model: model, id: id)
    }

    static func http(_ response: HTTPURLResponse, body: Data, stage: String, model: String?, id: String, key: String) -> GeminiFailure {
        let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let google = envelope?["error"] as? [String: Any]
        let status = google?["status"] as? String
        let message = sanitize(google?["message"] as? String ?? "", key: key)
        let lower = message.lowercased()
        let code = response.statusCode
        let category: GeminiFailureCategory
        if lower.contains("api key not valid") || lower.contains("api_key_invalid") || lower.contains("invalid api key") {
            category = .invalidKey
        } else if code == 401 {
            category = .invalidKey
        } else if code == 403 {
            category = .permission
        } else if code == 404 && stage.hasPrefix("generation") {
            category = .modelNotFound
        } else if code == 400 {
            if lower.contains("responsemimetype") || lower.contains("response mime") || lower.contains("structured output") {
                category = .unsupportedFormat
            } else if lower.contains("thinkingconfig") || lower.contains("thinkinglevel") || lower.contains("unknown name") || lower.contains("unsupported") {
                category = .unsupportedParameter
            } else {
                category = .invalidJSONRequest
            }
        } else if code == 429 {
            category = lower.contains("quota") || lower.contains("daily limit") ? .quota : .rateLimit
        } else if [500, 502, 503, 504].contains(code) {
            category = .overload
        } else {
            category = .unknown
        }
        let headerDelay = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let details = google?["details"] as? [[String: Any]] ?? []
        let metadataDelay = details.compactMap { detail -> TimeInterval? in
            guard let value = detail["retryDelay"] as? String, value.hasSuffix("s") else { return nil }
            return TimeInterval(value.dropLast())
        }.first
        let retryAfter = headerDelay ?? metadataDelay
        return GeminiFailure(category: category, stage: stage, model: model, requestID: id,
                             httpStatus: code, googleStatus: status, googleMessage: message, retryAfter: retryAfter)
    }

    static func sanitize(_ raw: String, key: String) -> String {
        var clean = raw.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        if !key.isEmpty { clean = clean.replacingOccurrences(of: key, with: "[redacted]") }
        for pattern in ["(?i)key\\s*[:=]\\s*[^\\s,;]+", "https?://[^\\s]+", "AIza[A-Za-z0-9_-]{20,}"] {
            clean = clean.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(clean.prefix(240))
    }
}

struct GeminiModel: Equatable {
    let name: String // The complete resource name, e.g. models/gemini-3.8-flash.
    let methods: Set<String>

    var id: String { String(name.dropFirst("models/".count)) }

    static func parsePage(_ data: Data) throws -> ([GeminiModel], String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["models"] as? [[String: Any]] else {
            throw GeminiFailure.local(.invalidResponse, stage: "discovery", id: "discovery")
        }
        let models = raw.compactMap { entry -> GeminiModel? in
            guard let name = entry["name"] as? String,
                  name.hasPrefix("models/"),
                  let methods = entry["supportedGenerationMethods"] as? [String] else { return nil }
            return GeminiModel(name: name, methods: Set(methods))
        }
        return (models, json["nextPageToken"] as? String)
    }
}

@MainActor
final class GeminiClient {
    // These exact model names are documented to accept image input and structured output.
    // models.list validates availability and generateContent support for this key.
    static let preferredIDs = ["gemini-3.5-flash", "gemini-3.8-flash", "gemini-3.1-flash-lite"]
    private let session: URLSession
    private let keyProvider: GeminiKeyProvider
    private var cachedModels: [GeminiModel] = []
    private var cacheDate: Date?
    private var cacheKey = ""
    private var preferredID: String?
    private var cooldownUntil: [String: Date] = [:]
    private(set) var discoverySource = "none"
    private var records: [String] = []

    init(keyProvider: GeminiKeyProvider = Settings.keyProvider, session: URLSession? = nil) {
        self.keyProvider = keyProvider
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 12
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    func record(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
        records.append(line)
        if records.count > 100 { records.removeFirst(records.count - 100) }
        blogInfo("[GEMINI] \(line)")
    }

    var diagnostics: String { records.joined(separator: "\n") }

    private func currentKey(id: String) throws -> String {
        do { return try keyProvider.requireKey() }
        catch let error as GeminiKeyError {
            throw GeminiFailure.local(error == .missing ? .missingKey : .malformedKey, stage: "key", id: id)
        }
    }

    private func resetIfKeyChanged(_ key: String) {
        guard cacheKey != key else { return }
        cacheKey = key
        cachedModels = []
        cacheDate = nil
        preferredID = nil
        cooldownUntil = [:]
    }

    static func compatible(_ models: [GeminiModel]) -> [GeminiModel] {
        let byID = models.reduce(into: [String: GeminiModel]()) { result, model in result[model.id] = model }
        return preferredIDs.compactMap { id in
            guard let model = byID[id], model.methods.contains("generateContent") else { return nil }
            return model
        }
    }

    func discover(force: Bool = false, id: String, deadline: Date? = nil) async throws -> [GeminiModel] {
        let key = try currentKey(id: id)
        resetIfKeyChanged(key)
        if !force, let date = cacheDate, Date().timeIntervalSince(date) < 6 * 3600, !cachedModels.isEmpty {
            discoverySource = "cached"
            record("id=\(id) stage=discovery source=cached candidates=\(cachedModels.count)")
            return cachedModels
        }
        var all: [GeminiModel] = []
        var token: String?
        var seenTokens: Set<String> = []
        do {
            for page in 0..<20 {
                try Task.checkCancellation()
                let remaining = deadline.map { $0.timeIntervalSinceNow } ?? 12
                guard remaining > 0.5 else { throw GeminiFailure.local(.timeout, stage: "discovery-budget", id: id) }
                guard var parts = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models") else {
                    throw GeminiFailure.local(.invalidJSONRequest, stage: "discovery", id: id)
                }
                if let token { parts.queryItems = [URLQueryItem(name: "pageToken", value: token)] }
                guard let url = parts.url else { throw GeminiFailure.local(.invalidJSONRequest, stage: "discovery", id: id) }
                var request = URLRequest(url: url)
                request.timeoutInterval = min(12, remaining)
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw GeminiFailure.local(.invalidResponse, stage: "discovery", id: id) }
                if http.statusCode != 200 { throw GeminiFailure.http(http, body: data, stage: "discovery", model: nil, id: id, key: key) }
                let (models, next) = try GeminiModel.parsePage(data)
                all.append(contentsOf: models)
                record("id=\(id) stage=discovery page=\(page + 1) http=200 models=\(models.count)")
                guard let next, !next.isEmpty else { break }
                guard seenTokens.insert(next).inserted else { throw GeminiFailure.local(.invalidResponse, stage: "discovery", id: id) }
                token = next
                if page == 19 { throw GeminiFailure.local(.invalidResponse, stage: "discovery", id: id) }
            }
        } catch {
            let failure = (error as? GeminiFailure) ?? GeminiFailure.network(error, stage: "discovery", model: nil, id: id)
            record(failure.diagnostic)
            if [.offline, .connectionLost].contains(failure.category),
               let date = cacheDate, Date().timeIntervalSince(date) < 24 * 3600, !cachedModels.isEmpty {
                discoverySource = "stale offline cache"
                return cachedModels
            }
            throw failure
        }
        let compatible = Self.compatible(all)
        guard !compatible.isEmpty else { throw GeminiFailure.local(.noCompatibleModel, stage: "discovery", id: id) }
        cachedModels = compatible
        cacheDate = Date()
        discoverySource = "fresh"
        record("id=\(id) stage=discovery source=fresh candidates=\(compatible.map(\.id).joined(separator: ","))")
        return compatible
    }

    private func ordered(_ models: [GeminiModel]) -> [GeminiModel] {
        var result = models
        if let preferredID, let index = result.firstIndex(where: { $0.id == preferredID }) {
            result.insert(result.remove(at: index), at: 0)
        }
        return result.filter { cooldownUntil[$0.id].map { $0 <= Date() } ?? true }
    }

    func markSuccessful(model: String) {
        preferredID = model
        cooldownUntil.removeValue(forKey: model)
    }

    private func generationRequest(model: GeminiModel, payload: Data, key: String, remaining: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(model.name):generateContent") else {
            throw GeminiFailure.local(.invalidJSONRequest, stage: "request-build", model: model.id, id: "local")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = min(12, remaining)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        return request
    }

    func generate(payload: Data, id: String) async throws -> (Data, String) {
        let key = try currentKey(id: id)
        let started = Date()
        let candidates = ordered(try await discover(id: id, deadline: started.addingTimeInterval(30)))
        guard !candidates.isEmpty else { throw GeminiFailure.local(.overload, stage: "selection", id: id) }
        var attempts = 0
        var lastFailure: GeminiFailure?
        for model in candidates {
            var retried = false
            while attempts < 3 {
                try Task.checkCancellation()
                let remaining = 30 - Date().timeIntervalSince(started)
                guard remaining > 0.5 else { throw GeminiFailure.local(.timeout, stage: "budget", model: model.id, id: id) }
                attempts += 1
                let request = try generationRequest(model: model, payload: payload, key: key, remaining: remaining)
                record("id=\(id) stage=generation model=\(model.id) attempt=\(attempts) payloadBytes=\(payload.count) source=\(discoverySource)")
                do {
                    let (data, response) = try await session.data(for: request)
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse else { throw GeminiFailure.local(.invalidResponse, stage: "generation", model: model.id, id: id) }
                    if http.statusCode != 200 { throw GeminiFailure.http(http, body: data, stage: "generation", model: model.id, id: id, key: key) }
                    record("id=\(id) stage=generation model=\(model.id) http=200 elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
                    return (data, model.id)
                } catch {
                    let failure = (error as? GeminiFailure) ?? GeminiFailure.network(error, stage: "generation", model: model.id, id: id)
                    record(failure.diagnostic)
                    if failure.category == .cancelled { throw CancellationError() }
                    lastFailure = failure
                    if failure.category == .modelNotFound {
                        cachedModels.removeAll { $0.id == model.id }
                        cacheDate = nil
                        break
                    }
                    if failure.category == .overload { cooldownUntil[model.id] = Date().addingTimeInterval(30) }
                    if failure.category == .rateLimit { cooldownUntil[model.id] = Date().addingTimeInterval(max(30, failure.retryAfter ?? 30)) }
                    if failure.retryable && !retried && attempts < 3 {
                        let wait = failure.retryAfter ?? Double.random(in: 0.5...1.0)
                        if wait <= 2, 30 - Date().timeIntervalSince(started) > wait + 1 {
                            retried = true
                            record("id=\(id) stage=retry model=\(model.id) reason=\(failure.category.rawValue) delayMs=\(Int(wait * 1000))")
                            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                            continue
                        }
                    }
                    if failure.category == .overload || failure.category == .timeout || failure.category == .connectionLost { break }
                    throw failure // Includes quota, key, permission, format, and rate limits.
                }
            }
        }
        throw lastFailure ?? GeminiFailure.local(.noCompatibleModel, stage: "selection", id: id)
    }

    func testGeneration(id: String) async throws -> String {
        let key = try currentKey(id: id)
        guard let model = ordered(try await discover(id: id)).first else {
            throw GeminiFailure.local(.noCompatibleModel, stage: "selection", id: id)
        }
        let payload = try JSONSerialization.data(withJSONObject: ["contents": [["role": "user", "parts": [["text": "Reply with OK."]]]]])
        let request = try generationRequest(model: model, payload: payload, key: key, remaining: 12)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw GeminiFailure.network(error, stage: "generation-test", model: model.id, id: id) }
        guard let http = response as? HTTPURLResponse else { throw GeminiFailure.local(.invalidResponse, stage: "generation-test", model: model.id, id: id) }
        if http.statusCode != 200 { throw GeminiFailure.http(http, body: data, stage: "generation-test", model: model.id, id: id, key: key) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              parts.contains(where: { ($0["text"] as? String)?.isEmpty == false }) else {
            throw GeminiFailure.local(.emptyResponse, stage: "generation-test", model: model.id, id: id)
        }
        record("id=\(id) stage=generation-test model=\(model.id) http=200")
        return model.id
    }
}
