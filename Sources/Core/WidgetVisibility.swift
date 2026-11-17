import Foundation

/// Visibility is driven by user intent and new attention events, never ordinary activity.
struct WidgetVisibility {
    private(set) var manuallyOpened = false
    private var attention = Set<String>()
    private var dismissed = Set<String>()
    var isExpanded: Bool { manuallyOpened || !attention.subtracting(dismissed).isEmpty }

    mutating func update(attention keys: Set<String>) {
        attention = keys
        dismissed.formIntersection(keys)
    }
    mutating func show() { manuallyOpened = true }
    mutating func toggle() {
        if isExpanded { hide() } else { manuallyOpened = true }
    }
    mutating func hide() {
        manuallyOpened = false
        dismissed.formUnion(attention)
    }
}
