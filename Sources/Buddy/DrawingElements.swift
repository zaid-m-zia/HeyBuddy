import Foundation
import CoreGraphics

/// Drawing plans use a top-left 0...1000 grid. Points are {x,y}; rectangles are
/// {x,y,width,height}. The legacy Gemini [y,x] and box_2d formats are converted here.
struct DrawingPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var isValid: Bool { x.isFinite && y.isFinite && (0...1000).contains(x) && (0...1000).contains(y) }
}

struct DrawingRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite &&
        x >= 0 && y >= 0 && width > 0 && height > 0 &&
        x + width <= 1000 && y + height <= 1000
    }
}

enum DrawingKind: String, Codable {
    case pointer, line, polyline, arrow, curvedArrow, curve, circle, ellipse
    case rect, roundedRect, polygon, regularPolygon, underline, highlight
    case spotlight, brace, bracket, freehand, label, explanatoryLabel, badge

    /// Gemini sometimes changes capitalization or uses a familiar shape synonym.
    /// Keep the response schema canonical while repairing only unambiguous names.
    static func fromResponse(_ value: String) -> DrawingKind? {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        if let kind = allCasesByName[key] { return kind }
        switch key {
        case "rectangle", "box", "boundingbox", "outline", "outlinedrectangle": return .rect
        case "roundedrectangle": return .roundedRect
        case "curvedarrow": return .curvedArrow
        case "regularpolygon": return .regularPolygon
        case "explanatorylabel": return .explanatoryLabel
        default: return nil
        }
    }

    private static let allCasesByName: [String: DrawingKind] = {
        let kinds: [DrawingKind] = [.pointer, .line, .polyline, .arrow, .curvedArrow,
            .curve, .circle, .ellipse, .rect, .roundedRect, .polygon, .regularPolygon,
            .underline, .highlight, .spotlight, .brace, .bracket, .freehand,
            .label, .explanatoryLabel, .badge]
        return Dictionary(uniqueKeysWithValues: kinds.map { ($0.rawValue.lowercased(), $0) })
    }()
}

enum DrawingGeometry: Equatable {
    case point(DrawingPoint)
    case rect(DrawingRect)
    case segment(DrawingPoint, DrawingPoint)
    case cubic(DrawingPoint, DrawingPoint, DrawingPoint, DrawingPoint) // start, control1, control2, end
    case path([DrawingPoint])
    case regularPolygon(DrawingRect, Int)
    case invalid

    var isValid: Bool {
        switch self {
        case .point(let p): return p.isValid
        case .rect(let r): return r.isValid
        case .segment(let a, let b): return a.isValid && b.isValid && a != b
        case .cubic(let a, let b, let c, let d): return [a, b, c, d].allSatisfy(\.isValid) && a != d
        case .path(let points): return (2...32).contains(points.count) && points.allSatisfy(\.isValid)
        case .regularPolygon(let r, let sides): return r.isValid && (3...12).contains(sides)
        case .invalid: return false
        }
    }
}

struct DrawingStyle: Codable, Equatable {
    var color: String? = nil // Named palette color; unknown names invalidate this drawing.
    var strokeWidth: Double? = nil
    var opacity: Double? = nil
    var fillOpacity: Double? = nil

    var isValid: Bool {
        (color.map { ["primary", "red", "coral", "blue", "cyan", "yellow", "amber", "white"].contains($0.lowercased()) } ?? true) &&
        (strokeWidth.map { $0.isFinite && (1...8).contains($0) } ?? true) &&
        (opacity.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
        (fillOpacity.map { $0.isFinite && (0...0.30).contains($0) } ?? true)
    }
}

/// A malformed drawing decodes as an invalid element and is skipped by the renderer;
/// it cannot invalidate spoken text or other valid drawings in the same step.
struct DrawingElement: Codable {
    var id: String
    var type: String
    var geometry: DrawingGeometry
    var text: String?
    var style: DrawingStyle?
    var duration: Double?
    var order: Int?
    var targetID: String?
    var targetText: String? // Exact visible text, for conservative local OCR alignment.
    var purpose: String?

    var kind: DrawingKind? { DrawingKind.fromResponse(type) }

    var anchor: DrawingPoint? {
        switch geometry {
        case .point(let p): return p
        case .segment(let start, let end): return kind == .arrow ? end : start
        case .cubic(let start, _, _, let end): return kind == .curvedArrow ? end : start
        case .rect(let r), .regularPolygon(let r, _): return DrawingPoint(x: r.x + r.width / 2, y: r.y + r.height / 2)
        case .path(let points): return points.first
        case .invalid: return nil
        }
    }

