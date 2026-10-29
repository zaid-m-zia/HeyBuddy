// Brain.swift: settings, plan types, and the plan system prompt.
// Network transport and response handling live in GeminiClient.swift and BrainNetworking.swift.

import Foundation

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

enum GeminiKeyError: Error, Equatable { case missing, malformed }

final class GeminiKeyProvider {
    private let store: APIKeyStore
    private(set) var current = ""

    init(store: APIKeyStore) { self.store = store }

    static func normalized(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("key=") {
            value = String(value.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.count >= 2, let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.isEmpty { throw GeminiKeyError.missing }
        if value.count < 20 || value.count > 512 ||
           value.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\"" || $0 == "'" || $0 == "<" || $0 == ">" }) ||
           value.lowercased().hasPrefix("key=") {
            throw GeminiKeyError.malformed
        }
        return value
    }

    func load() { current = (try? Self.normalized(store.loadKey())) ?? "" }

    func save(_ raw: String) throws {
        let value = try Self.normalized(raw)
        current = value
        store.saveKey(value)
    }

    func requireKey() throws -> String {
        if current.isEmpty { throw GeminiKeyError.missing }
        return try Self.normalized(current)
    }
}

enum Settings {
    private static let store: APIKeyStore = UserDefaultsKeyStore()
    static let keyProvider = GeminiKeyProvider(store: store)

    static func initialize() {
        (store as? UserDefaultsKeyStore)?.migrateFromKeychainSilently()
        keyProvider.load()
    }

    static var name: String {
        get { UserDefaults.standard.string(forKey: "name") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "name") }
    }

    static var apiKey: String { keyProvider.current }
    static func saveAPIKey(_ raw: String) throws { try keyProvider.save(raw) }
}

// ---------------------------------------------------------------------------
// MARK: - Shared model types
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
    var drawings: [DrawingElement]?       // New top-left {x,y} drawing plan

    init(say: String, cue: String?, focus: [Double]?, annotations: [Annotation]?,
         keep: Bool?, drawings: [DrawingElement]? = nil) {
        self.say = say; self.cue = cue; self.focus = focus
        self.annotations = annotations; self.keep = keep; self.drawings = drawings
    }

    private enum CodingKeys: String, CodingKey { case say, cue, focus, annotations, keep, drawings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        say = (try? c.decode(String.self, forKey: .say)) ?? ""
        cue = try? c.decode(String.self, forKey: .cue)
        focus = try? c.decode([Double].self, forKey: .focus)
        annotations = try? c.decode([Annotation].self, forKey: .annotations)
        keep = try? c.decode(Bool.self, forKey: .keep)
        let drawingList = try? c.decode(LossyDrawingList.self, forKey: .drawings)
        drawings = drawingList?.elements
        if c.contains(.drawings) && drawingList == nil {
            blogWarn("[DRAWING] Malformed drawings collection; preserving spoken step")
        }
        if c.contains(.annotations) && annotations == nil {
            blogWarn("[DRAWING] Malformed legacy annotations collection; preserving spoken step")
        }
        if let discarded = drawingList?.discardedCount, discarded > 0 {
            blogWarn("[DRAWING] Discarded \(discarded) malformed drawing value(s)")
        }
        if let invalid = drawingList?.elements.filter({ !$0.isValid }), !invalid.isEmpty {
            blogWarn("[DRAWING] Decoded \(invalid.count) invalid element(s): \(invalid.map { String($0.type.prefix(24)) }.joined(separator: ","))")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(say, forKey: .say)
        try c.encodeIfPresent(cue, forKey: .cue)
        try c.encodeIfPresent(focus, forKey: .focus)
        try c.encodeIfPresent(annotations, forKey: .annotations)
        try c.encodeIfPresent(keep, forKey: .keep)
        try c.encodeIfPresent(drawings, forKey: .drawings)
    }
}

struct Plan: Codable {
    // New format (Stage 3):
    var steps: [Step]?
    var actions: [Action]?
    var visual: Bool?                 // Whether the answer calls for screen guidance.

    // Backwards-compatible legacy format:
    var say: String?
    var points: [Point]?

    init(steps: [Step]?, actions: [Action]?, say: String?, points: [Point]?, visual: Bool? = nil) {
        self.steps = steps; self.actions = actions; self.say = say; self.points = points; self.visual = visual
    }

    private enum CodingKeys: String, CodingKey { case steps, actions, visual, say, points }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = try? c.decode([Step].self, forKey: .steps)
        actions = try? c.decode([Action].self, forKey: .actions)
        visual = try? c.decode(Bool.self, forKey: .visual)
        say = try? c.decode(String.self, forKey: .say)
        points = try? c.decode([Point].self, forKey: .points)
        if c.contains(.steps) && steps == nil { blogWarn("[DRAWING] Malformed steps collection") }
        if c.contains(.visual) && visual == nil { blogWarn("[DRAWING] Malformed visual flag") }
    }

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

