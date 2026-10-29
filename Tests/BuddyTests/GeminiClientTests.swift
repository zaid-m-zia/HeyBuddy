import XCTest
import AppKit
@testable import Buddy

private final class MemoryKeyStore: APIKeyStore {
    var value = ""
    func loadKey() -> String { value }
    func saveKey(_ key: String) { value = key }
}

private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class GeminiClientTests: XCTestCase {
    private func makeClient(_ provider: GeminiKeyProvider) -> GeminiClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return GeminiClient(keyProvider: provider, session: URLSession(configuration: config))
    }

    func testKeyNormalizationAndImmediateReplacement() throws {
        let store = MemoryKeyStore()
        let provider = GeminiKeyProvider(store: store)
        let first = "AIza111111111111111111111111111111111111111"
        let next = "AIza222222222222222222222222222222222222222"
        try provider.save("  key='\(first)'\n")
        XCTAssertEqual(try provider.requireKey(), first)
        try provider.save(next)
        XCTAssertEqual(try provider.requireKey(), next)
        XCTAssertEqual(store.value, next)
        XCTAssertThrowsError(try provider.save("key=too short"))
    }

    func testPaginationFilteringAndHeaderAuth() async throws {
        let provider = GeminiKeyProvider(store: MemoryKeyStore())
        try provider.save("AIza111111111111111111111111111111111111111")
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), try provider.requireKey())
            XCTAssertFalse(request.url?.absoluteString.contains("key=") ?? true)
            let page2 = request.url?.query?.contains("pageToken=next") == true
            let json = page2
                ? """
                  {"models":[{"name":"models/gemini-3.5-flash","supportedGenerationMethods":["generateContent"]}]}
                  """
                : """
                  {"models":[{"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]},{"name":"models/gemini-3.8-flash","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"next"}
                  """
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badURL)
            }
            return (response, Data(json.utf8))
        }
        let models = try await makeClient(provider).discover(id: "test")
        XCTAssertEqual(models.map(\.id), ["gemini-3.5-flash", "gemini-3.8-flash"])
    }

    func testHTTPClassificationAndRedaction() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let key = "AIza111111111111111111111111111111111111111"
        func classify(_ status: Int, _ message: String) throws -> GeminiFailure {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            let data = try JSONSerialization.data(withJSONObject: ["error": ["message": message, "status": "ERROR"]])
            return GeminiFailure.http(response, body: data, stage: "generation", model: "gemini-3.5-flash", id: "test", key: key)
        }
        XCTAssertEqual(try classify(400, "Unknown name thinkingConfig").category, .unsupportedParameter)
        XCTAssertEqual(try classify(403, "Permission denied").category, .permission)
        XCTAssertEqual(try classify(400, "API key not valid").category, .invalidKey)
        XCTAssertEqual(try classify(404, "Model not found").category, .modelNotFound)
        XCTAssertEqual(try classify(429, "Quota exceeded").category, .quota)
        XCTAssertEqual(try classify(429, "Rate limited").category, .rateLimit)
        XCTAssertEqual(try classify(503, "High demand").category, .overload)
        XCTAssertFalse(try classify(400, key).diagnostic.contains(key))
        XCTAssertEqual(GeminiFailure.network(URLError(.timedOut), stage: "test", model: nil, id: "test").category, .timeout)
        XCTAssertEqual(GeminiFailure.network(URLError(.notConnectedToInternet), stage: "test", model: nil, id: "test").category, .offline)
    }

    func testMalformedModelJSONAndResponseRepair() throws {
        XCTAssertThrowsError(try GeminiModel.parsePage(Data("not json".utf8)))
        let brain = Brain(client: makeClient(GeminiKeyProvider(store: MemoryKeyStore())))
        let malformed = Data(#"{"candidates":[{"content":{"parts":[{"text":"{bad}"}]}}]}"#.utf8)
        XCTAssertThrowsError(try brain.decodeResponse(malformed, model: "test", id: "test"))
        let repaired = Data(#"{"candidates":[{"content":{"parts":[{"text":"```json\n{\"say\":\"Hello\"}\n```"}]}}]}"#.utf8)
        XCTAssertEqual(try brain.decodeResponse(repaired, model: "test", id: "test").say, "Hello")
    }

    func testVisionPayloadAndMalformedImage() throws {
        let brain = Brain(client: makeClient(GeminiKeyProvider(store: MemoryKeyStore())))
        XCTAssertThrowsError(try brain.buildPayload(prompt: "Hello", image: Data([1, 2]), id: "test"))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)
        let jpeg = try XCTUnwrap(bitmap?.representation(using: .jpeg, properties: [:]))
        let (body, width, height) = try brain.buildPayload(prompt: "Hello", image: jpeg, id: "test")
        XCTAssertEqual(width, 2)
        XCTAssertEqual(height, 2)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let config = try XCTUnwrap(json["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.last?["parts"] as? [[String: Any]])
        let imagePart = try XCTUnwrap(parts.last?["inline_data"] as? [String: Any])
        XCTAssertEqual(imagePart["mime_type"] as? String, "image/jpeg")
        XCTAssertNotNil(imagePart["data"] as? String)
    }

    func testBoundedOverloadRetry() async throws {
        let provider = GeminiKeyProvider(store: MemoryKeyStore())
        try provider.save("AIza111111111111111111111111111111111111111")
        var generations = 0
        StubProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let isGeneration = request.httpMethod == "POST"
            if isGeneration { generations += 1 }
            let status = isGeneration ? 503 : 200
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badURL)
            }
            let body = isGeneration
                ? #"{"error":{"status":"UNAVAILABLE","message":"High demand"}}"#
                : #"{"models":[{"name":"models/gemini-3.5-flash","supportedGenerationMethods":["generateContent"]}]}"#
            return (response, Data(body.utf8))
        }
        do {
            _ = try await makeClient(provider).generate(payload: Data("{}".utf8), id: "test")
            XCTFail("Expected overload")
        } catch let failure as GeminiFailure {
            XCTAssertEqual(failure.category, .overload)
        }
        XCTAssertGreaterThan(generations, 0)
        XCTAssertLessThanOrEqual(generations, 3)
    }

    func testSuccessfulVisionRequestUsesReplacementKey() async throws {
        let provider = GeminiKeyProvider(store: MemoryKeyStore())
        try provider.save("AIza111111111111111111111111111111111111111")
        let replacement = "AIza222222222222222222222222222222222222222"
        try provider.save(replacement)
        var sawImage = false
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), replacement)
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badURL)
            }
            if request.httpMethod == "POST" {
                let body = try XCTUnwrap(StubProtocol.bodyData(request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
                let parts = try XCTUnwrap(contents.last?["parts"] as? [[String: Any]])
                let imagePart = parts.last?["inline_data"] as? [String: Any]
                sawImage = (imagePart?["mime_type"] as? String) == "image/jpeg" &&
                    (imagePart?["data"] as? String) != nil &&
                    (parts.first?["text"] as? String)?.contains("User said: Hello") == true
                return (response, Data(#"{"candidates":[{"content":{"parts":[{"text":"{\"say\":\"Hi\"}"}]}}]}"#.utf8))
            }
            return (response, Data(#"{"models":[{"name":"models/gemini-3.5-flash","supportedGenerationMethods":["generateContent"]}]}"#.utf8))
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)
        let jpeg = try XCTUnwrap(bitmap?.representation(using: .jpeg, properties: [:]))
        let brain = Brain(client: makeClient(provider))
        let plan = try await brain.ask(text: "Hello", image: jpeg, gesture: "")
        XCTAssertEqual(plan.say, "Hi")
        XCTAssertTrue(sawImage)
    }
}
