import AppKit
import QuartzCore

struct RenderedDrawing {
    let id: String
    let layer: CALayer
    let isSpotlight: Bool
}

/// Small deterministic placement pass. All frames are local AppKit points.
struct DrawingLabelPlacer {
    let canvas: CGRect
    private(set) var occupied: [CGRect] = []

    mutating func place(near target: CGPoint, size: CGSize, avoiding area: CGRect? = nil) -> CGRect {
        let margin: CGFloat = 8
        let candidates = [
            CGRect(x: target.x + 12, y: target.y + 12, width: size.width, height: size.height),
            CGRect(x: target.x + 12, y: target.y - size.height - 12, width: size.width, height: size.height),
            CGRect(x: target.x - size.width - 12, y: target.y + 12, width: size.width, height: size.height),
            CGRect(x: target.x - size.width - 12, y: target.y - size.height - 12, width: size.width, height: size.height),
            CGRect(x: target.x + 12, y: target.y - 2 * size.height - 20, width: size.width, height: size.height),
            CGRect(x: target.x - size.width - 12, y: target.y - 2 * size.height - 20, width: size.width, height: size.height)
        ]
        let bounds = canvas.insetBy(dx: margin, dy: margin)
        let clamped = candidates.map { candidate in
            CGRect(x: min(max(candidate.minX, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
                   y: min(max(candidate.minY, bounds.minY), max(bounds.minY, bounds.maxY - size.height)),
                   width: size.width, height: size.height)
        }
        let targetArea = area ?? CGRect(x: target.x - 6, y: target.y - 6, width: 12, height: 12)
        let best = clamped.min { a, b in
            score(a, target: targetArea) < score(b, target: targetArea)
        } ?? CGRect(origin: target, size: size)
        occupied.append(best)
        return best
    }

    private func score(_ frame: CGRect, target: CGRect) -> CGFloat {
        let targetOverlap = frame.intersection(target)
        var result = targetOverlap.isNull ? 0 : targetOverlap.width * targetOverlap.height * 4
        for prior in occupied {
            let overlap = frame.intersection(prior)
            if !overlap.isNull { result += overlap.width * overlap.height }
        }
        return result
    }
}

@MainActor
final class DrawingRenderer {
    struct Palette {
        static let primary = NSColor(srgbRed: 0.96, green: 0.25, blue: 0.48, alpha: 1)
        static let blue = NSColor.systemBlue
        static let cyan = NSColor.systemCyan
        static let amber = NSColor(srgbRed: 1, green: 0.72, blue: 0.16, alpha: 1)
        static let highlight = NSColor(srgbRed: 1, green: 0.80, blue: 0.27, alpha: 0.25)
        static let dim = NSColor.black.withAlphaComponent(0.55)
    }

    let maxElementsPerStep = 8
    private let debugDrawings = ProcessInfo.processInfo.environment["BUDDY_DRAW_DEBUG"] == "1"

    func render(_ elements: [DrawingElement], mapper: CanvasMapper, backingScale: CGFloat) -> [RenderedDrawing] {
        let rejected = elements.filter { !$0.isValid }
        if !rejected.isEmpty {
            blogWarn("[DRAWING] Skipped \(rejected.count) invalid element(s): \(rejected.map { String($0.type.prefix(24)) }.joined(separator: ","))")
        }
        if debugDrawings {
            blogDebug("[DRAWING] requested=\(elements.count) types=\(elements.map(\.type).joined(separator: ",")) canvas=\(Int(mapper.size.width))x\(Int(mapper.size.height))")
        }
        let ordered = elements.enumerated().filter { $0.element.isValid }
            .sorted { left, right in
                let a = left.element.order ?? left.offset
                let b = right.element.order ?? right.offset
                return a == b ? left.offset < right.offset : a < b
            }
        var seen: Set<String> = []
        var placer = DrawingLabelPlacer(canvas: CGRect(origin: .zero, size: mapper.size))
        var result: [RenderedDrawing] = []
        let targets = elements.reduce(into: [String: DrawingElement]()) { result, element in result[element.id] = element }
        if ordered.count > maxElementsPerStep {
            blogWarn("[DRAWING] Limited step to \(maxElementsPerStep) elements")
        }
        for (_, element) in ordered {
            guard result.count < maxElementsPerStep, seen.insert(element.id).inserted else { continue }
            if debugDrawings, let anchor = element.anchor {
                let mapped = mapper.point(anchor)
                blogDebug("[DRAWING] type=\(element.type) anchor=\(Int(anchor.x)),\(Int(anchor.y)) local=\(Int(mapped.x)),\(Int(mapped.y))")
            }
            let targetArea: CGRect?
            if let targetID = element.targetID, let target = targets[targetID] {
                switch target.geometry {
                case .rect(let rect), .regularPolygon(let rect, _): targetArea = mapper.rect(rect)
                default: targetArea = nil
                }
            } else { targetArea = nil }
            if let layer = makeLayer(element, mapper: mapper, backingScale: backingScale,
                                     targetArea: targetArea, placer: &placer) {
                result.append(RenderedDrawing(id: element.id, layer: layer, isSpotlight: element.kind == .spotlight))
            }
        }
        return result
    }

    private func color(_ element: DrawingElement) -> NSColor {
        switch element.style?.color?.lowercased() {
        case "blue": return Palette.blue
        case "cyan": return Palette.cyan
        case "yellow": return NSColor.systemYellow
        case "amber": return Palette.amber
        case "white": return .white
        default: return Palette.primary // primary, red, coral
        }
    }

    private func shape(_ path: CGPath, element: DrawingElement, mapper: CanvasMapper,
                       scale: CGFloat, fill: CGColor? = nil, stroke: CGColor? = nil,
                       evenOdd: Bool = false) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.frame = CGRect(origin: .zero, size: mapper.size)
        layer.path = path
        layer.fillColor = fill
        layer.strokeColor = stroke
        layer.lineWidth = CGFloat(element.style?.strokeWidth ?? 4)
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.contentsScale = scale
        layer.opacity = Float(element.style?.opacity ?? 1)
        layer.shadowColor = stroke
        layer.shadowOffset = .zero
        layer.shadowRadius = 6
        layer.shadowOpacity = stroke == nil ? 0 : 0.6
        if evenOdd { layer.fillRule = .evenOdd }
        if stroke != nil && fill != nil && element.kind != .polygon && element.kind != .regularPolygon {
            blogWarn("[DRAWING] Outline received a fill; clearing it")
            layer.fillColor = nil
        }
        return layer
    }

    private func strokeAnimation(_ layer: CAShapeLayer, duration: Double, delay: Double = 0) {
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "draw")
    }