    init(id: String = UUID().uuidString, kind: DrawingKind, geometry: DrawingGeometry,
         text: String? = nil, style: DrawingStyle? = nil, duration: Double? = nil,
         order: Int? = nil, targetID: String? = nil, targetText: String? = nil,
         purpose: String? = nil) {
        self.id = id; self.type = kind.rawValue; self.geometry = geometry
        self.text = text; self.style = style; self.duration = duration
        self.order = order; self.targetID = targetID; self.targetText = targetText; self.purpose = purpose
    }

    var isValid: Bool {
        guard let kind, geometry.isValid, style?.isValid ?? true,
              (duration.map { $0.isFinite && (0.10...2.0).contains($0) } ?? true),
              (order.map { (0...100).contains($0) } ?? true),
              id.count <= 80, (targetID?.count ?? 0) <= 80,
              (targetText?.count ?? 0) <= 80, (purpose?.count ?? 0) <= 120 else { return false }
        if let text, text.count > 80 { return false }
        switch (kind, geometry) {
        case (.pointer, .point(_)), (.badge, .point(_)), (.label, .point(_)), (.explanatoryLabel, .point(_)):
            return kind == .pointer || !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case (.circle, .rect(_)), (.ellipse, .rect(_)), (.rect, .rect(_)), (.roundedRect, .rect(_)),
             (.underline, .rect(_)), (.highlight, .rect(_)), (.spotlight, .rect(_)),
             (.brace, .rect(_)), (.bracket, .rect(_)): return true
        case (.line, .segment(_, _)), (.arrow, .segment(_, _)): return true
        case (.curvedArrow, .cubic(_, _, _, _)), (.curve, .cubic(_, _, _, _)): return true
        case (.line, .path(_)), (.polyline, .path(_)), (.freehand, .path(_)): return true
        case (.polygon, .path(let points)): return points.count >= 3
        case (.regularPolygon, .regularPolygon(_, _)): return true
        default: return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, point, rect, box_2d, from, to, control1, control2, points, sides
        case text, label, style, duration, order, targetID, targetText, purpose
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        text = (try? c.decode(String.self, forKey: .text)) ?? (try? c.decode(String.self, forKey: .label))
        style = try? c.decode(DrawingStyle.self, forKey: .style)
        duration = try? c.decode(Double.self, forKey: .duration)
        order = try? c.decode(Int.self, forKey: .order)
        targetID = try? c.decode(String.self, forKey: .targetID)
        targetText = try? c.decode(String.self, forKey: .targetText)
        purpose = try? c.decode(String.self, forKey: .purpose)
        if (c.contains(.style) && style == nil) ||
            (c.contains(.duration) && duration == nil) ||
            (c.contains(.order) && order == nil) {
            geometry = .invalid
            return
        }
        guard let decodedKind = DrawingKind.fromResponse(type) else { geometry = .invalid; return }
        func point(_ key: CodingKeys) -> DrawingPoint? {
            if let value = try? c.decode(DrawingPoint.self, forKey: key) { return value }
            if let values = try? c.decode([Double].self, forKey: key), values.count == 2 {
                return DrawingPoint(x: values[1], y: values[0])
            }
            return nil
        }
        func rect() -> DrawingRect? {
            if let value = try? c.decode(DrawingRect.self, forKey: .rect) { return value }
            if let values = try? c.decode([Double].self, forKey: .box_2d), values.count == 4 {
                return DrawingRect(x: values[1], y: values[0],
                                   width: values[3] - values[1], height: values[2] - values[0])
            }
            return nil
        }
        switch decodedKind {
        case .pointer, .badge, .label, .explanatoryLabel:
            geometry = point(.point).map(DrawingGeometry.point) ?? .invalid
        case .circle, .ellipse, .rect, .roundedRect, .underline, .highlight, .spotlight, .brace, .bracket:
            geometry = rect().map(DrawingGeometry.rect) ?? .invalid
        case .line, .arrow:
            if let a = point(.from), let b = point(.to) { geometry = .segment(a, b) }
            else { geometry = .invalid }
        case .curvedArrow, .curve:
            if let a = point(.from), let b = point(.control1), let d = point(.to) {
                let c2 = point(.control2) ?? b
                geometry = .cubic(a, b, c2, d)
            } else { geometry = .invalid }
        case .polyline, .polygon, .freehand:
            if let values = try? c.decode([DrawingPoint].self, forKey: .points) {
                geometry = .path(values)
            } else if let values = try? c.decode([[Double]].self, forKey: .points),
                      values.allSatisfy({ $0.count == 2 }) {
                geometry = .path(values.map { DrawingPoint(x: $0[1], y: $0[0]) })
            } else { geometry = .invalid }
        case .regularPolygon:
            if let value = rect(), let sides = try? c.decode(Int.self, forKey: .sides) {
                geometry = .regularPolygon(value, sides)
            } else { geometry = .invalid }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(type, forKey: .type)
        try c.encodeIfPresent(text, forKey: .text); try c.encodeIfPresent(style, forKey: .style)
        try c.encodeIfPresent(duration, forKey: .duration); try c.encodeIfPresent(order, forKey: .order)
        try c.encodeIfPresent(targetID, forKey: .targetID)
        try c.encodeIfPresent(targetText, forKey: .targetText)
        try c.encodeIfPresent(purpose, forKey: .purpose)
        switch geometry {
        case .point(let p): try c.encode(p, forKey: .point)
        case .rect(let r): try c.encode(r, forKey: .rect)
        case .segment(let a, let b): try c.encode(a, forKey: .from); try c.encode(b, forKey: .to)
        case .cubic(let a, let b, let control2, let d):
            try c.encode(a, forKey: .from); try c.encode(b, forKey: .control1)
            try c.encode(control2, forKey: .control2); try c.encode(d, forKey: .to)
        case .path(let p): try c.encode(p, forKey: .points)
        case .regularPolygon(let r, let sides): try c.encode(r, forKey: .rect); try c.encode(sides, forKey: .sides)
        case .invalid: break
        }
    }

    static func legacy(_ a: Annotation) -> DrawingElement? {
        guard let kind = DrawingKind.fromResponse(a.type) else { return nil }
        func point(_ values: [Double]?) -> DrawingPoint? {
            guard let values, values.count == 2 else { return nil }
            return DrawingPoint(x: values[1], y: values[0])
        }
        func rect(_ values: [Double]?) -> DrawingRect? {
            guard let values, values.count == 4 else { return nil }
            return DrawingRect(x: values[1], y: values[0], width: values[3] - values[1], height: values[2] - values[0])
        }
        let geometry: DrawingGeometry
        switch kind {
        case .pointer, .badge, .label, .explanatoryLabel: geometry = point(a.point).map(DrawingGeometry.point) ?? .invalid
        case .circle, .ellipse, .rect, .roundedRect, .underline, .highlight, .spotlight, .brace, .bracket:
            geometry = rect(a.box_2d).map(DrawingGeometry.rect) ?? .invalid
        case .line:
            if let points = a.points, points.count > 2 {
                geometry = .path(points.compactMap { point($0) })
            } else if let points = a.points, points.count == 2,
                      let first = point(points.first), let last = point(points.last) {
                geometry = .segment(first, last)
            } else { geometry = .invalid }
        case .arrow:
            if let first = point(a.from), let last = point(a.to) { geometry = .segment(first, last) }
            else { geometry = .invalid }
        case .polyline, .polygon, .freehand:
            geometry = .path((a.points ?? []).compactMap { point($0) })
        case .curvedArrow, .curve, .regularPolygon: geometry = .invalid
        }
        let element = DrawingElement(kind: kind, geometry: geometry, text: a.text ?? a.label)
        return element.isValid ? element : nil
    }
}

/// Vision supplies bottom-left unit boxes. Convert them once to the model's
/// top-left 0...1000 grid, independently of Retina scale or JPEG resizing.
struct OCRTarget {
    let text: String
    let rect: DrawingRect

    init?(text: String, visionBox: CGRect) {
        let rect = DrawingRect(x: Double(visionBox.minX * 1000),
                               y: Double((1 - visionBox.maxY) * 1000),
                               width: Double(visionBox.width * 1000),
                               height: Double(visionBox.height * 1000))
        guard rect.isValid, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.text = text
        self.rect = rect
    }
}

/// Snap only to one exact OCR match. Ambiguous or missing text leaves the model's
/// coordinates untouched. Compact UI outlines retain their model-selected size.
enum DrawingTargetResolver {
    static func refine(_ plan: Plan, targets: [OCRTarget]) -> Plan {
        var result = plan
        result.steps = plan.steps?.map { step in
            var updated = step
            updated.drawings = step.drawings?.map { element in
                guard let text = element.targetText?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, element.isValid else { return element }
                let matches = targets.filter {
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .localizedCaseInsensitiveCompare(text) == .orderedSame
                }
                guard matches.count == 1, let target = matches.first else { return element }
                var snapped = element
                let rect = target.rect
                let center = DrawingPoint(x: rect.x + rect.width / 2,
                                          y: rect.y + rect.height / 2)
                switch (element.kind, element.geometry) {
                case (.highlight, .rect(_)), (.underline, .rect(_)):
                    snapped.geometry = .rect(rect)
                case (.arrow, .segment(let start, _)):
                    snapped.geometry = .segment(start, center)
                case (.curvedArrow, .cubic(let start, let c1, let c2, _)):
                    snapped.geometry = .cubic(start, c1, c2, center)
                case (.pointer, .point(_)):
                    snapped.geometry = .point(center)
                case (.rect, .rect(let outline)), (.roundedRect, .rect(let outline)):
                    if outline.width <= 200 && outline.height <= 150 &&
                        abs(outline.x + outline.width / 2 - center.x) <= outline.width &&
                        abs(outline.y + outline.height / 2 - center.y) <= outline.height {
                        snapped.geometry = .rect(DrawingRect(
                            x: min(max(center.x - outline.width / 2, 0), 1000 - outline.width),
                            y: min(max(center.y - outline.height / 2, 0), 1000 - outline.height),
                            width: outline.width, height: outline.height))
                    }
                default: break
                }
                return snapped.isValid ? snapped : element
            }
            return updated
        }
        return result
    }
}

/// Maps the screenshot's top-left normalized grid into the overlay window's
/// local bottom-left point coordinates. The window itself is placed at the
/// captured display frame, which may have a negative global origin. Retina
/// scale applies to layer rasterization only; it does not multiply geometry.
struct CanvasMapper {
    let size: CGSize

    /// The model sees a whole-display screenshot. Resizing its pixels without
    /// cropping leaves normalized positions unchanged; geometry stays in points.
    func normalized(_ globalPoint: CGPoint, displayFrame: CGRect) -> DrawingPoint {
        DrawingPoint(x: Double((globalPoint.x - displayFrame.minX) / displayFrame.width * 1000),
                     y: Double((displayFrame.maxY - globalPoint.y) / displayFrame.height * 1000))
    }

    func point(_ p: DrawingPoint) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * size.width / 1000,
                y: size.height - CGFloat(p.y) * size.height / 1000)
    }

