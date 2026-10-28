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
    var color: String? = nil // "primary" or "blue"; unrecognized colors use primary
    var strokeWidth: Double? = nil
    var opacity: Double? = nil
    var fillOpacity: Double? = nil

    var isValid: Bool {
        (color.map { ["primary", "blue"].contains($0) } ?? true) &&
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
    var purpose: String?

    var kind: DrawingKind? { DrawingKind(rawValue: type) }

    var anchor: DrawingPoint? {
        switch geometry {
        case .point(let p), .segment(let p, _), .cubic(let p, _, _, _): return p
        case .rect(let r), .regularPolygon(let r, _): return DrawingPoint(x: r.x + r.width / 2, y: r.y + r.height / 2)
        case .path(let points): return points.first
        case .invalid: return nil
        }
    }

    init(id: String = UUID().uuidString, kind: DrawingKind, geometry: DrawingGeometry,
         text: String? = nil, style: DrawingStyle? = nil, duration: Double? = nil,
         order: Int? = nil, targetID: String? = nil, purpose: String? = nil) {
        self.id = id; self.type = kind.rawValue; self.geometry = geometry
        self.text = text; self.style = style; self.duration = duration
        self.order = order; self.targetID = targetID; self.purpose = purpose
    }

    var isValid: Bool {
        guard let kind, geometry.isValid, style?.isValid ?? true,
              (duration.map { $0.isFinite && (0.10...2.0).contains($0) } ?? true),
              (order.map { (0...100).contains($0) } ?? true),
              id.count <= 80, (targetID?.count ?? 0) <= 80, (purpose?.count ?? 0) <= 120 else { return false }
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
        case id, type, point, rect, from, to, control1, control2, points, sides
        case text, label, style, duration, order, targetID, purpose
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
        purpose = try? c.decode(String.self, forKey: .purpose)
        if (c.contains(.style) && style == nil) ||
            (c.contains(.duration) && duration == nil) ||
            (c.contains(.order) && order == nil) {
            geometry = .invalid
            return
        }
        guard let decodedKind = DrawingKind(rawValue: type) else { geometry = .invalid; return }
        switch decodedKind {
        case .pointer, .badge, .label, .explanatoryLabel:
            geometry = (try? c.decode(DrawingPoint.self, forKey: .point)).map(DrawingGeometry.point) ?? .invalid
        case .circle, .ellipse, .rect, .roundedRect, .underline, .highlight, .spotlight, .brace, .bracket:
            geometry = (try? c.decode(DrawingRect.self, forKey: .rect)).map(DrawingGeometry.rect) ?? .invalid
        case .line, .arrow:
            if let a = try? c.decode(DrawingPoint.self, forKey: .from),
               let b = try? c.decode(DrawingPoint.self, forKey: .to) { geometry = .segment(a, b) }
            else { geometry = .invalid }
        case .curvedArrow, .curve:
            if let a = try? c.decode(DrawingPoint.self, forKey: .from),
               let b = try? c.decode(DrawingPoint.self, forKey: .control1),
               let d = try? c.decode(DrawingPoint.self, forKey: .to) {
                let c2 = (try? c.decode(DrawingPoint.self, forKey: .control2)) ?? b
                geometry = .cubic(a, b, c2, d)
            } else { geometry = .invalid }
        case .polyline, .polygon, .freehand:
            geometry = (try? c.decode([DrawingPoint].self, forKey: .points)).map(DrawingGeometry.path) ?? .invalid
        case .regularPolygon:
            if let rect = try? c.decode(DrawingRect.self, forKey: .rect), let sides = try? c.decode(Int.self, forKey: .sides) {
                geometry = .regularPolygon(rect, sides)
            } else { geometry = .invalid }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(type, forKey: .type)
        try c.encodeIfPresent(text, forKey: .text); try c.encodeIfPresent(style, forKey: .style)
        try c.encodeIfPresent(duration, forKey: .duration); try c.encodeIfPresent(order, forKey: .order)
        try c.encodeIfPresent(targetID, forKey: .targetID); try c.encodeIfPresent(purpose, forKey: .purpose)
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
        guard let kind = DrawingKind(rawValue: a.type) else { return nil }
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

/// Maps the screenshot's top-left normalized grid into the overlay window's
/// local bottom-left point coordinates. The window itself is placed at the
/// captured display frame, which may have a negative global origin. Retina
/// scale applies to layer rasterization only; it does not multiply geometry.
struct CanvasMapper {
    let size: CGSize

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

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var valid: [DrawingElement] = []
        while !container.isAtEnd {
            if let element = try? container.decode(DrawingElement.self) {
                valid.append(element)
            } else {
                _ = try container.decode(DiscardDrawingValue.self)
            }
        }
        elements = valid
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
