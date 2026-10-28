import Foundation

/// The notch's hover visibility is independent of the assistant's work state.
struct NotchVisibility {
    enum Phase: Equatable { case hidden, active, grace, dismissing }

    private(set) var phase: Phase = .hidden
    private(set) var expanded = false
    private(set) var generation = 0

    var clickable: Bool { phase == .active || phase == .grace }
    var visible: Bool { phase != .hidden }

    mutating func activate() {
        generation += 1
        phase = .active
        expanded = false
    }

    mutating func complete() -> Int {
        guard phase == .active else { return generation }
        generation += 1
        phase = .grace
        return generation
    }

    @discardableResult
    mutating func setHovered(_ hovered: Bool) -> Bool {
        guard clickable else { return false }
        guard expanded != hovered else { return false }
        expanded = hovered
        return true
    }

    mutating func beginDismissal(ifGeneration token: Int) -> Bool {
        guard phase == .grace, generation == token else { return false }
        phase = .dismissing
        expanded = false
        return true
    }

    mutating func finishDismissal(ifGeneration token: Int) -> Bool {
        guard phase == .dismissing, generation == token else { return false }
        phase = .hidden
        return true
    }

    mutating func shutdown() {
        generation += 1
        phase = .hidden
        expanded = false
    }
}