    func rect(_ r: DrawingRect) -> CGRect {
        CGRect(x: CGFloat(r.x) * size.width / 1000,
               y: size.height - CGFloat(r.y + r.height) * size.height / 1000,
               width: CGFloat(r.width) * size.width / 1000,
               height: CGFloat(r.height) * size.height / 1000)
    }
}

/// Decode every drawing independently so a scalar or malformed object cannot
/// discard the other elements in a spoken step.
struct LossyDrawingList: Decodable {
    let elements: [DrawingElement]
    let discardedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var valid: [DrawingElement] = []
        var discarded = 0
        while !container.isAtEnd {
            if let element = try? container.decode(DrawingElement.self) {
                valid.append(element)
            } else {
                _ = try container.decode(DiscardDrawingValue.self)
                discarded += 1
            }
        }
        elements = valid
        discardedCount = discarded
    }
}

extension Step {
    /// Preserve invalid new elements for renderer diagnostics. Fall back to
    /// legacy elements only when the new list has no usable drawing.
    var effectiveDrawings: [DrawingElement] {
        let planned = drawings ?? []
        if planned.contains(where: \.isValid) { return planned }
        return (annotations ?? []).compactMap(DrawingElement.legacy)
    }

    /// Only a pointer mark or arrow endpoint authorizes companion movement.
    /// A bare focus or an arbitrary shape center is not a pointing instruction.
    var pointerTarget: DrawingPoint? {
        effectiveDrawings.first(where: { $0.isValid && $0.kind == .pointer })?.anchor ??
        effectiveDrawings.first(where: { $0.isValid && ($0.kind == .arrow || $0.kind == .curvedArrow) })?.anchor
    }
}

enum VisualRequest {
    static func requiresGuidance(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
        return ["show me where", "where should i click", "where do i click", "point to",
                "circle ", "highlight ", "underline ", "mark ", "annotate ",
                "draw ", "this paragraph", "this interface", "this screen",
                "these two values", "on my screen"].contains { text.contains($0) }
    }
}

private struct DrawingJSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { Int(stringValue) }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue) }
}

private struct DiscardDrawingValue: Decodable {
    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd { _ = try array.decode(DiscardDrawingValue.self) }
        } else if let object = try? decoder.container(keyedBy: DrawingJSONKey.self) {
            for key in object.allKeys { _ = try object.decode(DiscardDrawingValue.self, forKey: key) }
        } else {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() || (try? value.decode(String.self)) != nil ||
                (try? value.decode(Bool.self)) != nil || (try? value.decode(Double.self)) != nil { return }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported drawing value")
        }
    }
}