@MainActor
final class Brain {
    static let configuredModels = GeminiClient.preferredIDs
    let client: GeminiClient
    var history: [[String: Any]] = []

    init(client: GeminiClient? = nil) { self.client = client ?? GeminiClient() }

    func systemPrompt() -> String {
        """
        You are \(Settings.name), a friendly AI buddy that lives next to the user's mouse cursor on macOS.
        You get a screenshot, what the user said, and cursor gesture info.
        You see one full-display screenshot resized without cropping. Base every target on
        objects actually visible in that image; do not guess typical macOS locations.
        New drawings use a top-left 0-1000 grid: x increases right, y increases down.
        Legacy focus uses [y, x]; legacy box_2d uses [ymin, xmin, ymax, xmax].

        Reply with ONLY valid JSON in this shape (choose real values, and use empty arrays when no drawing or action helps):
        {
          "visual": true,
          "steps": [
            {
              "say": "Look at this heading.",
              "cue": "heading",
              "focus": [180, 120],
              "drawings": [
                {"id": "heading-1", "type": "underline", "rect": {"x": 120, "y": 180, "width": 260, "height": 35}, "style": {"color": "amber"}, "purpose": "emphasize the visible heading", "order": 0, "duration": 0.35}
              ],
              "keep": false
            }
          ],
          "actions": []
        }

        Rules:
        - At most 6 steps. "say" is spoken aloud: concise, warm, natural, zero markdown.
        - Set "visual" true when the user asks you to point, mark, locate, compare visible content, or explain this screen. Set it false for a general question that needs no screen drawing. If true, provide grounded drawings in the relevant steps, or say clearly why no visible target can be identified.
        - Prefer "drawings" for new visuals; do not send both "drawings" and legacy "annotations" in one step.
        - Drawing coordinates are top-left normalized 0-1000. Points use {"x": number, "y": number}; rects use {"x": number, "y": number, "width": number, "height": number}. Keep every shape inside the grid.
        - Choose each drawing from the user's question, the visible target, and what that spoken step explains. Return multiple coordinated drawings when useful; never add shapes just for variety.
        - For a click target or bounded UI region use a tight red/coral outline rect, optionally with an arrow whose "to" point touches that target. For a small icon use a circle or ellipse. For text/value emphasis use a narrow translucent yellow/amber highlight or underline. Use a spotlight briefly for one target in a crowded interface. Use lines/arrows for relationships; badges for real sequences; brackets/braces for groups.
        - A UI target is usually better served by an outline than a broad yellow highlight. Do not highlight entire windows or unrelated content.
        - Give every drawing a short "purpose" and, when useful, a short "targetID" linking a label to a drawn target. Set "cue" to the exact phrase in "say" that introduces the drawing. For an intentional companion pointer move, include a valid pointer drawing or an arrow ending on the target; "focus" alone never moves it.
        - If the target itself has clearly legible text, add "targetText" with the exact visible text. Local OCR may align a highlight, underline, pointer, or arrow to one unique exact match. Omit targetText for icons, ambiguous text, or guessed words.
        - Include a center "point" for pointers, labels and badges; a tight "rect" for full visible targets; endpoints for arrows/lines. Use the supplied screenshot itself to place them. If the target is not visible or cannot be localized confidently, explain that and return no drawing.
        - Valid style colors are primary, red, coral, blue, cyan, yellow, amber, white. Outlines have no opaque fill; highlights remain translucent. Prefer red/coral for UI outlines, blue/cyan for direction, yellow/amber for text emphasis.
        - Supported drawing types: pointer, line, polyline, arrow, curvedArrow, curve, circle, ellipse, rect, roundedRect, polygon, regularPolygon, underline, highlight, spotlight, brace, bracket, freehand, label, explanatoryLabel, badge.
        - line and arrow use "from" and "to" points; curvedArrow and curve also use "control1" and "control2" points; polyline, polygon, and freehand use "points"; regularPolygon uses "rect" and "sides" (3-12). Labels and badges use "point" and real "text".
        - Use at most 8 purposeful drawings per step. Use "order" for a meaningful sequence and "cue" for the exact phrase when the drawings should appear.
        - Tight boxes around real elements. Use spotlight only to focus attention briefly.
        - Coordinates from vision are estimates. If a target is uncertain, explain without drawing; never invent precise placement confidently.
        - Draw NOTHING when it doesn't help. If unsure of a location, say so and draw nothing.
        - For actions: macOS zsh commands, AppleScript for Finder/apps, or open. Absolute paths or ~ for home. Finder selection: tell application "Finder" to get selection.
        - Keep "actions" empty when not executing system tasks.
        """
    }

}