    private func fadeAnimation(_ layer: CALayer, duration: Double) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = layer.opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "appear")
    }

    private func makeLayer(_ e: DrawingElement, mapper: CanvasMapper, backingScale scale: CGFloat,
                           targetArea: CGRect?, placer: inout DrawingLabelPlacer) -> CALayer? {
        guard let kind = e.kind else { return nil }
        let ink = color(e).cgColor
        let duration = e.duration ?? 0.35
        let path = CGMutablePath()

        switch (kind, e.geometry) {
        case (.highlight, .rect(let r)):
            let layer = CALayer()
            layer.frame = mapper.rect(r)
            let alpha = CGFloat(min(e.style?.fillOpacity ?? 0.25, 0.30))
            layer.backgroundColor = (e.style?.color == nil ? Palette.highlight : color(e))
                .withAlphaComponent(alpha).cgColor
            layer.cornerRadius = 6
            layer.opacity = Float(e.style?.opacity ?? 1)
            layer.contentsScale = scale
            layer.zPosition = -50
            fadeAnimation(layer, duration: duration)
            return layer

        case (.spotlight, .rect(let r)):
            path.addRect(CGRect(origin: .zero, size: mapper.size))
            path.addRoundedRect(in: mapper.rect(r), cornerWidth: 10, cornerHeight: 10)
            let layer = shape(path, element: e, mapper: mapper, scale: scale,
                              fill: Palette.dim.cgColor, evenOdd: true)
            layer.zPosition = -100
            fadeAnimation(layer, duration: duration)
            return layer

        case (.label, .point(let p)), (.explanatoryLabel, .point(let p)), (.badge, .point(let p)):
            guard let text = e.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let anchor = mapper.point(p)
            let isBadge = kind == .badge
            let size = isBadge ? CGSize(width: 30, height: 30)
                : CGSize(width: min(CGFloat(text.count) * 7.6 + 22, 320), height: 28)
            let frame = placer.place(near: anchor, size: size, avoiding: targetArea)
            let container = CALayer()
            container.frame = frame
            container.backgroundColor = isBadge ? ink : NSColor.black.withAlphaComponent(0.82).cgColor
            container.cornerRadius = isBadge ? 15 : 8
            container.contentsScale = scale
            container.opacity = Float(e.style?.opacity ?? 1)
            container.zPosition = 20
            let label = CATextLayer()
            label.frame = CGRect(x: isBadge ? 2 : 8, y: isBadge ? 4 : 5,
                                 width: size.width - (isBadge ? 4 : 16), height: size.height - 9)
            label.string = text
            label.fontSize = isBadge ? 15 : 12
            label.alignmentMode = .center
            label.truncationMode = .end
            label.foregroundColor = NSColor.white.cgColor
            label.contentsScale = scale
            container.addSublayer(label)
            fadeAnimation(container, duration: duration)
            return container

        case (.pointer, .point(let p)):
            let center = mapper.point(p)
            path.addEllipse(in: CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44))

        case (.circle, .rect(let r)):
            let rect = mapper.rect(r)
            let side = min(rect.width, rect.height)
            path.addEllipse(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
        case (.ellipse, .rect(let r)): path.addEllipse(in: mapper.rect(r))
        case (.rect, .rect(let r)): path.addRect(mapper.rect(r))
        case (.roundedRect, .rect(let r)):
            path.addRoundedRect(in: mapper.rect(r), cornerWidth: 8, cornerHeight: 8)
        case (.underline, .rect(let r)):
            let rect = mapper.rect(r)
            let y = max(2, rect.minY - 2)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        case (.line, .segment(let a, let b)):
            path.move(to: mapper.point(a)); path.addLine(to: mapper.point(b))
        case (.arrow, .segment(let a, let b)):
            return arrow(from: mapper.point(a), to: mapper.point(b), control1: nil, control2: nil,
                         element: e, mapper: mapper, scale: scale, ink: ink, duration: duration)
        case (.curvedArrow, .cubic(let a, let b, let c, let d)):
            return arrow(from: mapper.point(a), to: mapper.point(d), control1: mapper.point(b),
                         control2: mapper.point(c), element: e, mapper: mapper, scale: scale,
                         ink: ink, duration: duration)
        case (.curve, .cubic(let a, let b, let c, let d)):
            path.move(to: mapper.point(a))
            path.addCurve(to: mapper.point(d), control1: mapper.point(b), control2: mapper.point(c))
        case (.line, .path(let points)), (.polyline, .path(let points)), (.polygon, .path(let points)):
            guard let first = points.first else { return nil }
            path.move(to: mapper.point(first))
            for p in points.dropFirst() { path.addLine(to: mapper.point(p)) }
            if kind == .polygon { path.closeSubpath() }
        case (.freehand, .path(let points)):
            guard let first = points.first else { return nil }
            path.move(to: mapper.point(first))
            for i in 1..<points.count {
                let previous = mapper.point(points[i - 1])
                let current = mapper.point(points[i])
                let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                path.addQuadCurve(to: midpoint, control: previous)
            }
            if let last = points.last { path.addLine(to: mapper.point(last)) }
        case (.regularPolygon, .regularPolygon(let r, let sides)):
            let rect = mapper.rect(r)
            let rx = rect.width / 2, ry = rect.height / 2
            for i in 0..<sides {
                let angle = CGFloat(i) * 2 * .pi / CGFloat(sides) + .pi / 2
                let p = CGPoint(x: rect.midX + rx * cos(angle), y: rect.midY + ry * sin(angle))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        case (.bracket, .rect(let r)):
            let rect = mapper.rect(r)
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        case (.brace, .rect(let r)):
            let rect = mapper.rect(r)
            let x = rect.minX, right = rect.maxX, mid = rect.midY
            path.move(to: CGPoint(x: right, y: rect.maxY))
            path.addCurve(to: CGPoint(x: x, y: mid + 3),
                          control1: CGPoint(x: x, y: rect.maxY), control2: CGPoint(x: right, y: mid + 8))
            path.addCurve(to: CGPoint(x: right, y: rect.minY),
                          control1: CGPoint(x: right, y: mid - 8), control2: CGPoint(x: x, y: rect.minY))
        default: return nil
        }

        let fill: CGColor? = kind == .polygon || kind == .regularPolygon
            ? color(e).withAlphaComponent(CGFloat(min(e.style?.fillOpacity ?? 0.08, 0.10))).cgColor : nil
        let layer = shape(path, element: e, mapper: mapper, scale: scale, fill: fill,
                          stroke: kind == .pointer ? Palette.blue.cgColor : ink)
        strokeAnimation(layer, duration: duration)
        return layer
    }

    private func arrow(from start: CGPoint, to end: CGPoint, control1: CGPoint?, control2: CGPoint?,
                       element: DrawingElement, mapper: CanvasMapper, scale: CGFloat,
                       ink: CGColor, duration: Double) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: mapper.size)
        let shaftPath = CGMutablePath()
        shaftPath.move(to: start)
        let tangent: CGPoint
        if let control1, let control2 {
            shaftPath.addCurve(to: end, control1: control1, control2: control2)
            let finalHandle = hypot(end.x - control2.x, end.y - control2.y) > 0.01 ? control2 : control1
            tangent = CGPoint(x: end.x - finalHandle.x, y: end.y - finalHandle.y)
        } else {
            shaftPath.addLine(to: end)
            tangent = CGPoint(x: end.x - start.x, y: end.y - start.y)
        }
        let shaft = shape(shaftPath, element: element, mapper: mapper, scale: scale, stroke: ink)
        let angle = atan2(tangent.y, tangent.x)
        let length = min(16, max(5, hypot(end.x - start.x, end.y - start.y) * 0.35))
        let headPath = CGMutablePath()
        headPath.move(to: CGPoint(x: end.x - length * cos(angle - .pi / 6),
                                  y: end.y - length * sin(angle - .pi / 6)))
        headPath.addLine(to: end)
        headPath.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6),
                                     y: end.y - length * sin(angle + .pi / 6)))
        let head = shape(headPath, element: element, mapper: mapper, scale: scale, stroke: ink)
        container.addSublayer(shaft)
        container.addSublayer(head)
        strokeAnimation(shaft, duration: duration * 0.72)
        strokeAnimation(head, duration: duration * 0.28, delay: duration * 0.72)
        return container
    }
}
