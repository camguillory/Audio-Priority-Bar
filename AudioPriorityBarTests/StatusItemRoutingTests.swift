import AppKit
import Testing
@testable import AudioPriorityBar

@Test
func statusItemRoutesMouseAndAccessibilityEvents() {
    #expect(ClickRouting.action(for: .leftMouseUp) == .togglePanel)
    #expect(ClickRouting.action(for: .rightMouseUp) == .showMenu)
    #expect(ClickRouting.action(
        for: .leftMouseUp,
        modifiers: .control
    ) == .showMenu)
    #expect(ClickRouting.action(for: .leftMouseDown) == .togglePanel)
}

@Test
func statusItemSuppressionIsConsumeOnceAndExpires() {
    #expect(ClickRouting.shouldSuppressOpen(suppressedAt: 10, now: 10.5))
    #expect(!ClickRouting.shouldSuppressOpen(suppressedAt: 10, now: 12))
    #expect(!ClickRouting.shouldSuppressOpen(suppressedAt: nil, now: 10))
}
