import Foundation

/// The notch's click eligibility is independent of the assistant's work state.
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
        expanded = true
    }

    mutating func complete() -> Int {
        guard phase == .active else { return generation }
        generation += 1
        phase = .grace
        return generation
    }

    mutating func clickedOutside() {
        guard clickable else { return }
        expanded = false
        if phase == .grace { generation += 1 }
    }

    mutating func clickedCapsule() {
        guard clickable else { return }
        expanded = true
        if phase == .grace { generation += 1 }
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
